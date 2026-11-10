import BlePingCore
import Foundation

func printLog(_ message: String) {
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
    var engine = Engine.Options()
    var test = false

    static let usage = """
        usage: bleping [pair | unpair] [options]

          bleping            forward Mac notifications to the paired iPhone
          bleping pair       pair with the iPhone app (type the code it shows), then keep forwarding
          bleping unpair     forget the paired iPhone

          --interval SEC     how often to check for new notifications (default 1)
          --only IDS         comma-separated bundle IDs to forward (default: all)
          --ignore IDS       comma-separated bundle IDs to skip
          --no-catch-up      don't resend missed notifications when the iPhone reconnects
          --test             send a test notification at startup
          -h, --help         show this help

        Don't run this and the bleping menu bar app at the same time.
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
                o.engine.interval = v
            case "--only": o.engine.only = ids(value(arg))
            case "--ignore": o.engine.ignore = ids(value(arg))
            case "--no-catch-up": o.engine.catchUp = false
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

// MARK: - Main

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))

if options.command == .unpair {
    do {
        try Engine.forgetPairing()
        print("Forgot the paired iPhone. Run `bleping pair` to pair again (and tap Unpair in the iPhone app).")
        exit(0)
    } catch {
        print("Could not remove \(Engine.pairingFile.path): \(error.localizedDescription)")
        exit(1)
    }
}

let engine = Engine(options: options.engine)
engine.onLog = { line, _ in printLog(line) }   // your own terminal: show everything
engine.start()

if options.command == .pair {
    engine.startPairing()
} else if engine.phone == nil {
    printLog("No iPhone paired yet.")
    engine.startPairing()
}
// While pairing, each line typed in the terminal is a try at the code the iPhone shows.
var typed = Data()
FileHandle.standardInput.readabilityHandler = { handle in
    let chunk = handle.availableData
    DispatchQueue.main.async {
        if chunk.isEmpty {   // stdin closed (e.g. running in the background)
            FileHandle.standardInput.readabilityHandler = nil
            return
        }
        typed += chunk
        while let newline = typed.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: typed[..<newline], as: UTF8.self)
            typed = Data(typed[typed.index(after: newline)...])
            if case .enterCode? = engine.pairing { engine.submitCode(line) }
        }
    }
}
if options.test {
    engine.sendTest()
}
printLog("Ctrl-C to quit.")
dispatchMain()
