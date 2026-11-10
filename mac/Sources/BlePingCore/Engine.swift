import AppKit
import CoreBluetooth
import CryptoKit
import Foundation

/// Runs bleping: advertises over Bluetooth, pairs with the iPhone, watches Notification
/// Center and sends each new notification (app and title only, encrypted) to the iPhone.
/// Used by both the CLI and the menu bar app. Everything happens on the main queue.
public final class Engine {
    public struct Options {
        /// How often to check Notification Center's database, in seconds.
        public var interval: TimeInterval = 1
        /// Only forward these bundle IDs (empty: all).
        public var only: Set<String> = []
        /// Never forward these bundle IDs.
        public var ignore: Set<String> = []
        /// Keep the last hour's notifications and resend them when the iPhone reconnects.
        /// When off, notifications that arrive while the iPhone is away are skipped.
        public var catchUp = true

        public init() {}
    }

    public enum Bluetooth: Equatable {
        case starting, on, off, unauthorized, unsupported, unavailable
    }

    public enum Pairing: Equatable {
        /// Waiting for the iPhone to connect.
        case waiting
        /// The iPhone connected; keys are being exchanged.
        case exchanging
        /// Ask the user to type the code shown on the iPhone named `phoneName`. `error` says why
        /// the last try was wrong.
        case enterCode(phoneName: String, error: String?)
        case failed(String)
    }

    public enum Delivery: Equatable {
        /// Sent to the connected iPhone.
        case sent
        /// The iPhone wasn't connected; it gets this when it reconnects (within an hour).
        case queued
        /// The iPhone wasn't connected and catching up is off, so it was skipped.
        case skipped
        /// No iPhone paired.
        case notPaired
    }

    public struct Forwarded: Identifiable, Equatable {
        public let id: String
        public let app: String
        public let bundleID: String
        public let title: String?
        public let subtitle: String?
        public let date: Date
        public let delivery: Delivery
    }

    public struct Phone: Equatable {
        public let name: String
        public let pairedAt: Date
    }

    // MARK: State (read it in onChange)

    public private(set) var bluetooth = Bluetooth.starting
    public private(set) var phone: Phone?
    public var phoneConnected: Bool { peripheral.connectedPhones > 0 }
    /// Non-nil while pairing mode is on.
    public private(set) var pairing: Pairing?
    /// Why notifications aren't being watched (usually missing Full Disk Access), or nil.
    public private(set) var watchError: String?
    /// The most recent notifications, newest first.
    public private(set) var forwarded: [Forwarded] = []

    /// Called on the main queue whenever any state above changes.
    public var onChange: (() -> Void)?
    /// Log lines, for the CLI's output or a log view. `personal` marks lines that quote a
    /// notification's text or a device's name: keep those out of the system log.
    public var onLog: ((_ line: String, _ personal: Bool) -> Void)? {
        didSet { logHandler = { [weak self] line, personal in self?.onLog?(line, personal) } }
    }

    public var options: Options {
        didSet { if !options.catchUp { recent.removeAll() } }
    }

    private let peripheral = Peripheral()
    private var paired: PairedPhone?
    private var eventKey: SymmetricKey?
    private var session: PairingSession?
    private var watcher: NotificationWatcher?
    private var timer: DispatchSourceTimer?
    /// What gets replayed to an iPhone that reconnects.
    private var recent: [MacNotification] = []
    private let maxRecent = 20
    private let maxForwarded = 50

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Where the pairing key is kept.
    public static var pairingFile: URL { PairingStore.url }

    /// Forgets the paired iPhone without starting Bluetooth (for `bleping unpair`).
    public static func forgetPairing() throws {
        try PairingStore.delete()
    }

