import HerdrKit
import SwiftUI

/// herdr's agents side panel as a bottom sheet: every agent grouped by status.
struct AgentsSheet: View {
    @Environment(HerdrStore.self) private var store
    let onSelect: (Agent) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if let s = store.snapshot, !s.agents.isEmpty {
                    let groups = Dictionary(grouping: s.agents, by: \.agentStatus)
                    List {
                        ForEach(AgentStatus.allCases.sorted { $0.priority < $1.priority }, id: \.self) { status in
                            if let agents = groups[status] {
                                Section(status.label) {
                                    ForEach(agents.sorted { $0.workspaceId < $1.workspaceId }) { agent in
                                        Button { onSelect(agent) } label: {
                                            AgentRow(agent: agent, workspaceLabel: s.workspace(agent.workspaceId)?.label)
                                        }
                                        .tint(.primary)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("No agents running", systemImage: "person.2.slash",
                                           description: Text("Agents herdr detects in any pane show up here."))
                }
            }
            .navigationTitle("Agents")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
