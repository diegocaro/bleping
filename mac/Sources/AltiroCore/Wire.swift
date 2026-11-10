import CoreBluetooth
import CryptoKit
import Foundation

// Everything the Mac tool and the iPhone app must agree on. This one file is compiled into
// both (ios/project.yml points here), so the two sides cannot drift apart.
//
// How it works:
//   1. The Mac is a BLE peripheral that always advertises `serviceUUID`.
//   2. Pairing (once): the iPhone connects and the two run an ECDH key exchange over the
//      `pairing` characteristic. Both derive a 6-digit code from the exchange and show it,
//      and the user checks they match and presses Pair on both, as with Apple's own
//      Bluetooth pairing. Matching codes prove nobody sat in the middle. Asking on both
//      sides means neither can be paired by a stranger's device in range: a stranger's
//      phone or Mac can't press Pair on the user's own Mac or iPhone. Both sides then keep
//      the same 256-bit key, and each saves it only once both users' Pair presses arrived.
//   3. Afterwards the iPhone reconnects whenever the Mac is in range, and the two check each
//      other: the iPhone writes a random nonce that only a Mac holding the pairing key can
//      answer, and the Mac's answer carries its own nonce, which the iPhone answers in turn.
//      Then the iPhone subscribes to `events`. The Mac sends events (and honours catch-up
//      requests) only to an iPhone that passed, so other devices in range get nothing.
//      Each Mac notification arrives encrypted (ChaCha20-Poly1305) with a key derived from
//      the pairing key.

enum Wire {
    static let serviceUUID = CBUUID(string: "7268617C-DB3D-4D61-9142-9C2D94ACBE6C")
    /// Pairing messages: the iPhone writes (with response), the Mac answers by notification.
    static let pairingUUID = CBUUID(string: "7268617C-0001-4D61-9142-9C2D94ACBE6C")
    /// Encrypted notifications, Mac → iPhone, by notification.
    static let eventsUUID = CBUUID(string: "7268617C-0002-4D61-9142-9C2D94ACBE6C")
    /// The Mac resends notifications from this far back when the iPhone reconnects;
    /// the iPhone ignores anything older (which also defeats replays of old traffic).
    static let replayWindow: TimeInterval = 3600
}

// MARK: - Pairing messages

enum PairMessage: Equatable {
    /// iPhone → Mac: the iPhone's ephemeral P-256 public key (65 bytes, X9.63) and its name,
    /// so the Mac can ask "Pair with …?". The name is only shown, never trusted.
    case hello(phoneKey: Data, phoneName: String)
    /// Mac → iPhone: the Mac's public key and a commitment to its nonce.
    case commit(macKey: Data, commitment: Data)
    /// iPhone → Mac: the iPhone's nonce (16 bytes).
    case phoneNonce(Data)
    /// Mac → iPhone: the Mac's nonce, revealed only after it has seen the iPhone's.
    /// Both sides can now work out the code, and both show it.
    case macNonce(Data)
    /// iPhone → Mac, when the user pressed Pair on the iPhone: proof it holds the new key.
    case phoneConfirm(proof: Data, phoneName: String)
    /// Mac → iPhone, when the user pressed Pair on the Mac: the Mac's proof, plus the pairing
    /// ID and the Mac's name. Each side saves the pairing once it has both Pair presses.
    case macConfirm(proof: Data, pairingID: Data, macName: String)
    /// Either way: pairing stopped. The text is shown to the user.
    case failed(String)
    /// iPhone → Mac, once paired and subscribed to events: "resend the recent notifications".
    /// The iPhone sends this on every connect, because iOS can keep the subscription alive
    /// while the app restarts, so the Mac can't tell the app missed anything.
    case catchUp
    /// iPhone → Mac, on every connect once paired: "prove you hold our key" (a fresh nonce).
    case verify(nonce: Data)
    /// Mac → iPhone: the answer to `verify`, plus the Mac's own nonce for the iPhone to answer.
    case verified(proof: Data, macNonce: Data)
    /// iPhone → Mac: the answer to the Mac's nonce. Until this arrives the Mac sends that
    /// iPhone nothing.
    case phoneVerified(proof: Data)

    static let keyLength = 65, nonceLength = 16, proofLength = 32, pairingIDLength = 16

