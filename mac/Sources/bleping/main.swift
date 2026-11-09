import AppKit
import CoreBluetooth
import CryptoKit
import Foundation

func log(_ message: String) {
    let ts = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
    // Indent continuation lines so multi-line messages line up under the text.
    let body = message.replacingOccurrences(of: "\n", with: "\n" + String(repeating: " ", count: ts.count + 3))
    print("[\(ts)] \(body)")
    fflush(stdout)
}

// MARK: - Options

struct Options {
    enum Command { case run, pair, unpair }
    var command = Command.run
    var interval: TimeInterval = 1
    var only: Set<String> = []
    var ignore: Set<String> = []
    var test = false

    static let usage = """
        usage: bleping [pair | unpair] [options]

          bleping            forward Mac notifications to the paired iPhone
          bleping pair       pair with the iPhone app (shows a 6-digit code), then keep forwarding
          bleping unpair     forget the paired iPhone

          --interval SEC     how often to check for new notifications (default 1)
          --only IDS         comma-separated bundle IDs to forward (default: all)
          --ignore IDS       comma-separated bundle IDs to skip
          --test             send a test notification at startup
          -h, --help         show this help
        """

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var it = args.makeIterator()
        func value(_ flag: String) -> String {
            guard let v = it.next() else { fail("\(flag) needs a value") }
            return v
        }
        func ids(_ s: String) -> Set<String> {
            Set(s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
        while let arg = it.next() {
            switch arg {
            case "pair": o.command = .pair
            case "unpair": o.command = .unpair
            case "--interval":
                let s = value(arg)
                guard let v = TimeInterval(s), v > 0 else { fail("bad value for --interval: \(s)") }
                o.interval = v
            case "--only": o.only = ids(value(arg))
            case "--ignore": o.ignore = ids(value(arg))
            case "--test": o.test = true
            case "-h", "--help": print(usage); exit(0)
            default: fail("unknown option \(arg)")
            }
        }
        return o
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n\n" + Options.usage + "\n").data(using: .utf8)!)
    exit(2)
}

/// "Script Editor" for "com.apple.scripteditor2", if the app is installed.
func appName(for bundleID: String) -> String? {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
    let name = FileManager.default.displayName(atPath: url.path)
    return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
}

// MARK: - Relay

/// Encrypts notifications for the paired iPhone and keeps the last hour's, so an iPhone
/// that was out of range gets them when it reconnects.
final class Relay {
    private let peripheral: Peripheral
    private var key: SymmetricKey?
    private var recent: [MacNotification] = []
    private let maxRecent = 20

    init(peripheral: Peripheral) {
        self.peripheral = peripheral
    }

    func use(_ phone: PairedPhone?) {
        key = phone.map { EventCrypto.eventKey(pairingKey: $0.pairingKey) }
        peripheral.pairingID = phone?.pairingID ?? Data()
    }

    func send(_ notification: MacNotification) {
        recent.append(notification)
        prune()
        let describe = "\(notification.app)\(notification.title.map { ": \"\($0)\"" } ?? "")"
        guard let key else {
            log("\(describe) (not sent: no iPhone paired)")
            return
        }
        guard peripheral.connectedPhones > 0 else {
            log("\(describe) → iPhone not connected; it gets this when it reconnects (within 1 h)")
            return
        }
        do {
            peripheral.sendEvent(try EventCrypto.seal(notification, key: key))
            log("\(describe) → sent to iPhone (encrypted)")
        } catch {
            log("Could not encrypt notification: \(error)")
        }
    }

    /// Sends the recent notifications to an iPhone that just connected. It drops the ones it already has.
    func replay(to central: CBCentral) {
        prune()
        guard let key, !recent.isEmpty else { return }
        for notification in recent {
            if let sealed = try? EventCrypto.seal(notification, key: key) {
                peripheral.sendEvent(sealed, to: central)
            }
        }
        log("Resent the last \(recent.count) notification(s) so the iPhone can catch up")
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Wire.replayWindow)
        recent.removeAll { $0.date < cutoff }
        if recent.count > maxRecent { recent.removeFirst(recent.count - maxRecent) }
    }
}

// MARK: - Main

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))

if options.command == .unpair {
    do {
        try PairingStore.delete()
        print("Forgot the paired iPhone. Run `bleping pair` to pair again (and tap Unpair in the iPhone app).")
        exit(0)
    } catch {
        print("Could not remove \(PairingStore.url.path): \(error.localizedDescription)")
        exit(1)
    }
}

let peripheral = Peripheral()
let relay = Relay(peripheral: peripheral)
var paired = PairingStore.load()
relay.use(paired)

// Pairing writes are only accepted while pairing; otherwise the iPhone is told what to do.
var pairing: PairingSession?
func startPairing() {
    pairing = PairingSession(peripheral: peripheral) { phone in
        paired = phone
        relay.use(phone)
        pairing = nil
    }
    log("""
        Pairing mode. On your iPhone, open bleping and tap "Pair with Mac".
          A 6-digit code will show here; type it on the iPhone.
        """)
}
peripheral.onPairingMessage = { data, central in
    if let pairing {
        pairing.handle(data, from: central)
    } else if case .hello? = PairMessage(data) {
        peripheral.sendPairing(.failed("This Mac isn't in pairing mode. Run `bleping pair` on it."), to: central)
    }
}
peripheral.onEventsSubscribed = { central in relay.replay(to: central) }

if let paired {
    log("Paired with \"\(paired.phoneName)\" since \(DateFormatter.localizedString(from: paired.pairedAt, dateStyle: .medium, timeStyle: .short))")
}
if options.command == .pair {
    startPairing()
} else if paired == nil {
    log("No iPhone paired yet.")
    startPairing()
}

if options.test {
    relay.send(MacNotification(id: "test-\(UUID().uuidString)", app: "bleping", bundleID: "dev.bleping.mac",
                               title: "Test notification", date: Date()))
}

do {
    let watcher = try NotificationWatcher()
    log("Watching notifications. Ctrl-C to quit.")
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + options.interval, repeating: options.interval)
    timer.setEventHandler {
        do {
            for n in try watcher.poll()
            where (options.only.isEmpty || options.only.contains(n.bundleID)) && !options.ignore.contains(n.bundleID) {
                relay.send(MacNotification(id: "n\(n.recordID)", app: appName(for: n.bundleID) ?? n.bundleID,
                                           bundleID: n.bundleID, title: n.title.map { String($0.prefix(120)) },
                                           date: Date()))
            }
        } catch {
            log("\(error)")
        }
    }
    timer.resume()
    withExtendedLifetime(timer) { dispatchMain() }
} catch {
    // Without Full Disk Access we can still pair and send --test notifications.
    FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
    log("Not watching notifications; pairing and --test still work. Ctrl-C to quit.")
    dispatchMain()
}
