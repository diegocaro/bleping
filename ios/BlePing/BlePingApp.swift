import SwiftUI
import UserNotifications

@main
struct BlePingApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(link: .shared)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        // Also runs on a Bluetooth-triggered background relaunch.
        MacLink.shared.start()
        return true
    }

    // Show the banner even while the app is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

struct ContentView: View {
    @ObservedObject var link: MacLink
    @State private var confirmUnpair = false

    var body: some View {
        NavigationStack {
            List {
                Section("Status") { status }

                Section {
                    if let mac = link.paired {
                        LabeledContent("Paired with", value: mac.macName)
                        Button("Pair with a different Mac") { link.startPairing() }
                        Button("Unpair", role: .destructive) { confirmUnpair = true }
                    } else {
                        Button("Pair with Mac") { link.startPairing() }
                            .font(.headline)
                        Text("On your Mac, run `bleping pair` first.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if link.paired != nil {
                    Section("Received") {
                        if link.history.isEmpty {
                            Text("Nothing yet. Notifications from your Mac show up here.")
                                .foregroundStyle(.secondary)
                        }
                        // Re-render every 30 s so "2 min ago" stays current.
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            ForEach(link.history) { NotificationRow(notification: $0, now: context.date) }
                        }
                    }
                    Section {
                        Text("Keep this app in the app switcher. If you swipe it away, iOS drops the connection until you open it again.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Bluetooth log") { DebugLogView(lines: link.debugLog) }
            }
            .navigationTitle("bleping")
            .confirmationDialog("Unpair from \(link.paired?.macName ?? "Mac")?", isPresented: $confirmUnpair,
                                titleVisibility: .visible) {
                Button("Unpair", role: .destructive) { link.unpair() }
            } message: {
                Text("Notifications stop until you pair again. Also run `bleping unpair` on the Mac.")
            }
            .sheet(isPresented: Binding(get: { link.pairingStep != nil },
                                        set: { if !$0 { link.cancelPairing() } })) {
                PairingView(link: link)
            }
        }
    }

    @ViewBuilder private var status: some View {
        if let problem = link.bluetoothProblem {
            Label(problem, systemImage: "exclamationmark.triangle")
        } else if link.paired == nil {
            Label("Not paired", systemImage: "link.badge.plus")
        } else if link.connected {
            Label("Connected to \(link.paired?.macName ?? "Mac")", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Label("Looking for \(link.paired?.macName ?? "your Mac")…", systemImage: "antenna.radiowaves.left.and.right")
        }
    }
}

struct PairingView: View {
    @ObservedObject var link: MacLink
    @State private var code = ""
    @FocusState private var codeFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                switch link.pairingStep {
                case .searching?:
                    ProgressView()
                    Text("Looking for your Mac…").font(.headline)
                    Text("On the Mac, run `bleping pair` and keep it close.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                case .exchanging?:
                    ProgressView()
                    Text("Connecting securely…").font(.headline)
                case .enterCode?:
                    Text("Enter the code shown on your Mac").font(.headline)
                    TextField("000000", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.system(size: 40, weight: .semibold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .focused($codeFocused)
                        .onAppear { codeFocused = true }
                        .onChange(of: code) { newValue in
                            let digits = String(newValue.filter(\.isNumber).prefix(6))
                            if digits != newValue { code = digits }
                            if digits.count == 6 { link.submitCode(digits) }
                        }
                    if let error = link.codeError {
                        Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
                    }
                case .confirming?:
                    ProgressView()
                    Text("Pairing…").font(.headline)
                case .failed(let reason)?:
                    Image(systemName: "xmark.circle").font(.largeTitle).foregroundStyle(.red)
                    Text("Pairing failed").font(.headline)
                    Text(reason).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Try again") {
                        code = ""
                        link.startPairing()
                    }
                    .buttonStyle(.borderedProminent)
                case nil:
                    EmptyView()
                }
                Spacer()
                ScrollView { DebugLogView(lines: link.debugLog) }
                    .frame(maxHeight: 220)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Pair with Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { link.cancelPairing() }
                }
            }
        }
        .interactiveDismissDisabled()
    }
}

struct NotificationRow: View {
    let notification: ReceivedNotification
    let now: Date

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(notification.app).font(.headline)
                Spacer()
                Text(now.timeIntervalSince(notification.date) < 10 ? "just now"
                     : Self.relative.localizedString(for: notification.date, relativeTo: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(notification.title ?? notification.subtitle ?? "New notification")
                .foregroundStyle(notification.title == nil && notification.subtitle == nil ? .secondary : .primary)
            if notification.title != nil, let subtitle = notification.subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct DebugLogView: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if lines.isEmpty { Text("(nothing yet)") }
            ForEach(Array(lines.enumerated().reversed()), id: \.offset) { Text($0.element) }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}
