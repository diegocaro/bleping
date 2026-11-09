import BlePingCore
import SwiftUI

@main
struct BlePingMacApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(model: model, engine: model.engine)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Window("bleping Settings", id: "settings") {
            SettingsView(model: model, engine: model.engine)
        }
        .windowResizability(.contentSize)

        Window("bleping Log", id: "log") {
            LogView(model: model)
        }
        .defaultSize(width: 640, height: 420)
    }
}

/// Opens one of the app's windows and brings it to the front (the app has no Dock icon).
struct WindowOpener {
    let openWindow: OpenWindowAction

    func callAsFunction(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - The panel under the menu bar icon

struct MenuPanel: View {
    @ObservedObject var model: AppModel
    let engine: Engine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusHeader(model: model, engine: engine)
                .padding(14)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if let pairing = engine.pairing {
                    PairingBox(pairing: pairing, engine: engine)
                } else {
                    problems
                    RecentList(items: engine.forwarded)
                }
            }
            .padding(14)
            Divider()
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(width: 340)
    }

    @ViewBuilder private var problems: some View {
        if engine.bluetooth == .unauthorized {
            Notice(text: "Allow bleping under Privacy & Security › Bluetooth.",
                   button: "Open Settings") { model.openPrivacySettings("Privacy_Bluetooth") }
        }
        if engine.watchError != nil {
            Notice(text: "bleping needs Full Disk Access to see your notifications. Turn it on, then click Retry.",
                   button: "Open Settings", secondary: "Retry",
                   action: { model.openPrivacySettings("Privacy_AllFiles") },
                   secondaryAction: { engine.startWatching() })
        }
    }

    private var footer: some View {
        let open = WindowOpener(openWindow: openWindow)
        return HStack(spacing: 8) {
            if engine.phone == nil && engine.pairing == nil {
                Button("Pair iPhone…") { engine.startPairing() }
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
            FooterIcon(symbol: "gearshape", help: "Settings") { open("settings") }
            FooterIcon(symbol: "power", help: "Quit bleping") { NSApp.terminate(nil) }
        }
        .controlSize(.small)
    }
}

struct FooterIcon: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

struct StatusHeader: View {
    @ObservedObject var model: AppModel
    let engine: Engine

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(color.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var color: Color {
        switch model.health {
        case .good: return .green
        case .waiting: return .orange
        case .problem: return .red
        }
    }

    private var symbol: String {
        if model.bluetoothProblem != nil { return "exclamationmark" }
        if engine.pairing != nil { return "link" }
        if engine.phone == nil { return "iphone.slash" }
        return engine.phoneConnected ? "iphone.radiowaves.left.and.right" : "iphone"
    }

    private var title: String {
        if let problem = model.bluetoothProblem { return problem }
        if engine.bluetooth == .starting { return "Starting Bluetooth…" }
        if engine.pairing != nil { return "Pairing with your iPhone" }
        guard let phone = engine.phone else { return "No iPhone paired" }
        return engine.phoneConnected ? "Connected to \(phone.name)" : "Waiting for \(phone.name)"
    }

    private var detail: String? {
        if model.bluetoothProblem != nil || engine.pairing != nil { return nil }
        guard engine.phone != nil else { return "Pair your iPhone to start." }
        if engine.phoneConnected { return "Notifications go to your iPhone." }
        return model.catchUp
            ? "Open bleping on your iPhone. Missed notifications arrive when it reconnects."
            : "Open bleping on your iPhone."
    }
}

struct PairingBox: View {
    let pairing: Engine.Pairing
    let engine: Engine

    var body: some View {
        VStack(spacing: 10) {
            switch pairing {
            case .waiting:
                ProgressView().controlSize(.small)
                Text("On your iPhone, open bleping and tap **Pair with Mac**.")
                    .multilineTextAlignment(.center)
            case .exchanging:
                ProgressView().controlSize(.small)
                Text("iPhone found. Connecting securely…")
            case .code(let code):
                Text("Type this code on your iPhone")
                    .foregroundStyle(.secondary)
                Text(Engine.displayCode(code))
                    .font(.system(size: 40, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
            case .failed(let reason):
                Image(systemName: "xmark.circle").font(.title).foregroundStyle(.red)
                Text("Pairing failed").font(.headline)
                Text(reason).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try Again") { engine.startPairing() }
            }
            if engine.phone != nil || pairing != .waiting {
                Button("Cancel") { engine.cancelPairing() }.controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

struct RecentList: View {
    let items: [Engine.Forwarded]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if items.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "bell").font(.title2).foregroundStyle(.tertiary)
                        Text("New Mac notifications show up here.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 12)
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(items.prefix(6)) { ForwardedRow(item: $0, now: context.date) }
                    }
                }
            }
        }
    }
}

struct ForwardedRow: View {
    let item: Engine.Forwarded
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AppIcon(bundleID: item.bundleID)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.app).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(now.timeIntervalSince(item.date) < 60 ? "now" : item.date.formatted(.relative(presentation: .numeric)))
                        .font(.caption2).foregroundStyle(.tertiary)
                    Image(systemName: symbol)
                        .font(.caption2)
                        .foregroundStyle(color)
                        .help(help)
                }
                Text(item.title ?? item.subtitle ?? "Notification")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if item.title != nil, let subtitle = item.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private var symbol: String {
        switch item.delivery {
        case .sent: return "checkmark.circle.fill"
        case .queued: return "clock.fill"
        case .skipped: return "xmark.circle"
        case .notPaired: return "minus.circle"
        }
    }