    var encoded: Data {
        switch self {
        case .hello(let key, let name): return Data([0x01]) + key + Self.text(name)
        case .commit(let key, let commitment): return Data([0x02]) + key + commitment
        case .phoneNonce(let nonce): return Data([0x03]) + nonce
        case .macNonce(let nonce): return Data([0x04]) + nonce
        case .phoneConfirm(let proof, let name): return Data([0x05]) + proof + Self.text(name)
        case .macConfirm(let proof, let id, let name): return Data([0x06]) + proof + id + Self.text(name)
        case .failed(let reason): return Data([0x7F]) + Self.text(reason, limit: 120)
        case .catchUp: return Data([0x10])
        case .verify(let nonce): return Data([0x11]) + nonce
        case .verified(let proof, let nonce): return Data([0x12]) + proof + nonce
        case .phoneVerified(let proof): return Data([0x13]) + proof
        }
    }

    init?(_ data: Data) {
        guard let type = data.first else { return nil }
        let body = Data(data.dropFirst())
        func slice(_ from: Int, _ count: Int) -> Data? {
            body.count >= from + count ? body.subdata(in: from ..< from + count) : nil
        }
        func rest(_ from: Int) -> String { String(decoding: body.dropFirst(from), as: UTF8.self) }
        let k = Self.keyLength, n = Self.nonceLength, p = Self.proofLength, i = Self.pairingIDLength
        switch type {
        case 0x01:
            guard let key = slice(0, k) else { return nil }
            self = .hello(phoneKey: key, phoneName: rest(k))
        case 0x02:
            guard body.count == k + 32, let key = slice(0, k), let c = slice(k, 32) else { return nil }
            self = .commit(macKey: key, commitment: c)
        case 0x03:
            guard body.count == n else { return nil }
            self = .phoneNonce(body)
        case 0x04:
            guard body.count == n else { return nil }
            self = .macNonce(body)
        case 0x05:
            guard let proof = slice(0, p) else { return nil }
            self = .phoneConfirm(proof: proof, phoneName: rest(p))
        case 0x06:
            guard let proof = slice(0, p), let id = slice(p, i) else { return nil }
            self = .macConfirm(proof: proof, pairingID: id, macName: rest(p + i))
        case 0x7F:
            self = .failed(rest(0))
        case 0x10:
            self = .catchUp
        case 0x11:
            guard body.count == n else { return nil }
            self = .verify(nonce: body)
        case 0x12:
            guard body.count == p + n, let proof = slice(0, p), let nonce = slice(p, n) else { return nil }
            self = .verified(proof: proof, macNonce: nonce)
        case 0x13:
            guard body.count == p else { return nil }
            self = .phoneVerified(proof: body)
        default:
            return nil
        }
    }

    /// UTF-8, cut at a character boundary so it stays short enough for one BLE packet.
    private static func text(_ s: String, limit: Int = 40) -> Data {
        var out = ""
        for ch in s where out.utf8.count + String(ch).utf8.count <= limit { out.append(ch) }
        return Data(out.utf8)
    }
}

// MARK: - Pairing crypto

