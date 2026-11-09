import CoreBluetooth
import CryptoKit
import Foundation

/// The iPhone this Mac is paired with. Stored in a file only the user can read.
struct PairedPhone: Codable {
    let key: Data
    let pairingID: Data
    let phoneName: String
    let pairedAt: Date

    var pairingKey: SymmetricKey { SymmetricKey(data: key) }
}

enum PairingStore {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/bleping/pairing.json")
    }

    static func load() -> PairedPhone? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PairedPhone.self, from: data)
    }

    static func save(_ phone: PairedPhone) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Create the file 0600 before writing, so the key is never readable by others.
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: JSONEncoder().encode(phone))
    }

    static func delete() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

/// The Mac's half of the pairing exchange (see Wire.swift for the steps).
/// One iPhone at a time; a wrong code ends that attempt, and the iPhone can start over.
final class PairingSession {
    private enum State {
        case waitingForPhone
        case committed(central: CBCentral, phoneKey: Data, macPrivate: P256.KeyAgreement.PrivateKey, macNonce: Data)
        case waitingForConfirm(central: CBCentral, key: SymmetricKey)
    }

    enum Progress {
        case phoneConnecting
        case code(String)
        case failed(String)
    }

    /// Steps the user should see (the code to type, failures).
    var onProgress: ((Progress) -> Void)?

    private let peripheral: Peripheral
    private let onPaired: (PairedPhone) -> Void
    private var state = State.waitingForPhone

    init(peripheral: Peripheral, onPaired: @escaping (PairedPhone) -> Void) {
        self.peripheral = peripheral
        self.onPaired = onPaired
    }

    func handle(_ data: Data, from central: CBCentral) {
        guard let message = PairMessage(data) else {
            return fail("Unexpected message", to: central)
        }
        switch (message, state) {
        case (.hello(let phoneKey), _):
            // A new hello always (re)starts pairing, unless another iPhone is mid-way.
            if let busy = activeCentral, busy != central {
                peripheral.sendPairing(.failed("Another iPhone is pairing with this Mac right now"), to: central)
                return
            }
            guard (try? P256.KeyAgreement.PublicKey(x963Representation: phoneKey)) != nil else {
                return fail("Invalid key", to: central)
            }
            let macPrivate = P256.KeyAgreement.PrivateKey()
            let macKey = macPrivate.publicKey.x963Representation
            let macNonce = PairingCrypto.randomBytes(PairMessage.nonceLength)
            state = .committed(central: central, phoneKey: phoneKey, macPrivate: macPrivate, macNonce: macNonce)
            log("An iPhone is pairing…")
            onProgress?(.phoneConnecting)
            peripheral.sendPairing(.commit(macKey: macKey, commitment: PairingCrypto.commitment(
                macKey: macKey, phoneKey: phoneKey, macNonce: macNonce)), to: central)

        case (.phoneNonce(let phoneNonce), .committed(let owner, let phoneKey, let macPrivate, let macNonce)) where owner == central:
            let macKey = macPrivate.publicKey.x963Representation
            guard let phonePublic = try? P256.KeyAgreement.PublicKey(x963Representation: phoneKey),
                  let secret = try? macPrivate.sharedSecretFromKeyAgreement(with: phonePublic) else {
                return fail("Key exchange failed", to: central)
            }
            let key = PairingCrypto.pairingKey(secret: secret, phoneKey: phoneKey, macKey: macKey,
                                               phoneNonce: phoneNonce, macNonce: macNonce)
            let code = PairingCrypto.code(phoneKey: phoneKey, macKey: macKey,
                                          phoneNonce: phoneNonce, macNonce: macNonce)
            state = .waitingForConfirm(central: central, key: key)
            peripheral.sendPairing(.macNonce(macNonce), to: central)
            onProgress?(.code(code))
            log("""
                Pairing code:  \(PairingCrypto.display(code))
                  Type it in the bleping app on your iPhone.
                """)

        case (.phoneConfirm(let proof, let phoneName), .waitingForConfirm(let owner, let key)) where owner == central:
            guard PairingCrypto.checkProof(proof, role: "phone", key: key) else {
                return fail("The pairing check failed. Start pairing again on the iPhone.", to: central)
            }
            let paired = PairedPhone(key: key.withUnsafeBytes { Data($0) },
                                     pairingID: PairingCrypto.randomBytes(PairMessage.pairingIDLength),
                                     phoneName: phoneName.isEmpty ? "iPhone" : phoneName, pairedAt: Date())
            do {
                try PairingStore.save(paired)
            } catch {
                return fail("The Mac could not save the pairing: \(error.localizedDescription)", to: central)
            }
            state = .waitingForPhone
            peripheral.sendPairing(.macConfirm(proof: PairingCrypto.proof("mac", key: key),
                                               pairingID: paired.pairingID, macName: macName), to: central)
            log("Paired with \"\(paired.phoneName)\" ✓")
            onPaired(paired)

        case (.failed(let reason), _):
            log("Pairing cancelled on the iPhone: \(reason)")
            state = .waitingForPhone
            onProgress?(.failed("Cancelled on the iPhone"))

        default:
            fail("Unexpected pairing step. Start pairing again on the iPhone.", to: central)
        }
    }

    private var activeCentral: CBCentral? {
        switch state {
        case .waitingForPhone: return nil
        case .committed(let central, _, _, _), .waitingForConfirm(let central, _): return central
        }
    }

    private func fail(_ reason: String, to central: CBCentral) {
        log("Pairing failed: \(reason)")
        peripheral.sendPairing(.failed(reason), to: central)
        state = .waitingForPhone
        onProgress?(.failed(reason))
    }
}

/// The Mac's name as shown in Sharing settings, e.g. "yamaneko".
var macName: String { Host.current().localizedName ?? "Mac" }
