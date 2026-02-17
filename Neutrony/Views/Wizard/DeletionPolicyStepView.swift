import SwiftUI

/// Deletion policy step: configure how deletions are handled.
struct DeletionPolicyStepView: View {
    @EnvironmentObject var wizardState: WizardState

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "shield.checkered")
                .font(.system(size: 40))
                .foregroundColor(.protonPurple)

            Text("Deletion & Version Policy")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Choose how the app handles files that are deleted or changed on Proton Drive. This affects your backup safety.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            // Policy selection
            VStack(spacing: 12) {
                ForEach(DeletionPolicy.allCases) { policy in
                    PolicyOptionView(
                        policy: policy,
                        isSelected: wizardState.deletionPolicy == policy,
                        isRecommended: policy == .mirrorDeletions
                    ) {
                        wizardState.deletionPolicy = policy
                    }
                }
            }
            .frame(maxWidth: 420)

            Spacer()

            Text("You can change these settings later from the app preferences.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct PolicyOptionView: View {
    let policy: DeletionPolicy
    let isSelected: Bool
    let isRecommended: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .protonPurple : .secondary)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(policy.displayName)
                            .font(.body)
                            .foregroundColor(.primary)

                        if isRecommended {
                            Text("Recommended")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.protonPurple.opacity(0.2))
                                .foregroundColor(.protonPurple)
                                .cornerRadius(4)
                        }
                    }

                    Text(policy.explanation)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.protonPurple.opacity(0.05) : Color.clear)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.protonPurple : Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