enum PairingCrypto {
    /// SystemRandomNumberGenerator is cryptographically secure on Apple platforms.
    static func randomBytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
    }

    /// Binds the Mac to its nonce before it sees the iPhone's, so a man in the middle
    /// can't pick nonces to force a matching code.
    static func commitment(macKey: Data, phoneKey: Data, macNonce: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: macKey + phoneKey, using: SymmetricKey(data: macNonce)))
    }

    /// The 6-digit code both sides show/check. Depends on both keys and both nonces.
    static func code(phoneKey: Data, macKey: Data, phoneNonce: Data, macNonce: Data) -> String {
        let digest = SHA256.hash(data: Data("altiro-code-v1".utf8) + phoneKey + macKey + phoneNonce + macNonce)
        let value = digest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return String(format: "%06u", value % 1_000_000)
    }

    /// The long-term key both sides store after pairing.
    static func pairingKey(secret: SharedSecret, phoneKey: Data, macKey: Data,
                           phoneNonce: Data, macNonce: Data) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: phoneNonce + macNonce,
                                       sharedInfo: Data("altiro-pairing-v1".utf8) + phoneKey + macKey,
                                       outputByteCount: 32)
    }

    /// Proof that a side holds the pairing key. `role` is "phone" or "mac".
    static func proof(_ role: String, key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("altiro-confirm-\(role)".utf8), using: key))
    }

    static func checkProof(_ proof: Data, role: String, key: SymmetricKey) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: Data("altiro-confirm-\(role)".utf8), using: key)
    }

    /// One side's answer to the other's reconnect nonce. `role` is the side answering, "mac" or
    /// "phone". Uses its own key derived from the pairing key, so it can't be confused with the
    /// pairing proofs or the event key.
    static func verifyProof(_ role: String, nonce: Data, pairingKey: SymmetricKey) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: pairingKey, info: Data("altiro-verify-v1".utf8),
                                         outputByteCount: 32)
        return Data(HMAC<SHA256>.authenticationCode(for: Data("altiro-verify-\(role)".utf8) + nonce, using: key))
    }

    static func checkVerifyProof(_ proof: Data, role: String, nonce: Data, pairingKey: SymmetricKey) -> Bool {
        let expected = verifyProof(role, nonce: nonce, pairingKey: pairingKey)
        // Constant-time comparison.
        return proof.count == expected.count && zip(proof, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// "482913" → "482 913"
    static func display(_ code: String) -> String { "\(code.prefix(3)) \(code.suffix(3))" }
}

// MARK: - Notifications

struct MacNotification: Codable, Equatable {
    /// Unique per notification; the iPhone uses it to drop duplicates and replays.
    let id: String
    /// App name as shown on the Mac, e.g. "Mail".
    let app: String
    let bundleID: String
    /// Notification title (e.g. the sender), if it had one. Never the body text.
    let title: String?
    /// Subtitle (e.g. a group chat or mail subject), if it had one. Optional on the wire, so
    /// older builds that don't send it still decode.
    var subtitle: String? = nil
    /// When macOS delivered it.
    let date: Date
}

enum EventCrypto {
    static func eventKey(pairingKey: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: pairingKey, info: Data("altiro-events-v1".utf8), outputByteCount: 32)
    }

    static func seal(_ notification: MacNotification, key: SymmetricKey) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try ChaChaPoly.seal(encoder.encode(notification), using: key).combined
    }

    static func open(_ data: Data, key: SymmetricKey) throws -> MacNotification {
        let plain = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: data), using: key)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(MacNotification.self, from: plain)
    }
}

// MARK: - Chunking

/// One BLE notification carries ~180 bytes, so a sealed event is split into chunks:
/// [message tag, index << 4 | (count - 1)] + payload. At most 16 chunks per message.
enum Chunker {
    static let headerLength = 2, maxChunks = 16

    static func split(_ data: Data, tag: UInt8, maxPacket: Int) -> [Data]? {
        let size = max(1, maxPacket - headerLength)
        let count = max(1, (data.count + size - 1) / size)
        guard count <= maxChunks else { return nil }
        return (0..<count).map { i in
            let part = data.subdata(in: i * size ..< min(data.count, (i + 1) * size))
            return Data([tag, UInt8(i << 4 | (count - 1))]) + part
        }
    }
}

/// Collects chunks from `Chunker` back into whole messages.
final class Reassembler {
    private var tag: UInt8?
    private var parts: [Data?] = []

    /// Returns the whole message once its last missing chunk arrives.
    func add(_ chunk: Data) -> Data? {
        guard chunk.count >= Chunker.headerLength else { return nil }
        let bytes = [UInt8](chunk.prefix(Chunker.headerLength))
        let index = Int(bytes[1] >> 4), count = Int(bytes[1] & 0x0F) + 1
        // A chunk can't sit past the end of its own message; drop it rather than trust it.
        guard index < count else { return nil }
        if tag != bytes[0] || parts.count != count {
            tag = bytes[0]
            parts = Array(repeating: nil, count: count)
        }
        parts[index] = Data(chunk.dropFirst(Chunker.headerLength))
        guard parts.allSatisfy({ $0 != nil }) else { return nil }
        let whole = parts.reduce(Data()) { $0 + $1! }
        tag = nil
        parts = []
        return whole
    }
}