    private var color: Color {
        switch item.delivery {
        case .sent: return .green
        case .queued: return .orange
        case .skipped, .notPaired: return .secondary
        }
    }

    private var help: String {
        switch item.delivery {
        case .sent: return "Sent to your iPhone"
        case .queued: return "Waiting for your iPhone to reconnect"
        case .skipped: return "Not sent: your iPhone wasn't connected (catching up is off)"
        case .notPaired: return "Not sent: no iPhone paired"
        }
    }
}

/// The icon of the app that posted the notification (bleping's own for test notifications).
struct AppIcon: View {
    let bundleID: String

    var body: some View {
        Image(nsImage: Self.icon(for: bundleID))
            .resizable()
            .interpolation(.high)
    }

    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String) -> NSImage {
        if let cached = cache[bundleID] { return cached }
        let image: NSImage
        if bundleID.hasPrefix("dev.bleping.") {
            image = NSApp.applicationIconImage
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        cache[bundleID] = image
        return image
    }
}

struct Notice: View {
    let text: String
    let button: String
    var secondary: String? = nil
    let action: () -> Void
    var secondaryAction: (() -> Void)? = nil

    init(text: String, button: String, secondary: String? = nil,
         action: @escaping () -> Void, secondaryAction: (() -> Void)? = nil) {
        self.text = text
        self.button = button
        self.secondary = secondary
        self.action = action
        self.secondaryAction = secondaryAction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .symbolRenderingMode(.multicolor)
            HStack {
                Button(button, action: action)
                if let secondary, let secondaryAction { Button(secondary, action: secondaryAction) }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @ObservedObject var model: AppModel
    let engine: Engine
    @Environment(\.openWindow) private var openWindow
    @State private var confirmUnpair = false
    /// The last test notification sent from here, to show what happened to it.
    @State private var testID: String?
    /// True for a moment after clicking Send Test, so the old result visibly clears.
    @State private var testing = false

    var body: some View {
        Form {
            Section("iPhone") {
                if let pairing = engine.pairing {
                    // The menu bar panel closes while this window is in front, so show pairing here too.
                    PairingBox(pairing: pairing, engine: engine)
                } else if let phone = engine.phone {
                    LabeledContent("Paired with", value: phone.name)
                    LabeledContent("Since", value: phone.pairedAt.formatted(date: .abbreviated, time: .shortened))
                    HStack {
                        Button("Pair a Different iPhone…") { engine.startPairing() }
                        Spacer()
                        Button("Unpair…", role: .destructive) { confirmUnpair = true }
                    }
                } else {
                    LabeledContent("Paired with", value: "Nobody yet")
                    Button("Pair iPhone…") { engine.startPairing() }
                }
            }
            Section("Notifications") {
                Toggle(isOn: $model.catchUp) {
                    Text("Send missed notifications")
                    Text("When your iPhone reconnects, send it the notifications from the last hour it missed. When off, notifications that arrive while it's away are skipped.")
                }
            }
            Section("General") {
                Toggle("Open at Login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
            }
            Section("Troubleshooting") {
                LabeledContent {
                    Button("Send Test") { sendTest() }
                        .disabled(engine.phone == nil || testing)
                } label: {
                    HStack(spacing: 5) {
                        Text("Test notification")
                        if testing {
                            ProgressView().controlSize(.mini)
                        } else if let result = testResult {
                            Image(systemName: result.symbol)
                                .foregroundStyle(result.color)
                                .help(result.text)
                        }
                    }
                    // Explain only when it didn't go straight through.
                    if let result = testResult, result.symbol != "checkmark.circle.fill" {
                        Text(result.text)
                    } else {
                        Text("Sends a notification to your iPhone to check the connection.")
                    }
                }
                LabeledContent {
                    Button("Open Log") { WindowOpener(openWindow: openWindow)("log") }
                } label: {
                    Text("Log")
                    Text("What bleping is doing, for troubleshooting.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize()
        .confirmationDialog("Unpair \(engine.phone?.name ?? "iPhone")?", isPresented: $confirmUnpair) {
            Button("Unpair", role: .destructive) { engine.unpair() }
        } message: {
            Text("Notifications stop until you pair again. Also tap Unpair in the iPhone app.")
        }
    }
}

extension SettingsView {
    /// Clears the previous result, then sends after a short pause so each click shows a fresh result.
    private func sendTest() {
        testID = nil
        testing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            testID = engine.sendTest()
            testing = false
        }
    }

    /// What happened to the last test notification (it updates if it's delivered later).
    private var testResult: (text: String, symbol: String, color: Color)? {
        guard let testID, let item = engine.forwarded.first(where: { $0.id == testID }) else { return nil }
        let phone = engine.phone?.name ?? "your iPhone"
        switch item.delivery {
        case .sent: return ("Sent to \(phone)", "checkmark.circle.fill", .green)
        case .queued: return ("\(phone) isn't connected. It gets the test when it reconnects.", "clock.fill", .orange)
        case .skipped: return ("Not sent: \(phone) isn't connected.", "xmark.circle.fill", .secondary)
        case .notPaired: return ("Not sent: no iPhone paired.", "minus.circle.fill", .secondary)
        }
    }
}

// MARK: - Log window

struct LogView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(model.logLines.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                Color.clear.frame(height: 1).id("end")
            }
            .onChange(of: model.logLines.count) { _ in proxy.scrollTo("end") }
            .onAppear { proxy.scrollTo("end") }
        }
    }
}
