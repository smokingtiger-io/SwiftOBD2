//
//  protocol_can.swift
//
//
//  Created by kemo konteh on 5/15/24.
//

import Foundation

protocol CANProtocol {
    var elmID: String { get }
    var name: String { get }

    func parse(_ lines: [String]) throws -> [MessageProtocol]
}

extension CANProtocol {
    func parseDefault(_ lines: [String], idBits: Int) throws -> [MessageProtocol] {
        try CANParser(lines, idBits: idBits).messages
    }

    func parseLegacy(_ lines: [String]) throws -> [MessageProtocol] {
        let messages = try LegacyParcer(lines).messages
        return messages
    }
}

// 11-bit vs 29-bit CAN frames differ in the header length the adapter
// emits, which Frame.init compensates for with a 5-char "00000" prefix
// pad when idBits == 11. Calling parseDefault with the wrong idBits
// shifts every byte offset by 5 hex chars and turns the assembled
// payload into garbage, so each protocol class must pass its actual
// header width.

class ISO_15765_4_11bit_500k: CANProtocol {
    let elmID = "6"
    let name = "ISO 15765-4 (CAN 11/500)"
    func parse(_ lines: [String]) throws -> [MessageProtocol] {
        try parseDefault(lines, idBits: 11)
    }
}

class ISO_15765_4_29bit_500k: CANProtocol {
    let elmID = "7"
    let name = "ISO 15765-4 (CAN 29/500)"
    func parse(_ lines: [String]) throws -> [MessageProtocol] {
        try parseDefault(lines, idBits: 29)
    }
}

class ISO_15765_4_11bit_250K: CANProtocol {
    let elmID = "8"
    let name = "ISO 15765-4 (CAN 11/250)"
    func parse(_ lines: [String]) throws -> [MessageProtocol] {
        try parseDefault(lines, idBits: 11)
    }
}

class ISO_15765_4_29bit_250k: CANProtocol {
    let elmID = "9"
    let name = "ISO 15765-4 (CAN 29/250)"
    func parse(_ lines: [String]) throws -> [MessageProtocol] {
        try parseDefault(lines, idBits: 29)
    }
}

class SAE_J1939: CANProtocol {
    let elmID = "A"
    let name = "SAE J1939 (CAN 29/250)"
    func parse(_ lines: [String]) throws -> [MessageProtocol] {
        try parseDefault(lines, idBits: 29)
    }
}
