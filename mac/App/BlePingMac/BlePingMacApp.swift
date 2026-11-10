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

        // The standard Settings window: toolbar tabs, titled after the selected tab.
        Settings {
            SettingsView(model: model, engine: model.engine)
        }

        Window("Bluetooth Log", id: "log") {
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
    @Environment(\.openSettings) private var openSettings

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
                // 6 + the row's own 8 lines the text up with the 14 pt margins above.
                .padding(6)
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

    /// Menu-style rows, like the bottom of Apple's own menu bar panels (Wi-Fi, Bluetooth, Sound).
    private var footer: some View {
        VStack(spacing: 0) {
            if engine.phone == nil && engine.pairing == nil {
                MenuRow(title: "Pair iPhone…") { engine.startPairing() }
            }
            MenuRow(title: "Settings…", shortcut: "⌘,") {
                // No Dock icon, so bring the app forward or the window opens behind others.
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
                .keyboardShortcut(",", modifiers: .command)
            MenuRow(title: "Quit bleping", shortcut: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
    }
}

/// A full-width row that highlights on hover, like a menu item.
struct MenuRow: View {
    let title: String
    var shortcut: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut).foregroundStyle(hovering ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                }
            }
            .foregroundStyle(hovering ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(hovering ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct StatusHeader: View {
    @ObservedObject var model: AppModel
    let engine: Engine

    var body: some View {
        // The same slim status line as the iPhone app.
        VStack(alignment: .leading, spacing: 3) {
            LinkStateLabel(title, state: state, tintsTitle: false)
                .font(.headline)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    // Line up with the title, past the symbol.
                    .padding(.leading, 26)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var state: LinkState {
        if model.bluetoothProblem != nil { return .problem }
        if engine.bluetooth == .starting { return .searching }
        if engine.pairing != nil { return .pairing }
        if engine.phone == nil { return .notPaired }
        return engine.phoneConnected ? .connected : .searching
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

    private enum Tab: String { case general, iPhone, troubleshooting }
    /// Reopens on the tab you last used.
    @AppStorage("settingsTab") private var tab = Tab.general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            PhoneSettings(model: model, engine: engine)
                .tabItem { Label("iPhone", systemImage: "iphone") }
                .tag(Tab.iPhone)
            // Named like the iPhone app's Troubleshooting section.
            TroubleshootingSettings(model: model, engine: engine)
                .tabItem { Label("Troubleshooting", systemImage: "wrench.and.screwdriver") }
                .tag(Tab.troubleshooting)
        }
        .frame(width: 460)
        .onAppear {
            // The panel's Pair buttons open pairing here; jump to it if pairing is under way.
            if engine.pairing != nil { tab = .iPhone }
        }
        .onChange(of: engine.pairing != nil) { pairing in
            if pairing { tab = .iPhone }
        }
    }
}

struct GeneralSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Open bleping at login",
                       isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
            }
            Section {
                Toggle(isOn: $model.catchUp) {
                    Text("Send missed notifications")
                    Text("When your iPhone reconnects, send it the notifications from the last hour it missed. When off, notifications that arrive while it's away are skipped.")
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct PhoneSettings: View {
    @ObservedObject var model: AppModel
    let engine: Engine
    @State private var confirmUnpair = false

    var body: some View {
        Form {
            if let pairing = engine.pairing {
                Section {
                    PairingBox(pairing: pairing, engine: engine)
                }
            } else if let phone = engine.phone {
                Section {
                    LabeledContent("Paired iPhone", value: phone.name)
                    LabeledContent("Paired since", value: phone.pairedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Status", value: engine.phoneConnected ? "Connected" : "Not connected")
                }
                Section {
                    HStack {
                        Button("Pair a Different iPhone…") { engine.startPairing() }
                        Spacer()
                        Button("Unpair…", role: .destructive) { confirmUnpair = true }
                    }
                }
            } else {
                Section {
                    LabeledContent("Paired iPhone", value: "None")
                } footer: {
                    Text("Pair your iPhone to send it your Mac's notifications. You'll need the bleping app on your iPhone.")
                }
                Section {
                    HStack {
                        Spacer()
                        Button("Pair iPhone…") { engine.startPairing() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Unpair \(engine.phone?.name ?? "iPhone")?", isPresented: $confirmUnpair) {
            Button("Unpair", role: .destructive) { engine.unpair() }
        } message: {
            Text("Notifications stop until you pair again. Also tap Unpair in the iPhone app.")
        }
    }
}

struct TroubleshootingSettings: View {
    @ObservedObject var model: AppModel
    let engine: Engine
    @Environment(\.openWindow) private var openWindow
    /// The last test notification sent from here, to show what happened to it.
    @State private var testID: String?
    /// True for a moment after clicking Send Test, so the old result visibly clears.
    @State private var testing = false

    var body: some View {
        Form {
            Section {
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
                    Text("Bluetooth log")
                    Text("Connection, pairing and notification events as they happen.")
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension TroubleshootingSettings {
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
