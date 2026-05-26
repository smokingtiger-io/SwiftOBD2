import Foundation
import OSLog
import CoreBluetooth
import Combine

protocol BLEPeripheralManagerDelegate: AnyObject {
    func peripheralManager(_ manager: BLEPeripheralManager, didSetupCharacteristics peripheral: CBPeripheral)
}

class BLEPeripheralManager: NSObject, ObservableObject {
    func didWriteValue(_ peripheral: CBPeripheral, descriptor: CBDescriptor, error: (any Error)?) {

    }

    @Published var connectedPeripheral: CBPeripheral?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.app", category: "BLEPeripheralManager")
    private let characteristicHandler: BLECharacteristicHandler

    weak var delegate: BLEPeripheralManagerDelegate?
    private var connectionCompletion: ((CBPeripheral?, Error?) -> Void)?

    init(characteristicHandler: BLECharacteristicHandler) {
        self.characteristicHandler = characteristicHandler
        super.init()
    }

    func setPeripheral(_ peripheral: CBPeripheral?) {
        connectedPeripheral?.delegate = nil
        connectedPeripheral = peripheral
        connectedPeripheral?.delegate = self

        if let peripheral = peripheral {
            peripheral.discoverServices(BLEPeripheralScanner.supportedServices)
        }
    }

    func waitForCharacteristicsSetup(timeout: TimeInterval) async throws {
        // Clear the completion slot on timeout so a late discovery callback
        // doesn't dispatch into a dead continuation, and so the next
        // connect attempt starts from a clean slate. Without this the
        // `connectionCompletion` reference survived the throw and the
        // next caller's slot would be silently overwritten (or assert in
        // debug builds).
        try await withTimeout(
            seconds: timeout,
            onTimeout: { [weak self] in self?.connectionCompletion = nil }
        ) { [self] in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // didDiscoverCharacteristicsFor fires once per service requested
                // during connect. If a peripheral exposes more than one of the
                // supportedServices (FFE0/FFF0/18F0) or one service errors
                // while another succeeds, connectionCompletion can be invoked
                // twice — the success path only nils it out after its branch,
                // so an error→success sequence resumes the continuation twice
                // and crashes with SWIFT TASK CONTINUATION MISUSE. CB delegate
                // callbacks are serialized on a single dispatch queue, so a
                // plain Bool is sufficient (mirrors BLEConnection.connect's
                // hasResumed).
                var hasResumed = false
                self.connectionCompletion = { peripheral, error in
                    guard !hasResumed else { return }
                    hasResumed = true
                    if peripheral != nil {
                        continuation.resume()
                    } else if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: BLEManagerError.unknownError)
                    }
                }
            }
        }
    }

    func didDiscoverServices(_ peripheral: CBPeripheral, error: Error?) {
        // Forward the framework error immediately so waitForCharacteristicsSetup
        // can fail fast (BLEManagerError.unknownError or the underlying CB
        // error) instead of stalling until timeout. Previously the parameter
        // was ignored entirely and the loop just iterated an empty/nil
        // peripheral.services list, leaving the continuation parked.
        if let error = error {
            logger.error("Service discovery failed: \(error.localizedDescription)")
            connectionCompletion?(nil, error)
            connectionCompletion = nil
            return
        }
        for service in peripheral.services ?? [] {
            logger.info("Discovered service: \(service.uuid.uuidString)")
            characteristicHandler.discoverCharacteristics(for: service, on: peripheral)
        }
    }

    func didDiscoverCharacteristics(_ peripheral: CBPeripheral, service: CBService, error: Error?) {
        if let error = error {
            logger.error("Error discovering characteristics: \(error.localizedDescription)")
            connectionCompletion?(nil, error)
            return
        }

        guard let characteristics = service.characteristics else { return }

        characteristicHandler.setupCharacteristics(characteristics, on: peripheral)

        // Check if all required characteristics are set up
        if characteristicHandler.isReady {
            connectionCompletion?(peripheral, nil)
            connectionCompletion = nil

            // Notify delegate
            delegate?.peripheralManager(self, didSetupCharacteristics: peripheral)
        }
    }

    func didUpdateValue(_: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logger.error("Error reading characteristic value: \(error.localizedDescription)")
            return
        }

        guard let data = characteristic.value else { return }
        characteristicHandler.handleUpdatedValue(data, from: characteristic)
    }
}

extension BLEPeripheralManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        didDiscoverServices(peripheral, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        didDiscoverCharacteristics(peripheral, service: service, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        didUpdateValue(peripheral, characteristic: characteristic, error: error)
    }
}
