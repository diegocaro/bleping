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
/// One iPhone at a time. Both screens show the code; the pairing is saved once the user pressed
/// Pair on the Mac and the iPhone's Pair (with its proof) arrived. An attempt that stalls times
/// out, so no phone can hold pairing mode hostage.
final class PairingSession {
    private enum State {
        case waitingForPhone
        case committed(central: CBCentral, phoneKey: Data, phoneName: String,
                       macPrivate: P256.KeyAgreement.PrivateKey, macNonce: Data)
        /// Both sides show `code`; waiting for Pair on the Mac (`macApproved`) and on the
        /// iPhone (`phoneApproved`, set once its proof checked out).
        case comparing(central: CBCentral, key: SymmetricKey, code: String, phoneName: String,
                       macApproved: Bool, phoneApproved: Bool)
    }

    enum Progress {
        case phoneConnecting
        /// Show `code` and ask "Pair with `phoneName`?". `waitingForPhone`: the user already
        /// pressed Pair on the Mac.
        case compare(code: String, phoneName: String, waitingForPhone: Bool)
        case failed(String)
    }

    /// How long an iPhone may take to finish the key exchange, and the user to press Pair.
    static let exchangeTimeout: TimeInterval = 30, confirmTimeout: TimeInterval = 180

    /// Steps the user should see (the code to compare, failures).
    var onProgress: ((Progress) -> Void)?

    private let peripheral: Peripheral
    private let onPaired: (PairedPhone, CBCentral) -> Void
    private var state = State.waitingForPhone
    private var timeout: DispatchWorkItem?
    /// Chosen up front so the Mac's Pair message can carry it before anything is saved.
    private let pairingID = PairingCrypto.randomBytes(PairMessage.pairingIDLength)

    init(peripheral: Peripheral, onPaired: @escaping (PairedPhone, CBCentral) -> Void) {
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
        case (.hello(let phoneKey, let name), _):
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
            state = .committed(central: central, phoneKey: phoneKey, phoneName: Self.clean(name),
                               macPrivate: macPrivate, macNonce: macNonce)
            armTimeout(Self.exchangeTimeout)
            log("An iPhone is pairing…")
            onProgress?(.phoneConnecting)
            peripheral.sendPairing(.commit(macKey: macKey, commitment: PairingCrypto.commitment(
                macKey: macKey, phoneKey: phoneKey, macNonce: macNonce)), to: central)

        case (.phoneNonce(let phoneNonce), .committed(let owner, let phoneKey, let phoneName, let macPrivate, let macNonce))
            where owner == central:
            let macKey = macPrivate.publicKey.x963Representation
            guard let phonePublic = try? P256.KeyAgreement.PublicKey(x963Representation: phoneKey),
                  let secret = try? macPrivate.sharedSecretFromKeyAgreement(with: phonePublic) else {
                return fail("Key exchange failed", to: central)
            }
            let key = PairingCrypto.pairingKey(secret: secret, phoneKey: phoneKey, macKey: macKey,
                                               phoneNonce: phoneNonce, macNonce: macNonce)
            let code = PairingCrypto.code(phoneKey: phoneKey, macKey: macKey,
                                          phoneNonce: phoneNonce, macNonce: macNonce)
            state = .comparing(central: central, key: key, code: code, phoneName: phoneName,
                               macApproved: false, phoneApproved: false)
            armTimeout(Self.confirmTimeout)
            peripheral.sendPairing(.macNonce(macNonce), to: central)
            onProgress?(.compare(code: code, phoneName: phoneName, waitingForPhone: false))
            log("Pairing code:  \(PairingCrypto.display(code))  (check \"\(phoneName)\" shows the same, then Pair on both)",
                personal: true)

        case (.phoneConfirm(let proof, _), .comparing(let owner, let key, let code, let phoneName, let macApproved, _))
            where owner == central:
            guard PairingCrypto.checkProof(proof, role: "phone", key: key) else {
                return fail("The pairing check failed. Start pairing again on the iPhone.", to: central)
            }
            log("Pair pressed on the iPhone")
            state = .comparing(central: central, key: key, code: code, phoneName: phoneName,
                               macApproved: macApproved, phoneApproved: true)
            if macApproved { finish() }

        case (.failed(let reason), _):
            log("Pairing cancelled on the iPhone: \(reason)")
            reset()
            onProgress?(.failed("Cancelled on the iPhone"))

        default:
            fail("Unexpected pairing step. Start pairing again on the iPhone.", to: central)
        }
    }

    /// The user pressed Pair on the Mac (the codes match).
    func approve() {
        guard case .comparing(let central, let key, let code, let phoneName, false, let phoneApproved) = state else { return }
        state = .comparing(central: central, key: key, code: code, phoneName: phoneName,
                           macApproved: true, phoneApproved: phoneApproved)
        if phoneApproved {
            finish()
        } else {
            peripheral.sendPairing(.macConfirm(proof: PairingCrypto.proof("mac", key: key),
                                               pairingID: pairingID, macName: macName), to: central)
            onProgress?(.compare(code: code, phoneName: phoneName, waitingForPhone: true))
        }
    }

    /// The user cancelled on the Mac: tell the iPhone, if one is pairing.
    func cancel() {
        if let central = activeCentral { peripheral.sendPairing(.failed("Cancelled on the Mac"), to: central) }
        reset()
    }

    /// Pair was pressed on both sides: save, and tell the iPhone if it doesn't know yet.
    private func finish() {
        guard case .comparing(let central, let key, _, let phoneName, true, true) = state else { return }
        let paired = PairedPhone(key: key.withUnsafeBytes { Data($0) }, pairingID: pairingID,
                                 phoneName: phoneName, pairedAt: Date())
        do {
            try PairingStore.save(paired)
        } catch {
            return fail("The Mac could not save the pairing: \(error.localizedDescription)", to: central)
        }
        reset()
        // The iPhone may have pressed Pair first; then it's still waiting for our confirmation.
        // (Sending it twice is harmless: the iPhone ignores it once paired.)
        peripheral.sendPairing(.macConfirm(proof: PairingCrypto.proof("mac", key: key),
                                           pairingID: pairingID, macName: macName), to: central)
        log("Paired with \"\(paired.phoneName)\" ✓", personal: true)
        onPaired(paired, central)
    }

    private var activeCentral: CBCentral? {
        switch state {
        case .waitingForPhone: return nil
        case .committed(let central, _, _, _, _), .comparing(let central, _, _, _, _, _): return central
        }
    }

    private func reset() {
        state = .waitingForPhone
        timeout?.cancel()
        timeout = nil
    }

    /// Starts the clock for the step just entered, so a stalled phone frees pairing mode.
    private func armTimeout(_ seconds: TimeInterval) {
        timeout?.cancel()
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
