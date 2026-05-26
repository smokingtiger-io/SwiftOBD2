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

    func connectAsync(timeout _: TimeInterval, peripheral _: CBPeripheral? = nil) async throws {
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

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            tcp?.stateUpdateHandler = { [weak self] newState in
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
                default:
                    break
                }
            }
            tcp?.start(queue: .main)
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
        for attempt in 1 ... retries {
            do {
                let response = try await sendAndReceiveData(data)
                if let lines = processResponse(response) {
                    return lines
                } else if attempt < retries {
                    logger.info("No data received, retrying attempt \(attempt + 1) of \(retries)...")
                    try await Task.sleep(nanoseconds: 100_000_000) // 0.5 seconds delay
                }
            } catch {
                if attempt == retries {
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

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            tcpConnection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    logger.error("Error sending data: \(error.localizedDescription)")
                    continuation.resume(throwing: CommunicationError.errorOccurred(error))
                    return
                }

                // ELM327 frames each reply with a trailing '>' prompt. A single TCP
                // receive can return only the command echo or only part of the
                // response, so accumulate chunks until the prompt arrives. Without
                // this loop, a later command picks up the previous command's
                // leftover bytes and parsing collapses.
                var accumulated = ""
                let hasResumed = AtomicFlag()

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
