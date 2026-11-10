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
/// One iPhone at a time. The user types the code the iPhone shows; three wrong codes end that
/// attempt, and an attempt that stalls times out, so no phone can hold pairing mode hostage.
final class PairingSession {
    private enum State {
        case waitingForPhone
        case committed(central: CBCentral, phoneKey: Data, macPrivate: P256.KeyAgreement.PrivateKey, macNonce: Data)
        /// Nonces swapped; waiting for the iPhone to prove it derived the same key.
        case awaitingProof(central: CBCentral, key: SymmetricKey, code: String)
        /// Waiting for the user to type, on the Mac, the code the iPhone shows.
        case enteringCode(central: CBCentral, key: SymmetricKey, code: String, phoneName: String, wrongTries: Int)
    }

    enum Progress {
        case phoneConnecting
        /// Ask the user for the code shown on `phoneName`; `error` explains a wrong try.
        case enterCode(phoneName: String, error: String?)
        case failed(String)
    }

    static let maxWrongTries = 3
    /// How long an iPhone may take to finish the key exchange, and the user to type the code.
    static let exchangeTimeout: TimeInterval = 30, codeTimeout: TimeInterval = 180

    /// Steps the user should see (the code prompt, failures).
    var onProgress: ((Progress) -> Void)?

    private let peripheral: Peripheral
    private let onPaired: (PairedPhone) -> Void
    private var state = State.waitingForPhone
    private var timeout: DispatchWorkItem?

    init(peripheral: Peripheral, onPaired: @escaping (PairedPhone) -> Void) {
        self.peripheral = peripheral
        self.onPaired = onPaired
    }

    deinit { timeout?.cancel() }

    func handle(_ data: Data, from central: CBCentral) {
        guard let message = PairMessage(data) else {
            // Only the iPhone that's pairing may end its own attempt.
            if activeCentral == nil || activeCentral == central { fail("Unexpected message", to: central) }
            return
        }
        if case .hello = message {} else if let busy = activeCentral, busy != central {
            // Another phone talking during someone else's pairing: answer it, leave ours alone.
            peripheral.sendPairing(.failed("Another iPhone is pairing with this Mac right now"), to: central)
            return
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
            armTimeout()
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
            state = .awaitingProof(central: central, key: key, code: code)
            peripheral.sendPairing(.macNonce(macNonce), to: central)

        case (.phoneConfirm(let proof, let name), .awaitingProof(let owner, let key, let code)) where owner == central:
            guard PairingCrypto.checkProof(proof, role: "phone", key: key) else {
                return fail("The pairing check failed. Start pairing again on the iPhone.", to: central)
            }
            let phoneName = Self.clean(name)
            state = .enteringCode(central: central, key: key, code: code, phoneName: phoneName, wrongTries: 0)
            armTimeout()
            onProgress?(.enterCode(phoneName: phoneName, error: nil))
            log("Type the 6-digit code shown on \"\(phoneName)\" and press Return.", personal: true)

        case (.failed(let reason), _):
            log("Pairing cancelled on the iPhone: \(reason)")
            reset()
            onProgress?(.failed("Cancelled on the iPhone"))

        default:
            fail("Unexpected pairing step. Start pairing again on the iPhone.", to: central)
        }
    }

    /// The user typed a code on the Mac.
    func submitCode(_ text: String) {
        guard case .enteringCode(let central, let key, let code, let phoneName, let wrongTries) = state else { return }
        guard text.filter(\.isNumber) == code else {
            let tries = wrongTries + 1
            if tries >= Self.maxWrongTries {
                return fail("The wrong code was typed on the Mac \(tries) times. Start pairing again.", to: central)
            }
            log("Wrong pairing code (\(Self.maxWrongTries - tries) tries left)")
            // The clock keeps running from the first prompt.
            state = .enteringCode(central: central, key: key, code: code, phoneName: phoneName, wrongTries: tries)
            onProgress?(.enterCode(phoneName: phoneName, error:
                "That doesn't match the code on \(phoneName). \(Self.maxWrongTries - tries) tries left."))
            return
        }
        let paired = PairedPhone(key: key.withUnsafeBytes { Data($0) },
                                 pairingID: PairingCrypto.randomBytes(PairMessage.pairingIDLength),
                                 phoneName: phoneName, pairedAt: Date())
        do {
            try PairingStore.save(paired)
        } catch {
            return fail("The Mac could not save the pairing: \(error.localizedDescription)", to: central)
        }
        reset()
        peripheral.sendPairing(.macConfirm(proof: PairingCrypto.proof("mac", key: key),
                                           pairingID: paired.pairingID, macName: macName), to: central)
        log("Paired with \"\(paired.phoneName)\" ✓", personal: true)
        onPaired(paired)
    }

    private var activeCentral: CBCentral? {
        switch state {
        case .waitingForPhone: return nil
        case .committed(let central, _, _, _), .awaitingProof(let central, _, _),
             .enteringCode(let central, _, _, _, _): return central
        }
    }

    private func reset() {
        state = .waitingForPhone
        timeout?.cancel()
        timeout = nil
    }

    /// Starts the clock for the step just entered, so a stalled phone frees pairing mode.
    private func armTimeout() {
        timeout?.cancel()
        timeout = nil
        let seconds: TimeInterval
        switch state {
        case .waitingForPhone: return
        case .committed, .awaitingProof: seconds = Self.exchangeTimeout
        case .enteringCode: seconds = Self.codeTimeout
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self, let central = activeCentral else { return }
            fail("Pairing took too long. Start pairing again on the iPhone.", to: central)
        }
        timeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func fail(_ reason: String, to central: CBCentral) {
        log("Pairing failed: \(reason)")
        peripheral.sendPairing(.failed(reason), to: central)
        reset()
        onProgress?(.failed(reason))
    }

    /// The phone's name is shown and logged: keep it to one line of printable text.
    private static func clean(_ name: String) -> String {
        let text = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "iPhone" : text
    }
}

/// The Mac's name as shown in Sharing settings, e.g. "yamaneko".
var macName: String { Host.current().localizedName ?? "Mac" }
