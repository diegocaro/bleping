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
        // Permissions are asked in context: Bluetooth when the user taps Pair, notifications
        // right after pairing. Not here.
        UNUserNotificationCenter.current().delegate = self
        // Once paired, start Bluetooth at every launch, including iOS relaunching us in the
        // background for a Bluetooth event (state restoration needs the manager recreated).
        if MacLink.shared.paired != nil || launchOptions?[.bluetoothCentrals] != nil {
            MacLink.shared.start()
        }
        return true
    }

    // Show the banner even while the app is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

// MARK: - Notification permission

/// Whether bleping may show notifications. Re-checked whenever the app comes to the front,
/// since the user can change it in Settings at any time.
@MainActor
final class NotificationAccess: ObservableObject {
    static let shared = NotificationAccess()
    @Published private(set) var status: UNAuthorizationStatus = .notDetermined

    func refresh() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Shows iOS's prompt if the user hasn't been asked yet. Called once a Mac is paired, when
    /// it's clear why bleping wants to notify.
    func requestIfNeeded() async {
        await refresh()
        guard status == .notDetermined else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        await refresh()
    }
}

/// Opens bleping's page in the Settings app (or its notification settings).
func openSettingsApp(notifications: Bool = false) {
    let string = notifications ? UIApplication.openNotificationSettingsURLString : UIApplication.openSettingsURLString
    if let url = URL(string: string) { UIApplication.shared.open(url) }
}

// MARK: - Main screen

struct ContentView: View {
    @ObservedObject var link: MacLink
    @ObservedObject private var notifications = NotificationAccess.shared
    @AppStorage("showBluetoothLog") private var showLog = false
    @State private var showSettings = false
    @State private var confirmClear = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                Section {
                    StatusCard(link: link)
                    if link.paired != nil, notifications.status == .denied {
                        NotificationsOffRow()
                    }
                }

                if link.paired != nil {
                    Section {
                        if link.history.isEmpty {
                            ContentUnavailableView("No Notifications Yet", systemImage: "bell",
                                                   description: Text("New notifications from your Mac show up here."))
                        } else {
                            // Re-render every 30 s so "2 min ago" stays current.
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                ForEach(link.history) { notification in
                                    NotificationRow(notification: notification, now: context.date)
                                        .swipeActions {
                                            Button(role: .destructive) {
                                                withAnimation { link.removeFromHistory(notification.id) }
                                            } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                        }
                                }
                            }
                        }
                    } header: {
                        Text("Notifications")
                    }
                }

                if showLog {
                    Section("Bluetooth log") { DebugLogView(lines: link.debugLog) }
                }
            }
            .navigationTitle("bleping")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if link.paired != nil {
                        Menu {
                            Button("Clear All…", systemImage: "trash", role: .destructive) { confirmClear = true }
                                .disabled(link.history.isEmpty)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("More")
                    }
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .confirmationDialog("Clear all notifications?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear All", role: .destructive) { withAnimation { link.clearHistory() } }
            } message: {
                Text("This only removes them from this list. Notifications already on your Lock Screen stay there.")
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(link: link)
            }
            .task {
                // Paired before this version asked in context: ask now if it never happened.
                if link.paired != nil { await notifications.requestIfNeeded() } else { await notifications.refresh() }
            }
            .onChange(of: link.paired != nil) { _, paired in
                if paired { Task { await notifications.requestIfNeeded() } }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await notifications.refresh() } }
            }
            .sheet(isPresented: Binding(get: { link.pairingStep != nil },
                                        set: { if !$0 { link.cancelPairing() } })) {
                PairingView(link: link)
            }
        }
    }
}

struct StatusCard: View {
    @ObservedObject var link: MacLink

    var body: some View {
        if let problem = link.bluetoothProblem {
            LinkStateLabel(problem, state: link.bluetoothStarting ? .searching : .problem)
            if link.bluetoothDenied {
                Button("Open Settings") { openSettingsApp() }
            }
        } else if let mac = link.paired {
            if link.connected {
                LinkStateLabel("Connected to \(mac.macName)", state: .connected)
            } else {
                LinkStateLabel("Looking for \(mac.macName)…", state: .searching)
            }
        } else {
            LinkStateLabel("Not paired", state: .notPaired)
            Button("Pair with Mac") { link.startPairing() }
                .font(.headline)
        }
    }
}

struct NotificationsOffRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Notifications are off for bleping", systemImage: "bell.slash.fill")
                .foregroundStyle(.orange)
                .font(.subheadline.weight(.semibold))
            Text("Your Mac's notifications still arrive here, but they can't appear on your Lock Screen or as banners.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Turn On in Settings") { openSettingsApp(notifications: true) }
                .font(.subheadline)
        }
        .padding(.vertical, 2)
    }
}

struct NotificationRow: View {
    let notification: ReceivedNotification
    let now: Date

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AppBadge(name: notification.app, bundleID: notification.bundleID)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(notification.app)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(now.timeIntervalSince(notification.date) < 60 ? "now"
                         : Self.relative.localizedString(for: notification.date, relativeTo: now))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text(notification.title ?? notification.subtitle ?? "New notification")
                    .font(.body.weight(.medium))
                    .foregroundStyle(notification.title == nil && notification.subtitle == nil ? .secondary : .primary)
                if notification.title != nil, let subtitle = notification.subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// A rounded square with the app's first letter, in a color that stays the same for each app.
struct AppBadge: View {
    let name: String
    let bundleID: String

