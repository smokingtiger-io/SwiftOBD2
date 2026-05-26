//
//  wifiManager.swift
//
//
//  Created by kemo konteh on 2/26/24.
//

import CoreBluetooth
import Foundation
import Network
import OSLog

protocol CommProtocol {
    func sendCommand(_ command: String, retries: Int) async throws -> [String]
    func disconnectPeripheral()
    func connectAsync(timeout: TimeInterval, peripheral: CBPeripheral?) async throws
    func scanForPeripherals() async throws
    var connectionStatePublisher: Published<ConnectionState>.Publisher { get }
    var obdDelegate: OBDServiceDelegate? { get set }
}

enum CommunicationError: Error {
    case invalidData
    case errorOccurred(Error)
}

class WifiManager: CommProtocol {
    @Published var connectionState: ConnectionState = .disconnected

    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.app", category: "wifiManager")

    var obdDelegate: OBDServiceDelegate?

    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }

    var tcp: NWConnection?

    func connectAsync(timeout: TimeInterval, peripheral _: CBPeripheral? = nil) async throws {
        let host = NWEndpoint.Host("192.168.0.10")
        guard let port = NWEndpoint.Port("35000") else {
            throw CommunicationError.invalidData
        }
        tcp = NWConnection(host: host, port: port, using: .tcp)

        // NWConnection's stateUpdateHandler stays live for the whole connection
        // lifetime, but the continuation can only be resumed once. Without this
        // flag a post-connect .failed transition (e.g. ECONNRESET when the
        // adapter or emulator drops) would crash with SWIFT TASK CONTINUATION
        // MISUSE. The handler keeps updating connectionState so subscribers
        // still see the drop via the connectionState publisher.
        let hasResumed = AtomicFlag()

        // NWConnection has no built-in connect timeout: an unreachable host
        // parks the connection in .waiting(error) indefinitely (the handler
        // just logs and never resumes), so wrap the handshake in withTimeout.
        // On timeout we cancel the in-flight NWConnection — that transitions
        // the state machine to .cancelled, which resumes the continuation via
        // the hasResumed-gated path below before withTimeout itself throws.
        try await withTimeout(
            seconds: timeout,
            timeoutError: CommunicationError.errorOccurred(URLError(.timedOut)),
            onTimeout: { [weak self] in self?.tcp?.cancel() }
        ) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.tcp?.stateUpdateHandler = { [weak self] newState in
                    guard let self = self else { return }
                    switch newState {
                    case .ready:
                        self.logger.info("Connected to \(host.debugDescription):\(port.debugDescription)")
                        self.connectionState = .connectedToAdapter
                        if hasResumed.setIfClear() {
                            continuation.resume(returning: ())
                        }
                    case let .waiting(error):
                        self.logger.warning("Connection waiting: \(error.localizedDescription)")
                    case let .failed(error):
                        self.logger.error("Connection failed: \(error.localizedDescription)")
                        self.connectionState = .disconnected
                        if hasResumed.setIfClear() {
                            continuation.resume(throwing: CommunicationError.errorOccurred(error))
                        }
                    case .cancelled:
                        // Reached either when disconnectPeripheral() calls
                        // tcp.cancel() (post-connect — hasResumed already set,
                        // resume is a no-op) or when withTimeout's onTimeout
                        // cancelled the in-flight connection (hasResumed still
                        // clear — resume so the operation task doesn't leak).
                        self.logger.info("Connection cancelled")
                        self.connectionState = .disconnected
                        if hasResumed.setIfClear() {
                            continuation.resume(throwing: CommunicationError.errorOccurred(URLError(.timedOut)))
                        }
                    default:
                        break
                    }
                }
                self.tcp?.start(queue: .main)
            }
        }
    }

    func sendCommand(_ command: String, retries: Int) async throws -> [String] {
        guard let data = "\(command)\r".data(using: .ascii) else {
            throw CommunicationError.invalidData
        }
        logger.info("Sending: \(command)")
        return try await sendCommandInternal(data: data, retries: retries)
    }

    private func sendCommandInternal(data: Data, retries: Int) async throws -> [String] {
        // Guard against retries ≤ 0: `1 ... retries` would be an invalid
        // closed range and trap. Treat zero or negative as "one attempt".
        let attempts = max(1, retries)
        for attempt in 1 ... attempts {
            do {
                let response = try await sendAndReceiveData(data)
                if let lines = processResponse(response) {
                    return lines
                } else if attempt < attempts {
                    logger.info("No data received, retrying attempt \(attempt + 1) of \(attempts)...")
                    try await Task.sleep(nanoseconds: 100_000_000) // 0.1 s — comment in older revisions said 0.5s; actual value here is 0.1s
                }
            } catch {
                if attempt == attempts {
                    throw error
                }
                logger.warning("Attempt \(attempt) failed, retrying: \(error.localizedDescription)")
            }
        }
        throw CommunicationError.invalidData
    }

    private func sendAndReceiveData(_ data: Data) async throws -> String {
        guard let tcpConnection = tcp else {
             throw CommunicationError.invalidData
         }
        let logger = self.logger // Avoid capturing `self` directly

        // If the adapter never emits the '>' prompt (firmware hangs, link
        // half-drops, etc.), the inner receive loop would await forever
        // and the outer retry loop in sendCommandInternal could never
        // fire. Wrap the receive in withTimeout so a stuck request fails
        // and lets the retry path kick in. The hasResumed AtomicFlag
        // below stays — when the timeout cancels the operation task the
        // receive callback may still deliver a late chunk, and we want
        // that callback to no-op rather than crash on a dead continuation.
        let hasResumed = AtomicFlag()
        return try await withTimeout(
            seconds: BLEConstants.defaultTimeout,
            timeoutError: CommunicationError.errorOccurred(URLError(.timedOut))
        ) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                tcpConnection.send(content: data, completion: .contentProcessed { error in
                    if let error = error {
                        logger.error("Error sending data: \(error.localizedDescription)")
                        if hasResumed.setIfClear() {
                            continuation.resume(throwing: CommunicationError.errorOccurred(error))
                        }
                        return
                    }

                    // ELM327 frames each reply with a trailing '>' prompt. A single TCP
                    // receive can return only the command echo or only part of the
                    // response, so accumulate chunks until the prompt arrives. Without
                    // this loop, a later command picks up the previous command's
                    // leftover bytes and parsing collapses.
                    var accumulated = ""

                    func readMore() {
                        tcpConnection.receive(minimumIncompleteLength: 1, maximumLength: 500) { data, _, _, error in
                            if hasResumed.isSet { return }
                            if let error = error {
                                logger.error("Error receiving data: \(error.localizedDescription)")
                                if hasResumed.setIfClear() {
                                    continuation.resume(throwing: CommunicationError.errorOccurred(error))
                                }
                                return
                            }
                            guard let data, let chunk = String(data: data, encoding: .utf8) else {
                                logger.warning("Received invalid or empty data")
                                if hasResumed.setIfClear() {
                                    continuation.resume(throwing: CommunicationError.invalidData)
                                }
                                return
                            }
                            accumulated.append(chunk)
                            if accumulated.contains(">") {
                                if hasResumed.setIfClear() {
                                    continuation.resume(returning: accumulated)
                                }
                            } else {
                                readMore()
                            }
                        }
                    }
                    readMore()
                })
            }
        }
    }

    private final class AtomicFlag {
        private let lock = NSLock()
        private var flag = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func setIfClear() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if flag { return false }
            flag = true
            return true
        }
    }

    private func processResponse(_ response: String) -> [String]? {
        logger.info("Processing response: \(response)")
        var lines = response.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard !lines.isEmpty else {
            logger.warning("Empty response lines")
            return nil
        }

        if lines.last?.contains(">") == true {
            lines.removeLast()
        }

        if lines.first?.lowercased() == "no data" {
            return nil
        }

        return lines
    }

    func disconnectPeripheral() {
        tcp?.cancel()
    }

    func scanForPeripherals() async throws {}
}
