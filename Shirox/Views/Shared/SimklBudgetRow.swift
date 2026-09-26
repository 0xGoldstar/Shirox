import SwiftUI

/// Today's Simkl requests, in the Simkl section of Settings.
struct SimklBudgetRow: View {
    @ObservedObject private var budget = SimklBudget.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(SimklBudget.summary(used: budget.used, resetsAt: budget.resetsAt))
                .font(.subheadline)
            if let note = SimklBudget.note(used: budget.used, spent: budget.spent) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Counts this device's requests only.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .onAppear { budget.refresh() }
    }
}
