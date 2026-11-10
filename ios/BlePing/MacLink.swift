import CoreBluetooth
import CryptoKit
import UIKit
import UserNotifications

struct ReceivedNotification: Identifiable {
    let id: String
    let app: String
    let bundleID: String
    let title: String?
    let subtitle: String?
    let date: Date
}

enum PairingStep: Equatable {
    /// Looking for a Mac running `bleping pair`.
    case searching
    /// Connected, exchanging keys.
    case exchanging
    /// The Mac shows a code; waiting for the user to type it.
    case enterCode
    /// Code matched; waiting for the Mac to confirm.
    case confirming
    /// Done: paired with the Mac of this name. Shown briefly before the sheet closes.
    case paired(String)
    case failed(String)
}

/// The iPhone's side of the BLE link. Finds the Mac, pairs with it once, then stays
/// connected and turns each encrypted event into a local notification. iOS keeps the
/// connection while the app is in the background and wakes it when an event arrives.
final class MacLink: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = MacLink()

    /// Why Bluetooth can't be used, or nil when it's on.
    /// Why Bluetooth can't be used, or nil when it's on (or not started yet).
    @Published private(set) var bluetoothProblem: String?
    /// The user said no to Bluetooth; the fix is in Settings.
    @Published private(set) var bluetoothDenied = false
    @Published private(set) var connected = false
    @Published private(set) var paired: PairedMac? = PairedMacStore.load()
    @Published private(set) var pairingStep: PairingStep?
    @Published var codeError: String?
    @Published private(set) var history: [ReceivedNotification] = []
    /// What the Bluetooth side is doing, newest last. Shown on screen to diagnose connection problems.
    @Published private(set) var debugLog: [String] = []

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func dbg(_ message: String) {
        let line = "\(Self.clock.string(from: Date())) \(message)"
        print("bleping: \(line)")
        debugLog.append(line)
        if debugLog.count > 40 { debugLog.removeFirst(debugLog.count - 40) }
    }

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    /// Other bleping Macs (not ours, or not in pairing mode), skipped for a minute.
    private var skipped: [UUID: Date] = [:]
    private let reassembler = Reassembler()
    private var exchange: Exchange?

    /// The iPhone's half of one pairing attempt.
    private struct Exchange {
        let phonePrivate = P256.KeyAgreement.PrivateKey()
        let phoneNonce = PairingCrypto.randomBytes(PairMessage.nonceLength)
        var macKey: Data?
        var commitment: Data?
        var code: String?
        var key: SymmetricKey?
        var phoneKey: Data { phonePrivate.publicKey.x963Representation }
    }

    /// Starts Bluetooth. The first call shows iOS's Bluetooth permission prompt, so it happens
    /// when the user taps Pair, or at launch once already paired.
    func start() {
        guard central == nil else { return }
        bluetoothProblem = "Starting Bluetooth…"
        // The restore identifier lets iOS relaunch the app in the background for Bluetooth
        // events after the system has suspended or killed it.
        central = CBCentralManager(delegate: self, queue: nil,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: "bleping.central"])
    }

    // MARK: Actions from the UI

    func startPairing() {
        start()
        dbg("Pair tapped")
        disconnect()
        central?.stopScan()
        skipped = [:]
        exchange = Exchange()
        codeError = nil
        pairingStep = .searching
        scan()
    }

    func cancelPairing() {
        // Closing the success screen: keep the new connection.
        if case .paired? = pairingStep {
            pairingStep = nil
            return
        }
        if exchange != nil, pairingStep != .searching { write(.failed("Cancelled on the iPhone")) }
        exchange = nil
        pairingStep = nil
        disconnect()
        scan()
    }

    func submitCode(_ text: String) {
        guard let exchange, let code = exchange.code, let key = exchange.key else { return }
        guard text.filter(\.isNumber) == code else {
            codeError = "That doesn't match the code on your Mac. Check it and try again."
            return
        }
        codeError = nil
        pairingStep = .confirming
        write(.phoneConfirm(proof: PairingCrypto.proof("phone", key: key), phoneName: UIDevice.current.name))
    }

    func clearHistory() {
        history = []
    }

    func unpair() {
        PairedMacStore.delete()
        paired = nil
        disconnect()
        central?.stopScan()
    }

    // MARK: Connection

    private var wantsConnection: Bool { paired != nil || pairingStep == .searching }

    private func scan() {
        guard let central else { return dbg("scan: no central manager") }
        guard central.state == .poweredOn else { return dbg("scan: Bluetooth not on yet (\(central.state.rawValue))") }
        guard peripheral == nil else { return dbg("scan: already have a Mac (\(peripheral!.state.rawValue))") }
        guard wantsConnection else { return dbg("scan: not paired and not pairing; idle") }
        dbg("Scanning for bleping service…")
        central.scanForPeripherals(withServices: [Wire.serviceUUID], options: nil)
    }

    private func disconnect() {
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        characteristics = [:]
        connected = false
    }

    /// Not the Mac we want: drop it and keep looking.
    private func skip(_ p: CBPeripheral, _ why: String = "") {
        dbg("Skipping \(p.name ?? p.identifier.uuidString.prefix(8).description) \(why)")
        skipped[p.identifier] = Date()
        disconnect()
        scan()
    }

    private func lost(_ p: CBPeripheral, _ error: Error? = nil) {
        dbg("Connection lost/failed: \(error?.localizedDescription ?? "no error")")
        guard p.identifier == peripheral?.identifier else { return }
        peripheral = nil
        characteristics = [:]
        connected = false
        switch pairingStep {
        case .exchanging?, .enterCode?, .confirming?:
            failPairing("Lost the connection to the Mac. Try again.")
        default:
            break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.scan() }
    }

    private func write(_ message: PairMessage) {
        guard let peripheral, let c = characteristics[Wire.pairingUUID] else { return dbg("write: not connected") }
        dbg("→ Mac: message 0x\(String(format: "%02x", message.encoded.first ?? 0)) (\(message.encoded.count) bytes)")
        peripheral.writeValue(message.encoded, for: c, type: .withResponse)
    }

    // MARK: Pairing

    private func handlePairing(_ message: PairMessage?, from p: CBPeripheral) {
        dbg("← Mac: \(message.map { "\($0)".prefix(30).description } ?? "unreadable message")")
        guard var ex = exchange, let message else { return }
        switch message {
        case .commit(let macKey, let commitment):
            guard pairingStep == .exchanging else { return }
            ex.macKey = macKey
            ex.commitment = commitment
            exchange = ex
            write(.phoneNonce(ex.phoneNonce))

        case .macNonce(let macNonce):
            guard let macKey = ex.macKey, let commitment = ex.commitment else { return }
            // The Mac committed to this nonce before seeing ours; check it kept its word.
            guard PairingCrypto.commitment(macKey: macKey, phoneKey: ex.phoneKey, macNonce: macNonce) == commitment,
                  let macPublic = try? P256.KeyAgreement.PublicKey(x963Representation: macKey),
                  let secret = try? ex.phonePrivate.sharedSecretFromKeyAgreement(with: macPublic) else {
                write(.failed("Security check failed"))
                return failPairing("Security check failed. Try again.")
            }
            ex.key = PairingCrypto.pairingKey(secret: secret, phoneKey: ex.phoneKey, macKey: macKey,
                                              phoneNonce: ex.phoneNonce, macNonce: macNonce)
            ex.code = PairingCrypto.code(phoneKey: ex.phoneKey, macKey: macKey,
                                         phoneNonce: ex.phoneNonce, macNonce: macNonce)
            exchange = ex
            pairingStep = .enterCode

        case .macConfirm(let proof, let pairingID, let macName):
            guard let key = ex.key, PairingCrypto.checkProof(proof, role: "mac", key: key) else {
                return failPairing("The Mac's confirmation didn't check out. Try again.")
            }
            let mac = PairedMac(key: key.withUnsafeBytes { Data($0) }, pairingID: pairingID,
                                macName: macName.isEmpty ? "Mac" : macName, pairedAt: Date())
            do {
                try PairedMacStore.save(mac)
            } catch {
                return failPairing("Could not save the pairing: \(error.localizedDescription)")
            }
            paired = mac
            exchange = nil
            pairingStep = .paired(mac.macName)
            // Close the success screen by itself after a moment (unless the user already did).
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                if case .paired? = self?.pairingStep { self?.pairingStep = nil }
            }
            // Already connected to the right Mac: go straight to receiving notifications.
            if let id = characteristics[Wire.pairingIDUUID] { p.readValue(for: id) }

        case .failed(let reason):
            if pairingStep == .exchanging, reason.contains("pairing mode") {
                // Another bleping Mac that isn't pairing. Keep looking for the one that is.
                pairingStep = .searching
                exchange = Exchange()
                skip(p)
            } else {
                failPairing(reason)
            }

        default:
            break
        }
    }

    private func failPairing(_ reason: String) {
        pairingStep = .failed(reason)
        exchange = nil
        disconnect()
    }

    // MARK: Notifications

    private func receive(_ sealed: Data) {
        guard let paired else { return dbg("Event ignored: not paired") }
        let n: MacNotification
        do {
            n = try EventCrypto.open(sealed, key: paired.eventKey)
        } catch {
            return dbg("Event could not be decrypted (\(sealed.count) bytes): \(error)")
        }
        // Drop repeats (the Mac resends recent ones on reconnect) and anything stale.
        guard n.date > Date().addingTimeInterval(-Wire.replayWindow) else { return dbg("Event \(n.id) too old; dropped") }
        guard markSeen(n.id) else { return dbg("Event \(n.id) already shown; dropped") }
        dbg("Event \(n.id) from \(n.app): showing notification")
        history.insert(ReceivedNotification(id: n.id, app: n.app, bundleID: n.bundleID, title: n.title, subtitle: n.subtitle, date: n.date),
                       at: 0)
        if history.count > 100 { history.removeLast() }

        let content = UNMutableNotificationContent()
        // Shown as:  Mail
        //            Ana García          (title)
        //            Dinner on Friday    (subtitle)
        content.title = n.app
        switch (n.title, n.subtitle) {
        case let (title?, subtitle?):
            content.subtitle = title
            content.body = subtitle
        case let (title?, nil), let (nil, title?):
            content.body = title
        case (nil, nil):
            content.body = "New notification on your Mac"
        }
        content.sound = .default
        content.threadIdentifier = n.bundleID
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: n.id, content: content, trigger: nil)) { [weak self] error in
            if let error { DispatchQueue.main.async { self?.dbg("Could not post notification: \(error.localizedDescription)") } }
        }
    }

    /// Records a notification ID; false if it was already seen. Persisted, so a relaunch
    /// doesn't re-announce what the Mac replays.
    private func markSeen(_ id: String) -> Bool {
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        var seen = (defaults.dictionary(forKey: "seenNotifications") as? [String: Double] ?? [:])
            .filter { now - $0.value < 2 * Wire.replayWindow }
        guard seen[id] == nil else { return false }
        seen[id] = now
        defaults.set(seen, forKey: "seenNotifications")
        return true
    }

    // MARK: CBCentralManagerDelegate

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let p = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first {
            peripheral = p
            p.delegate = self
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothDenied = central.state == .unauthorized
        dbg("Bluetooth state: \(central.state.rawValue) (5 = on, 3 = unauthorized, 4 = off)")
        switch central.state {
        case .poweredOn:
            bluetoothProblem = nil
            if let p = peripheral {
                // Restored after a background relaunch.
                if p.state == .connected { p.discoverServices([Wire.serviceUUID]) } else { central.connect(p) }
            } else {
                scan()
            }
        case .poweredOff: bluetoothProblem = "Bluetooth is off"
        case .unauthorized: bluetoothProblem = "bleping isn't allowed to use Bluetooth"
        case .unsupported: bluetoothProblem = "This device doesn't support Bluetooth LE"
        default: bluetoothProblem = "Waiting for Bluetooth…"
        }
        if central.state != .poweredOn {
            peripheral = nil
            characteristics = [:]
            connected = false
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        skipped = skipped.filter { Date().timeIntervalSince($0.value) < 60 }
        dbg("Found \(p.name ?? "?") RSSI \(RSSI)\(skipped[p.identifier] != nil ? " (skipped recently)" : "")")
        guard peripheral == nil, skipped[p.identifier] == nil else { return }
        dbg("Connecting…")
        central.stopScan()
        peripheral = p
        p.delegate = self
        central.connect(p)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        dbg("Connected; discovering services")
        p.discoverServices([Wire.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        lost(p, error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        lost(p, error)
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        dbg("Services: \(p.services?.map { String($0.uuid.uuidString.prefix(8)) } ?? []) \(error?.localizedDescription ?? "")")
        guard let service = p.services?.first(where: { $0.uuid == Wire.serviceUUID }) else { return skip(p, "(no bleping service)") }
        p.discoverCharacteristics([Wire.pairingUUID, Wire.eventsUUID, Wire.pairingIDUUID], for: service)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] { characteristics[c.uuid] = c }
        dbg("Characteristics: \(characteristics.count) \(error?.localizedDescription ?? ""); step \(pairingStep.map { "\($0)" } ?? "none"), paired \(paired != nil)")
        if pairingStep == .searching, let pairingChar = characteristics[Wire.pairingUUID] {
            // Listen for the Mac's answers first; the hello goes out once that's on.
            p.setNotifyValue(true, for: pairingChar)
        } else if paired != nil, let id = characteristics[Wire.pairingIDUUID] {
            p.readValue(for: id)   // is this our Mac?
        } else {
            skip(p, "(not pairing and not paired)")
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        dbg("Notify \(c.uuid.uuidString.prefix(8)) = \(c.isNotifying) \(error?.localizedDescription ?? "")")
        if error != nil { return skip(p, "(subscribe failed)") }
        if c.uuid == Wire.pairingUUID, c.isNotifying, pairingStep == .searching, let exchange {
            pairingStep = .exchanging
            write(.hello(phoneKey: exchange.phoneKey))
        } else if c.uuid == Wire.eventsUUID, c.isNotifying {
            connected = true
            write(.catchUp)   // get whatever arrived while we were away or restarting
        }
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        if let error { dbg("Write failed: \(error.localizedDescription)") }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if let error { dbg("Read/notify error: \(error.localizedDescription)") }
        guard error == nil, let value = c.value else { return }
        switch c.uuid {
        case Wire.pairingIDUUID:
            if let paired, value == paired.pairingID, let events = characteristics[Wire.eventsUUID] {
                p.setNotifyValue(true, for: events)
            } else if pairingStep == nil {
                skip(p, "(pairing ID doesn't match)")   // a different Mac, or ours was unpaired on the Mac side
            }
        case Wire.pairingUUID:
            handlePairing(PairMessage(value), from: p)
        case Wire.eventsUUID:
            dbg("Event chunk: \(value.count) bytes")
            if let whole = reassembler.add(value) { receive(whole) }
        default:
            break
        }
    }
}
