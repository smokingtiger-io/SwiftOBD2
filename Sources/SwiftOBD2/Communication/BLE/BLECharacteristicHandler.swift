import Foundation
import OSLog
import CoreBluetooth

class BLECharacteristicHandler {
    private var ecuReadCharacteristic: CBCharacteristic?
       private var ecuWriteCharacteristic: CBCharacteristic?
       private let messageProcessor: BLEMessageProcessor
       private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.app", category: "BLECharacteristicHandler")

       var isReady: Bool {
           ecuReadCharacteristic != nil && ecuWriteCharacteristic != nil
       }

       init(messageProcessor: BLEMessageProcessor) {
           self.messageProcessor = messageProcessor
       }


    // Many ELM327 BLE adapters expose only `.writeWithoutResponse` on
    // their write characteristic (e.g., VGate iCar Pro, some OBDLink
    // firmwares). The old code accepted only `.write`, leaving
    // ecuWriteCharacteristic nil on those adapters so the connect
    // characteristics-ready check (and subsequent sendCommand) failed.
    private static func supportsWrite(_ characteristic: CBCharacteristic) -> Bool {
        characteristic.properties.contains(.write) ||
            characteristic.properties.contains(.writeWithoutResponse)
    }

    func setupCharacteristics(_ characteristics: [CBCharacteristic], on peripheral: CBPeripheral) {
           for characteristic in characteristics {
               // Set up notifications for characteristics that support it
               if characteristic.properties.contains(.notify) {
                   peripheral.setNotifyValue(true, for: characteristic)
               }

               // Assign characteristics based on UUID and properties
               switch characteristic.uuid.uuidString.uppercased() {
               case "FFE1": // for service FFE0 (read and write)
                   if Self.supportsWrite(characteristic) {
                       ecuWriteCharacteristic = characteristic
                   }
                   if characteristic.properties.contains(.read) || characteristic.properties.contains(.notify) {
                       ecuReadCharacteristic = characteristic
                   }

               case "FFF1": // for service FFF0 (read only)
                   if characteristic.properties.contains(.read) || characteristic.properties.contains(.notify) {
                       ecuReadCharacteristic = characteristic
                   }

               case "FFF2": // for service FFF0 (write only)
                   if Self.supportsWrite(characteristic) {
                       ecuWriteCharacteristic = characteristic
                   }

               case "2AF0": // for service 18F0 (read)
                   if characteristic.properties.contains(.read) || characteristic.properties.contains(.notify) {
                       ecuReadCharacteristic = characteristic
                   }

               case "2AF1": // for service 18F0 (write)
                   if Self.supportsWrite(characteristic) {
                       ecuWriteCharacteristic = characteristic
                   }

               default:
                   logger.debug("Unknown characteristic: \(characteristic.uuid.uuidString)")
               }
           }

        logger.info("Characteristics setup - Read: \(self.ecuReadCharacteristic != nil), Write: \(self.ecuWriteCharacteristic != nil)")
       }

    func discoverCharacteristics(for service: CBService, on peripheral: CBPeripheral) {
        switch service.uuid {
        case CBUUID(string: "FFE0"):
            peripheral.discoverCharacteristics([CBUUID(string: "FFE1")], for: service)
        case CBUUID(string: "FFF0"):
            peripheral.discoverCharacteristics([CBUUID(string: "FFF1"), CBUUID(string: "FFF2")], for: service)
        case CBUUID(string: "18F0"):
            peripheral.discoverCharacteristics([CBUUID(string: "2AF0"), CBUUID(string: "2AF1")], for: service)
        default:
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func writeCommand(_ command: String, to peripheral: CBPeripheral) throws {
        guard let characteristic = ecuWriteCharacteristic,
              let data = "\(command)\r".data(using: .ascii) else {
            throw BLEManagerError.missingPeripheralOrCharacteristic
        }

        // Prefer .withResponse when the characteristic supports it
        // (delivers a delegate confirmation we can rely on for
        // backpressure); fall back to .withoutResponse for adapters
        // that advertise only that. Previously we always wrote with
        // .withResponse, so a characteristic that only allowed
        // .writeWithoutResponse silently failed the write.
        let writeType: CBCharacteristicWriteType =
            characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(data, for: characteristic, type: writeType)
        logger.info("Sent command: \(command)")
    }

    func handleUpdatedValue(_ data: Data, from characteristic: CBCharacteristic) {
        guard characteristic == ecuReadCharacteristic else {
            if let responseString = String(data: data, encoding: .utf8) {
                logger.info("Unknown characteristic: \(characteristic)\nResponse: \(responseString)")
            }
            return
        }

        messageProcessor.processReceivedData(data)
    }

    func reset() {
        ecuReadCharacteristic = nil
        ecuWriteCharacteristic = nil
    }
}
