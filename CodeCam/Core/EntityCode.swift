import CryptoKit
import Foundation

enum EntityCode {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    static func letters(from seed: String, length: Int) -> String {
        let digest = SHA256.hash(data: Data(seed.utf8))
        let bytes = Array(digest)
        return String((0..<length).map { alphabet[Int(bytes[$0]) % 26] })
    }

    static func codeCamSerial(terminalId: String) -> String {
        "CC" + letters(from: "\(terminalId):CODE_CAM", length: 4)
    }

    static func edgeTerminalSerial(terminalId: String) -> String {
        "ET" + letters(from: "\(terminalId):EDGE_TERMINAL", length: 4)
    }
}