    public func start() {
        use(PairingStore.load())
        if let paired {
            log("Paired with \"\(paired.phoneName)\" since \(DateFormatter.localizedString(from: paired.pairedAt, dateStyle: .medium, timeStyle: .short))", personal: true)
        }

        peripheral.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .poweredOn: bluetooth = .on
            case .poweredOff: bluetooth = .off
            case .unauthorized: bluetooth = .unauthorized
            case .unsupported: bluetooth = .unsupported
            case .resetting, .unknown: bluetooth = .starting
            @unknown default: bluetooth = .unavailable
            }
            changed()
        }
        peripheral.onSubscribersChanged = { [weak self] in self?.changed() }
        peripheral.onPairingMessage = { [weak self] data, central in
            guard let self else { return }
            if case .catchUp? = PairMessage(data) {
                log(options.catchUp ? "iPhone asked for missed notifications"
                                    : "iPhone asked for missed notifications (ignored: sending missed notifications is off)")
                replay(to: central)
            } else if case .verify(let nonce)? = PairMessage(data) {
                // The iPhone checks it found *its* Mac before trusting the connection.
                if let paired {
                    peripheral.sendPairing(.verified(proof: PairingCrypto.verifyProof(
                        nonce: nonce, pairingKey: paired.pairingKey)), to: central)
                } else {
                    peripheral.sendPairing(.failed("This Mac isn't paired with an iPhone."), to: central)
                }
            } else if let session {
                session.handle(data, from: central)
            } else if case .hello? = PairMessage(data) {
                peripheral.sendPairing(.failed("This Mac isn't in pairing mode. Run `bleping pair` on it."), to: central)
            }
        }

        startWatching()
    }

    // MARK: Pairing

    public func startPairing() {
        // An iPhone is already exchanging keys or showing the code: don't throw that away.
        switch pairing {
        case .exchanging?, .enterCode?: return
        default: break
        }
        let session = PairingSession(peripheral: peripheral) { [weak self] phone in
            guard let self else { return }
            use(phone)
            self.session = nil
            pairing = nil
            changed()
        }
        session.onProgress = { [weak self] progress in
            guard let self else { return }
            switch progress {
            case .phoneConnecting: pairing = .exchanging
            case .enterCode(let name, let error): pairing = .enterCode(phoneName: name, error: error)
            case .failed(let reason): pairing = .failed(reason)
            }
            changed()
        }
        self.session = session
        pairing = .waiting
        log("""
            Pairing mode. On your iPhone, open bleping and tap "Pair with Mac".
              Then type the 6-digit code it shows here.
            """)
        changed()
    }

    /// The user typed the code shown on the iPhone.
    public func submitCode(_ code: String) {
        session?.submitCode(code)
    }

    public func cancelPairing() {
        session = nil
        pairing = nil
        changed()
    }

    public func unpair() {
        do {
            try PairingStore.delete()
        } catch {
            log("Could not remove \(PairingStore.url.path): \(error.localizedDescription)")
        }
        use(nil)
        log("Forgot the paired iPhone")
        changed()
    }

    private func use(_ phone: PairedPhone?) {
        paired = phone
        self.phone = phone.map { Phone(name: $0.phoneName, pairedAt: $0.pairedAt) }
        eventKey = phone.map { EventCrypto.eventKey(pairingKey: $0.pairingKey) }
    }

    // MARK: Notifications

    /// Sends a test notification and returns its ID, to find it in `forwarded`.
    @discardableResult
    public func sendTest() -> String {
        let id = "test-\(UUID().uuidString)"
        let now = Date()
        let time = DateFormatter.localizedString(from: now, dateStyle: .none, timeStyle: .short)
        send(MacNotification(id: id, app: "bleping", bundleID: "dev.bleping.mac",
                             title: "Test notification", subtitle: "From \(macName) · \(time)", date: now))
        return id
    }

    /// Tries to open Notification Center's database again (after granting Full Disk Access).
    public func startWatching() {
        timer?.cancel()
        timer = nil
        do {
            let watcher = try NotificationWatcher()
            self.watcher = watcher
            watchError = nil
            log("Watching notifications.")
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + options.interval, repeating: options.interval)
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
        } catch {
            watcher = nil
            watchError = "\(error)"
            log("\(error)\nNot watching notifications; pairing and test notifications still work.")
        }
        changed()
    }

    private func poll() {
        guard let watcher else { return }
        do {
            for n in try watcher.poll()
            where (options.only.isEmpty || options.only.contains(n.bundleID)) && !options.ignore.contains(n.bundleID) {
                send(MacNotification(id: "n\(n.recordID)", app: appName(for: n.bundleID) ?? n.bundleID,
                                     bundleID: n.bundleID, title: n.title.map { String($0.prefix(120)) },
                                     subtitle: n.subtitle.map { String($0.prefix(120)) }, date: n.date))
            }
        } catch {
            log("\(error)")
        }
    }

    private func send(_ notification: MacNotification) {
        if options.catchUp {
            recent.append(notification)
            prune()
        }
        let text = [notification.title, notification.subtitle].compactMap { $0 }.map { "\"\($0)\"" }
        let describe = notification.app + (text.isEmpty ? "" : ": " + text.joined(separator: " · "))
        let delivery: Delivery
        if let eventKey {
            if peripheral.connectedPhones > 0 {
                do {
                    peripheral.sendEvent(try EventCrypto.seal(notification, key: eventKey))
                    log("\(describe) → sent to iPhone (encrypted)", personal: true)
                    delivery = .sent
                } catch {
                    log("Could not encrypt notification: \(error)")
                    delivery = .queued
                }
            } else if options.catchUp {
                log("\(describe) → iPhone not connected; it gets this when it reconnects (within 1 h)", personal: true)
                delivery = .queued
            } else {
                log("\(describe) → iPhone not connected; skipped (catching up is off)", personal: true)
                delivery = .skipped
            }
        } else {
            log("\(describe) (not sent: no iPhone paired)", personal: true)
            delivery = .notPaired
        }
        forwarded.insert(Forwarded(id: notification.id, app: notification.app, bundleID: notification.bundleID,
                                   title: notification.title,
                                   subtitle: notification.subtitle, date: notification.date, delivery: delivery), at: 0)
        if forwarded.count > maxForwarded { forwarded.removeLast(forwarded.count - maxForwarded) }
        changed()
    }

    /// Sends the recent notifications to an iPhone that asked to catch up after connecting.
    /// It drops the ones it already has.
    private func replay(to central: CBCentral) {
        guard options.catchUp else { return }
        prune()
        guard let eventKey, !recent.isEmpty else { return }
        for notification in recent {
            if let sealed = try? EventCrypto.seal(notification, key: eventKey) {
                peripheral.sendEvent(sealed, to: central)
            }
        }
        log("Resent the last \(recent.count) notification(s) so the iPhone can catch up")
        // Anything that was waiting has now reached the iPhone.
        let ids = Set(recent.map(\.id))
        forwarded = forwarded.map {
            $0.delivery == .queued && ids.contains($0.id)
                ? Forwarded(id: $0.id, app: $0.app, bundleID: $0.bundleID, title: $0.title, subtitle: $0.subtitle, date: $0.date,
                            delivery: .sent) : $0
        }
        changed()
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Wire.replayWindow)
        recent.removeAll { $0.date < cutoff }
        if recent.count > maxRecent { recent.removeFirst(recent.count - maxRecent) }
    }

    private func changed() {
        onChange?()
    }
}

/// "Script Editor" for "com.apple.scripteditor2", if the app is installed.
func appName(for bundleID: String) -> String? {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
    let name = FileManager.default.displayName(atPath: url.path)
    return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
}
