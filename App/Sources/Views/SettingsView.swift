import HerdrKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(HerdrStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("terminal.fontSize") private var fontSize = 11.0
    @AppStorage("terminal.wrap") private var wrap = true
    @State private var confirmUnpair = false
    @State private var testResult: String?
    @State private var testing = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Form {
                Section("Gateway") {
                    LabeledContent("Host", value: app.endpoint?.displayHost ?? "—")
                    LabeledContent("Signed in as", value: store.info?.user ?? "local")
                    LabeledContent("Status", value: statusText)
                    if let info = store.info {
                        LabeledContent("Gateway", value: info.gatewayVersion)
                        if let herdr = info.herdr {
                            LabeledContent("herdr", value: "\(herdr.version) (protocol \(herdr.protocol))")
                        }
                    }
                }
                notificationsSection
                liveActivitySection
                Section {
                    NavigationLink("Quick prompts") { QuickPromptsEditor() }
                } footer: {
                    Text("One-tap chips above the message field. Long-press a chip to edit or remove it.")
                }
                Section("Terminal") {
                    Stepper(value: $fontSize, in: 7...20, step: 1) {
                        LabeledContent("Font size", value: "\(Int(fontSize)) pt")
                    }
                    Toggle("Wrap long lines", isOn: $wrap)
                }
                Section {
                    Button("Unpair this device", role: .destructive) { confirmUnpair = true }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Unpair from \(app.endpoint?.displayHost ?? "gateway")?",
                                isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) {
                    dismiss()
                    app.unpair()
                }
            } message: {
                Text("The token is removed from this iPhone. Scan the pairing code again to reconnect.")
            }
        }
    }

    @ViewBuilder
    private var notificationsSection: some View {
        let push = app.push
        Section {
            switch push.authorization {
            case .authorized, .provisional, .ephemeral:
                LabeledContent("Notifications", value: push.deviceToken == nil ? "Registering…" : "On")
                if let problem = store.pushProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Button {
                    testing = true
                    Task {
                        testResult = await store.sendTestPush() ?? "Sent — it should arrive in a moment."
                        testing = false
                    }
                } label: {
                    HStack {
                        Text("Send test notification")
                        if testing { Spacer(); ProgressView() }
                    }
                }
                .disabled(testing || !store.isConnected || push.deviceToken == nil)
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
                        if let s = store.snapshot { Task { await live.startNow(AgentBoard(snapshot: s)) } }
                    }
                    .disabled(store.snapshot == nil)
                }
            }
        } header: {
            Text("Live Activity")
        } footer: {
            Text("A summary on the Lock Screen and in the Dynamic Island: how many agents are working and which need you. It starts when agents get busy, even with the app closed, and ends a couple of minutes after they're all done.")
        }
    }

    private var statusText: String {
        switch store.phase {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .waiting: "Reconnecting"
        case .unauthorized: "Rejected"
        case .idle: "Paused"
        }
    }
}
