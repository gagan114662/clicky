import SwiftUI

struct AgentConfirmationPanelView: View {
    let humanReadableSummary: String
    let onApprove: () -> Void
    let onEdit: (String) -> Void
    let onDeny: () -> Void

    @State private var editedInstruction = ""
    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.accent)
                Text("Approval Needed")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Text(humanReadableSummary)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(isEditing ? 3 : 4)

            if isEditing {
                TextEditor(text: $editedInstruction)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textPrimary)
                    .frame(minHeight: 58, maxHeight: 84)
                    .padding(6)
                    .scrollContentBackground(.hidden)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                    )
            }

            HStack(spacing: 8) {
                Button(action: onDeny) {
                    Label("Cancel", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .pointerCursor()

                Button(action: editButtonTapped) {
                    Label(isEditing ? "Use Edit" : "Edit", systemImage: isEditing ? "checkmark" : "pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isEditing && editedInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .pointerCursor()

                Button(action: onApprove) {
                    Label("Approve", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .pointerCursor()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
        .onAppear {
            editedInstruction = humanReadableSummary
        }
    }

    private func editButtonTapped() {
        if isEditing {
            onEdit(editedInstruction)
        } else {
            editedInstruction = humanReadableSummary
            isEditing = true
        }
    }
}
