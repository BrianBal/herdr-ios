import HerdrKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @AppStorage("terminal.fontSize") private var fontSize = 11.0
    @AppStorage("terminal.wrap") private var wrap = true
    @AppStorage("terminal.fit") private var fitScreen = true
    @State private var addingGateway = false
    @State private var removing: SavedGateway?
    @State private var testResult: String?
    @State private var testing = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Form {
                gatewaysSection
                notificationsSection
                liveActivitySection
                Section {
                    NavigationLink("Quick prompts") { QuickPromptsEditor() }
                } footer: {
                    Text("One-tap chips above the message field. Long-press a chip to edit or remove it.")
                }
                Section {
                    Stepper(value: $fontSize, in: 7...20, step: 1) {
                        LabeledContent("Font size", value: "\(Int(fontSize)) pt")
                    }
                    Toggle("Wrap long lines", isOn: $wrap)
                    Toggle("Fit panes to this screen", isOn: $fitScreen)
                        .disabled(!wrap)
                } header: {
                    Text("Terminal")
                } footer: {
                    Text("Shrinks the pane you're viewing to this screen, like a smaller tmux client, so full-screen programs such as opencode redraw to fit. The Mac shows it smaller until you leave the pane.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $addingGateway) { PairView(onPaired: { addingGateway = false }) }
            .confirmationDialog(removing.map { "Remove “\($0.name)”?" } ?? "",
                                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible, presenting: removing) { g in
                Button("Remove", role: .destructive) {
                    if app.gateways.count == 1 { dismiss() }
                    app.remove(g.id)
                }
            } message: { _ in
                Text("Its token is deleted from this iPhone and it stops sending notifications here. Scan its pairing code to add it again.")
            }
        }
    }

    /// Notifications, the Live Activity and the widget go through the primary machine.
    private var store: HerdrStore? { app.primaryStore }

    private var gatewaysSection: some View {
        Section {
            ForEach(app.gateways) { g in
                NavigationLink {
                    GatewayEditView(gateway: g, onRemove: { removing = g })
                } label: {
                    GatewayRow(gateway: g, store: app.store(g.id), primary: g.id == app.primaryId && app.gateways.count > 1)
                }
                .swipeActions {
                    Button("Remove", role: .destructive) { removing = g }
                }
            }
            Button { addingGateway = true } label: {
                Label("Add gateway", systemImage: "plus")
            }
        } header: {
            Text("Machines")
        } footer: {
            Text("One herdr per machine, each with its own gateway and pairing code. The app stays connected to all of them, and they all send notifications. The Live Activity and widget show one machine's agents, marked with a star.")
        }
    }

    @ViewBuilder
    private var notificationsSection: some View {
        let push = app.push
        Section {
            switch push.authorization {
            case .authorized, .provisional, .ephemeral:
                LabeledContent("Notifications", value: push.deviceToken == nil ? "Registering…" : "On")
                if let problem = store?.pushProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Button {
                    testing = true
                    Task {
                        testResult = await store?.sendTestPush() ?? "Sent — it should arrive in a moment."
                        testing = false
                    }
                } label: {
                    HStack {
                        Text("Send test notification")
                        if testing { Spacer(); ProgressView() }
                    }
                }
                .disabled(testing || store?.isConnected != true || push.deviceToken == nil)
                if let testResult {
                    Text(testResult).font(.footnote).foregroundStyle(.secondary)
                }
            case .denied:
                LabeledContent("Notifications", value: "Off")
                Button("Turn on in Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
            default:
                Button("Turn on notifications") { Task { await push.requestAuthorization() } }
            }
            if let error = push.registrationError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Your Mac sends one when an agent needs input or finishes, unless this app is open. Buttons on the notification answer without opening the app.")
        }
    }

    @ViewBuilder
    private var liveActivitySection: some View {
        let live = app.liveActivity
        Section {
            Toggle("Show while agents are busy", isOn: Binding(get: { live.enabled }, set: { live.enabled = $0 }))
            if !live.systemEnabled {
                Label("Live Activities are turned off for Herdr in iOS Settings.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            } else if live.enabled {
                LabeledContent("Status", value: live.isRunning ? "On the Lock Screen" : "Waiting for busy agents")
                if live.isRunning {
                    Button("End now", role: .destructive) { Task { await live.endNow() } }
                } else {
                    Button("Start now") {
                        if let s = store?.snapshot { Task { await live.startNow(AgentBoard(snapshot: s)) } }
                    }
                    .disabled(store?.snapshot == nil)
                }
            }
        } header: {
            Text("Live Activity")
        } footer: {
            Text("A summary on the Lock Screen and in the Dynamic Island: how many agents are working and which need you. It starts when agents get busy, even with the app closed, and ends a couple of minutes after they're all done.")
        }
    }

}

extension HerdrStore.Phase {
    var label: String {
        switch self {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .waiting: "Offline"
        case .unauthorized: "Rejected"
        case .idle: "Paused"
        }
    }
}

struct GatewayRow: View {
    let gateway: SavedGateway
    let store: HerdrStore?
    /// Drives the Live Activity and widget (only marked with more than one machine).
    let primary: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(gateway.name)
                    if primary {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                            .accessibilityLabel("Live Activity and widget")
                    }
                }
                Text(gateway.url.host ?? gateway.url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let store {
                Text(store.phase.label)
                    .font(.caption)
                    .foregroundStyle(store.isConnected ? Color.green : store.isOffline ? Color.red : Color.secondary)
            }
        }
    }
}

/// Rename a machine's gateway, point it at a new URL or token, make it the
/// one the Live Activity and widget show, or remove it.
struct GatewayEditView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let gateway: SavedGateway
    var onRemove: () -> Void
    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    @State private var saving = false
    @State private var error: String?

    private var dirty: Bool {
        name != gateway.name || url != gateway.url.absoluteString || !token.isEmpty
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField(SavedGateway.defaultName(for: gateway.url), text: $name)
            }
            Section {
                TextField("wss://host.tailnet.ts.net/ws", text: $url)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("New token (leave blank to keep)", text: $token)
                    // Plain text, not SecureField: iOS offers to save a secure field in Passwords.
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Connection")
            } footer: {
                Text("A new URL or token is checked by connecting before it's saved.")
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
            if let store = app.store(gateway.id) {
                Section("Status") {
                    LabeledContent("Status", value: store.phase.label)
                    LabeledContent("Signed in as", value: store.info?.user ?? "local")
                    if let info = store.info {
                        LabeledContent("Gateway", value: info.gatewayVersion)
                        if let herdr = info.herdr {
                            LabeledContent("herdr", value: "\(herdr.version) (protocol \(herdr.protocol))")
                        }
                    }
                }
            }
            if app.gateways.count > 1 {
                Section {
                    if gateway.id == app.primaryId {
                        Label("Shown in the Live Activity and widget", systemImage: "star.fill")
                    } else {
                        Button("Show in the Live Activity and widget") { app.makePrimary(gateway.id) }
                    }
                } footer: {
                    Text("They show one machine's agents at a time.")
                }
            }
            Section {
                Button("Remove gateway", role: .destructive, action: onRemove)
            }
        }
        .navigationTitle(gateway.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving {
                    ProgressView()
                } else {
                    Button("Save") { save() }.disabled(!dirty || url.isEmpty)
                }
            }
        }
        .onAppear {
            name = gateway.name
            url = gateway.url.absoluteString
        }
        .onChange(of: app.gateway(gateway.id) == nil) { _, gone in if gone { dismiss() } }
    }

    private func save() {
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await app.update(gateway.id, name: name, url: url, token: token)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
