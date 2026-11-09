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

        Window("bleping log", id: "log") {
            LogView(model: model)
        }
        .defaultSize(width: 640, height: 420)
    }
}

// MARK: - The panel under the menu bar icon

struct MenuPanel: View {
    @ObservedObject var model: AppModel
    let engine: Engine
    @Environment(\.openWindow) private var openWindow
    @State private var confirmUnpair = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if let pairing = engine.pairing {
                PairingBox(pairing: pairing, engine: engine)
            } else {
                problems
                RecentList(items: engine.forwarded)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.title2)
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle).font(.headline)
                if let detail = statusDetail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var statusColor: Color {
        switch model.health {
        case .good: return .green
        case .waiting: return .orange
        case .problem: return .red
        }
    }

    private var statusTitle: String {
        if let problem = model.bluetoothProblem { return problem }
        if engine.bluetooth == .starting { return "Starting Bluetooth…" }
        if engine.pairing != nil { return "Pairing" }
        guard let phone = engine.phone else { return "No iPhone paired" }
        return engine.phoneConnected ? "Connected to \(phone.name)" : "Waiting for \(phone.name)"
    }

    private var statusDetail: String? {
        if model.bluetoothProblem != nil || engine.pairing != nil { return nil }
        guard engine.phone != nil else { return "Pair your iPhone to start." }
        return engine.phoneConnected
            ? "Notifications go to your iPhone"
            : "Open bleping on your iPhone. Missed notifications arrive when it reconnects."
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if engine.phone == nil {
                    if engine.pairing == nil { Button("Pair iPhone…") { engine.startPairing() } }
                } else {
                    Button("Send Test") { engine.sendTest() }
                    Menu("iPhone") {
                        Button("Pair a Different iPhone…") { engine.startPairing() }
                        Button("Unpair \(engine.phone?.name ?? "iPhone")…") { confirmUnpair = true }
                    }
                    .fixedSize()
                }
                Spacer()
                Button {
                    openWindow(id: "log")
                    NSApp.activate(ignoringOtherApps: true)
                } label: { Image(systemName: "doc.text.magnifyingglass") }
                    .help("Show log")
            }
            HStack {
                Toggle("Open at Login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .controlSize(.small)
        .confirmationDialog("Unpair \(engine.phone?.name ?? "iPhone")?", isPresented: $confirmUnpair) {
            Button("Unpair", role: .destructive) { engine.unpair() }
        } message: {
            Text("Notifications stop until you pair again. Also tap Unpair in the iPhone app.")
        }
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
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent").font(.caption).foregroundStyle(.secondary)
            if items.isEmpty {
                Text("Nothing yet. New Mac notifications show up here.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(items.prefix(8)) { ForwardedRow(item: $0, now: context.date) }
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
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color).help(help)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.app).font(.callout.weight(.medium))
                if let title = item.title {
                    Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(now.timeIntervalSince(item.date) < 60 ? "now" : item.date.formatted(.relative(presentation: .numeric)))
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var symbol: String {
        switch item.delivery {
        case .sent: return "checkmark.circle.fill"
        case .queued: return "clock"
        case .notPaired: return "minus.circle"
        }
    }

    private var color: Color {
        switch item.delivery {
        case .sent: return .green
        case .queued: return .orange
        case .notPaired: return .secondary
        }
    }

    private var help: String {
        switch item.delivery {
        case .sent: return "Sent to your iPhone"
        case .queued: return "Waiting for your iPhone to reconnect"
        case .notPaired: return "Not sent: no iPhone paired"
        }
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