    private static let colors: [Color] = [.blue, .green, .orange, .pink, .purple, .red, .teal, .indigo, .mint, .brown]

    var body: some View {
        Text(String(name.first ?? "?").uppercased())
            .font(.system(size: 17, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var color: Color {
        // A stable hash (Swift's hashValue changes between launches).
        let sum = bundleID.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Self.colors[sum % Self.colors.count]
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var link: MacLink
    @AppStorage("showBluetoothLog") private var showLog = false
    @Environment(\.dismiss) private var dismiss
    @State private var confirmUnpair = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let mac = link.paired {
                        LabeledContent("Paired with", value: mac.macName)
                        LabeledContent("Since", value: mac.pairedAt.formatted(date: .abbreviated, time: .shortened))
                        Button("Pair with a Different Mac") { pairAfterDismiss() }
                        Button("Unpair", role: .destructive) { confirmUnpair = true }
                    } else {
                        Button("Pair with Mac") { pairAfterDismiss() }
                    }
                } header: {
                    Text("Mac")
                }

                Section {
                    Label("Keep bleping in the app switcher. If you swipe it away, iOS stops the connection until you open it again.",
                          systemImage: "rectangle.stack")
                    Label("After restarting your iPhone, open bleping once.", systemImage: "arrow.clockwise")
                } header: {
                    Text("Staying connected")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Section {
                    Toggle("Show Bluetooth log", isOn: $showLog)
                } header: {
                    Text("Troubleshooting")
                } footer: {
                    Text("Shows connection, pairing and notification events as they happen, on the main screen and while pairing.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Unpair from \(link.paired?.macName ?? "Mac")?", isPresented: $confirmUnpair,
                                titleVisibility: .visible) {
                Button("Unpair", role: .destructive) { link.unpair() }
            } message: {
                Text("Notifications stop until you pair again. Also unpair in bleping on the Mac.")
            }
        }
    }

    /// The pairing sheet belongs to the main screen, so close this one first.
    private func pairAfterDismiss() {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { link.startPairing() }
    }
}

// MARK: - Pairing

struct PairingView: View {
    @ObservedObject var link: MacLink

    private var isPaired: Bool {
        if case .paired? = link.pairingStep { return true }
        return false
    }
    @AppStorage("showBluetoothLog") private var showLog = false
    @State private var code = ""
    @FocusState private var codeFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                switch link.pairingStep {
                case .searching? where link.bluetoothProblem != nil && link.bluetoothProblem != "Starting Bluetooth…":
                    StepIcon(symbol: "exclamationmark", color: .red)
                    Text(link.bluetoothProblem ?? "").font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text("bleping uses Bluetooth to find your Mac and receive its notifications.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    if link.bluetoothDenied {
                        Button("Open Settings") { openSettingsApp() }
                            .buttonStyle(.borderedProminent)
                    }
                case .searching?:
                    StepIcon(symbol: "magnifyingglass")
                    if let hint = link.pairingHint {
                        Text("Waiting for your Mac…").font(.title3.weight(.semibold))
                        Text(hint)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Looking for your Mac…").font(.title3.weight(.semibold))
                        Text("On your Mac, open bleping and click **Pair iPhone…**. Keep your iPhone close to it.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    ProgressView()
                case .exchanging?:
                    StepIcon(symbol: "lock")
                    Text("Connecting securely…").font(.title3.weight(.semibold))
                    ProgressView()
                case .enterCode?:
                    StepIcon(symbol: "number")
                    Text("Enter the code shown on your Mac").font(.title3.weight(.semibold))
                    TextField("000000", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.system(size: 40, weight: .semibold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .focused($codeFocused)
                        .onAppear { codeFocused = true }
                        .onChange(of: code) { _, newValue in
                            let digits = String(newValue.filter(\.isNumber).prefix(6))
                            if digits != newValue { code = digits }
                            if digits.count == 6 { link.submitCode(digits) }
                        }
                    if let error = link.codeError {
                        Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
                    }
                case .paired(let macName)?:
                    StepIcon(symbol: "checkmark", color: .green)
                    Text("Paired with \(macName)").font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text("Your Mac's notifications will now show up on this iPhone.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                case .confirming?:
                    StepIcon(symbol: "checkmark")
                    Text("Pairing…").font(.title3.weight(.semibold))
                    ProgressView()
                case .failed(let reason)?:
                    StepIcon(symbol: "xmark", color: .red)
                    Text("Pairing failed").font(.title3.weight(.semibold))
                    Text(reason).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Try Again") {
                        code = ""
                        link.startPairing()
                    }
                    .buttonStyle(.borderedProminent)
                case nil:
                    EmptyView()
                }
                Spacer()
                if showLog {
                    ScrollView { DebugLogView(lines: link.debugLog) }
                        .frame(maxHeight: 200)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Pair with Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isPaired {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { link.cancelPairing() }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { link.cancelPairing() }
                    }
                }
            }
            .sensoryFeedback(.success, trigger: isPaired) { _, paired in paired }
        }
        .interactiveDismissDisabled(!isPaired)
    }
}

struct StepIcon: View {
    let symbol: String
    var color: Color = .blue

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 72, height: 72)
            .background(color.gradient, in: Circle())
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
