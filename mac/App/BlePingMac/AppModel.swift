import AppKit
import BlePingCore
import OSLog
import ServiceManagement
import SwiftUI

/// Owns the engine and republishes its state to SwiftUI.
@MainActor
final class AppModel: ObservableObject {
    let engine = Engine()
    @Published private(set) var logLines: [String] = []
    @Published private(set) var openAtLogin = SMAppService.mainApp.status == .enabled

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init() {
        engine.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
        engine.onLog = { [weak self] line in
            MainActor.assumeIsolated { self?.appendLog(line) }
        }
        engine.start()
        // First launch: nothing paired yet, so be ready to pair straight away.
        if engine.phone == nil { engine.startPairing() }
    }

    private static let logger = Logger(subsystem: "dev.bleping.macapp", category: "engine")

    private func appendLog(_ line: String) {
        // Also to the system log:  log stream --predicate 'subsystem == "dev.bleping.macapp"'
        Self.logger.notice("\(line, privacy: .public)")
        logLines.append("\(Self.clock.string(from: Date()))  \(line)")
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
    }

    // MARK: What the menu bar shows

    enum Health { case good, waiting, problem }

    var health: Health {
        if engine.bluetooth != .on && engine.bluetooth != .starting { return .problem }
        if engine.pairing != nil { return .waiting }
        if engine.phone == nil || engine.watchError != nil { return .problem }
        return engine.phoneConnected ? .good : .waiting
    }

    var menuBarSymbol: String {
        switch health {
        case .good: return "bell.badge.fill"
        case .waiting: return "bell"
        case .problem: return "bell.slash"
        }
    }

    var bluetoothProblem: String? {
        switch engine.bluetooth {
        case .on, .starting: return nil
        case .off: return "Bluetooth is off"
        case .unauthorized: return "bleping isn't allowed to use Bluetooth"
        case .unsupported: return "This Mac doesn't support Bluetooth LE"
        case .unavailable: return "Bluetooth isn't available"
        }
    }

    // MARK: Actions

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            appendLog("Could not change Open at Login: \(error.localizedDescription)")
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    func openPrivacySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
