//
//  parser.swift
//  SmartOBD2
//
//  Created by kemo konteh on 9/19/23.
//

import Foundation

enum FrameType: UInt8, Codable {
    case singleFrame = 0x00
    case firstFrame = 0x10
    case consecutiveFrame = 0x20
}

public enum ECUID: UInt8, Codable {
    case engine = 0x00
    case transmission = 0x01
    case unknown = 0x02

    public var description: String {
        switch self {
        case .engine:
            return "Engine"
        case .transmission:
            return "Transmission"
        case .unknown:
            return "Unknown"
        }
    }
}

enum TxId: UInt8, Codable {
    case engine = 0x00
    case transmission = 0x01
}

public struct CANParser {
    public let messages: [Message]
    let frames: [Frame]

    public init(_ lines: [String], idBits: Int) throws {
        let obdLines = lines
            .map { $0.replacingOccurrences(of: " ", with: "") }
            .filter(\.isHex)

        frames = try obdLines.compactMap { try Frame(raw: $0, idBits: idBits) }

        let framesByECU = Dictionary(grouping: frames) { $0.txID }

        messages = try framesByECU.values.compactMap { try Message(frames: $0) }
    }
}

public struct Message: MessageProtocol {
    var frames: [Frame]
    public var data: Data?

    public var ecu: ECUID {
        frames.first?.txID ?? .unknown
    }

    init(frames: [Frame]) throws {
        self.frames = frames
        switch frames.count {
        case 1:
            data = try parseSingleFrameMessage(frames)
        case 2...:
            data = try parseMultiFrameMessage(frames)
        default:
            throw ParserError.error("Invalid frame count")
        }
    }

    private func parseSingleFrameMessage(_ frames: [Frame]) throws -> Data {
        guard let frame = frames.first, frame.type == .singleFrame,
              let dataLen = frame.dataLen, dataLen > 0,
              frame.data.count >= dataLen + 1
        else { // Pre-validate the length
            throw ParserError.error("Frame validation failed")
        }
        // Layout: [PCI(length)] [mode] [PID, ...data]. dataLen counts
        // mode+PID+data, so after stripping length+mode the real payload
        // is dataLen-1 bytes. Trimming to that length drops any CAN
        // padding (0xAA / 0x55) that the adapter appended to fill the
        // 8-byte frame — without it the padding flowed into multi-byte
        // UAS decoders and inflated readings like RPM/MAF.
        return frame.data.dropFirst(2).prefix(Int(dataLen) - 1)
    }

    private func parseMultiFrameMessage(_ frames: [Frame]) throws -> Data {
        guard let firstFrame = frames.first(where: { $0.type == .firstFrame }) else {
            throw ParserError.error("Failed to parse multi frame message")
        }
        let consecutiveFrames = frames.filter { $0.type == .consecutiveFrame }
        return try assembleData(firstFrame: firstFrame, consecutiveFrames: consecutiveFrames)
    }

    private func assembleData(firstFrame: Frame, consecutiveFrames: [Frame]) throws -> Data {
        var assembledFrame: Frame = firstFrame
        // Extract data from consecutive frames, skipping the PCI byte
        for frame in consecutiveFrames {
            assembledFrame.data.append(frame.data[1...])
        }
        return try extractDataFromFrame(assembledFrame, startIndex: 3)
    }

    private func extractDataFromFrame(_ frame: Frame, startIndex: Int) throws -> Data {
        guard let frameDataLen = frame.dataLen, frameDataLen > 0 else {
            // Without the >0 guard a dataLen of 0 makes endIndex less
            // than startIndex below, and `data[startIndex ..< endIndex]`
            // traps with a precondition failure on the reversed range.
            throw ParserError.error("Failed to extract data from frame")
        }
        let endIndex = startIndex + Int(frameDataLen) - 1
        guard endIndex <= frame.data.count else {
            return frame.data[startIndex...]
        }
        return frame.data[startIndex ..< endIndex]
    }
}

struct Frame {
    var raw: String
    var data = Data()
    var priority: UInt8
    var addrMode: UInt8
    var rxID: UInt8
    var txID: ECUID
    var type: FrameType
    var seqIndex: UInt8 = 0 // Only used when type = CF
    // FirstFrame length is a 12-bit value packed across low nibble of
    // byte 0 and all of byte 1 (max 4095). Storing it as UInt8 silently
    // dropped the high nibble, so multi-frame responses larger than 255
    // bytes (e.g. long VIN / calibration-id streams) parsed with
    // truncated length and assembled partial data.
    var dataLen: UInt16?

    init(raw: String, idBits: Int) throws {
        self.raw = raw

        let paddedRawData = idBits == 11 ? "00000" + raw : raw

        let dataBytes = paddedRawData.hexBytes

        data = Data(dataBytes.dropFirst(4))

        guard dataBytes.count >= 6, dataBytes.count <= 12 else {
            obdError("Invalid frame size: \(dataBytes.count) bytes", category: .parsing)
            OBDLogger.shared.logParseError("Frame size out of range (6-12 bytes)", data: Data(dataBytes), expectedFormat: "6-12 bytes")
            throw ParserError.error("Invalid frame size")
        }

        guard let dataType = data.first,
              let type = FrameType(rawValue: dataType & 0xF0)
        else {
            obdError("Invalid frame type detected", category: .parsing)
            OBDLogger.shared.logParseError("Unknown frame type", data: Data(dataBytes), expectedFormat: "Valid FrameType enum value")
            throw ParserError.error("Invalid frame type")
        }

        priority = dataBytes[2] & 0x0F
        addrMode = dataBytes[3] & 0xF0
        rxID = dataBytes[2]
        txID = ECUID(rawValue: dataBytes[3] & 0x07) ?? .unknown
        self.type = type

        switch type {
        case .singleFrame:
            dataLen = UInt16(data[0] & 0x0F)
        case .firstFrame:
            // Compose 12-bit length: bits 11..8 from low nibble of byte 0,
            // bits 7..0 from byte 1. Previous code shifted UInt8 << 8 which
            // overflowed to zero, dropping the high nibble entirely.
            dataLen = (UInt16(data[0] & 0x0F) << 8) | UInt16(data[1])
        case .consecutiveFrame:
            seqIndex = data[0] & 0x0F
        }
    }
}

enum ParserError: Error {
    case error(String)
}
