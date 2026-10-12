import SwiftUI

/// Settings → Quick prompts: reorder, edit, remove, add, or reset each list.
struct QuickPromptsEditor: View {
    @Environment(AppModel.self) private var app
    @State private var newText: [QuickPrompts.Kind: String] = [:]
    @State private var editing: (kind: QuickPrompts.Kind, text: String)?
    @State private var editText = ""

    var body: some View {
        let prompts = app.quickPrompts
        List {
            ForEach(QuickPrompts.Kind.allCases) { kind in
                Section {
                    ForEach(prompts.list(kind), id: \.self) { prompt in
                        Button {
                            editText = prompt
                            editing = (kind, prompt)
                        } label: {
                            Text(prompt).foregroundStyle(.primary)
                        }
                    }
                    .onDelete { prompts.remove(atOffsets: $0, from: kind) }
                    .onMove { prompts.move(fromOffsets: $0, toOffset: $1, in: kind) }
                    HStack {
                        TextField(kind == .agent ? "New prompt" : "New command",
                                  text: Binding(get: { newText[kind] ?? "" }, set: { newText[kind] = $0 }))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { add(kind) }
                        Button("Add") { add(kind) }
                            .disabled((newText[kind] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text(kind.title)
                } footer: {
                    Button("Reset to defaults") { prompts.resetToDefaults(kind) }
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("Quick Prompts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .alert("Edit Quick Prompt", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Prompt", text: $editText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let editing { prompts.replace(editing.text, with: editText, in: editing.kind) }
            }
        }
    }

    private func add(_ kind: QuickPrompts.Kind) {
        app.quickPrompts.add(newText[kind] ?? "", to: kind)
        newText[kind] = ""
    }
}
