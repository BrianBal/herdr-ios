import HerdrKit
import SwiftUI

/// Creates a herdr workspace: an optional name, a starting folder (picked from
/// folders the session's panes are already in, or typed), and optionally an
/// agent to start in it with a first prompt.
struct NewWorkspaceSheet: View {
    @Environment(HerdrStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Returns whether it worked; the sheet stays open on failure.
    let create: (_ label: String?, _ cwd: String?, _ agent: String?, _ prompt: String?) async -> Bool

    @State private var name = ""
    @State private var folder: String?
    @State private var customPath = ""
    @State private var useCustom = false
    @State private var creating = false
    @State private var error: String?
    /// Agent kind to start; nil = just a shell. Defaults to the first installed agent.
    @State private var agent: String?
    @State private var agentChosen = false
    @State private var prompt = ""
    @FocusState private var nameFocused: Bool

    /// Folders in use across the session, most used first.
    private var knownFolders: [String] {
        let dirs = store.snapshot?.panes.compactMap { $0.foregroundCwd ?? $0.cwd } ?? []
        let counts = Dictionary(dirs.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.keys.sorted { (counts[$0]!, $1) > (counts[$1]!, $0) }
    }

    /// The Mac's home folder, inferred from pane paths, so "~/x" can be expanded.
    private var home: String? {
        knownFolders.lazy.compactMap { path in
            path.range(of: #"^/Users/[^/]+"#, options: .regularExpression).map { String(path[$0]) }
        }.first
    }

    private var resolvedCwd: String? {
        guard useCustom else { return folder }
        let path = customPath.trimmingCharacters(in: .whitespaces)
        if path.isEmpty { return nil }
        if path == "~" { return home ?? path }
        if path.hasPrefix("~/"), let home { return home + path.dropFirst(1) }
        return path
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (optional)", text: $name)
                        .focused($nameFocused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                } footer: {
                    Text("Without a name, herdr labels it after the folder.")
                }
                Section("Start in") {
                    folderRow(nil, title: "herdr default")
                    ForEach(knownFolders, id: \.self) { dir in
                        folderRow(dir, title: abbreviated(dir))
                    }
                    Button { useCustom = true } label: {
                        HStack {
                            Text("Other folder…").foregroundStyle(.primary)
                            Spacer()
                            if useCustom { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                    if useCustom {
                        TextField("/path/on/your/Mac or ~/…", text: $customPath)
                            .font(.callout.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                }
                if !store.agentKinds.isEmpty {
                    Section {
                        Picker("Start", selection: $agent) {
                            Text("Just a shell").tag(String?.none)
                            ForEach(store.agentKinds, id: \.self) { kind in
                                Text(AgentKind.displayName(kind)).tag(Optional(kind))
                            }
                        }
                        .onChange(of: agent) { agentChosen = true }
                        if agent != nil {
                            TextField("First prompt (optional)", text: $prompt, axis: .vertical)
                                .lineLimit(2...5)
                        }
                    } header: {
                        Text("Agent")
                    } footer: {
                        if agent != nil {
                            Text("The prompt is sent once the agent is ready. If it asks something first (like whether to trust the folder), answer it in the workspace and the prompt follows.")
                        }
                    }
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("New Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if creating {
                        ProgressView()
                    } else {
                        Button("Create") { submit() }
                            .disabled(!store.isConnected || (useCustom && resolvedCwd == nil))
                    }
                }
            }
            .onAppear {
                nameFocused = true
                if !agentChosen { agent = store.agentKinds.first }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func folderRow(_ dir: String?, title: String) -> some View {
        Button {
            useCustom = false
            folder = dir
        } label: {
            HStack {
                Text(title)
                    .font(dir == nil ? .body : .callout.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                if !useCustom && folder == dir { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
    }

    private func abbreviated(_ path: String) -> String {
        if let home, path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

    private func submit() {
        let label = name.trimmingCharacters(in: .whitespaces)
        creating = true
        Task {
            let firstPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let ok = await create(label.isEmpty ? nil : label, resolvedCwd, agent, firstPrompt.isEmpty ? nil : firstPrompt)
            creating = false
            if ok {
                dismiss()
            } else {
                // Shown here: the app-level alert can't appear over this sheet.
                error = store.actionError ?? "Couldn't create the workspace."
                store.actionError = nil
            }
        }
    }
}
