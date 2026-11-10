import CryptoKit
import Foundation
import Security

/// The Mac this iPhone is paired with. The key lives in the Keychain.
struct PairedMac: Codable, Equatable {
    let key: Data
    let pairingID: Data
    let macName: String
    let pairedAt: Date

    var eventKey: SymmetricKey { EventCrypto.eventKey(pairingKey: SymmetricKey(data: key)) }
}

enum PairedMacStore {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.altiro.pairing",
        kSecAttrAccount as String: "mac",
    ]

    static func load() -> PairedMac? {
        var q = query
        q[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(PairedMac.self, from: data)
    }

    static func save(_ mac: PairedMac) throws {
        delete()
        var q = query
        q[kSecValueData as String] = try JSONEncoder().encode(mac)
        // Readable while locked (after the first unlock), so background wake-ups can decrypt.
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
