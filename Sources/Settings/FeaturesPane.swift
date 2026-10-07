import SwiftUI

/// The Features tab: one switch per feature, System Settings style.
///
/// A `Form` is fine here, unlike on the Protected Apps tab: there is no
/// TextField to be promoted into a label and no unbounded List, so the grouped
/// style gives the native look without fighting layout.
struct FeaturesPane: View {
    @ObservedObject var quitProtection: QuitProtectionSettings
    @ObservedObject var dockQuit: DockQuitSettings
    @ObservedObject var stayAwake: StayAwake
    @ObservedObject var keyboardLockSettings: KeyboardLockSettings
    @ObservedObject var launchAtLogin: LaunchAtLogin
    @ObservedObject var wishlist: FeatureWishlist

    var body: some View {
        Form {
            Section("Features") {
                featureRow(
                    .quitProtection,
                    isOn: Binding(
                        get: { quitProtection.isEnabled },
                        set: { quitProtection.setEnabled($0) }
                    )
                )
                featureRow(
                    .dockQuit,
                    isOn: Binding(
                        get: { dockQuit.isEnabled },
                        set: { dockQuit.setEnabled($0) }
                    )
                )
                featureRow(
                    .stayAwake,
                    isOn: Binding(
                        get: { stayAwake.isEnabled },
                        set: { stayAwake.setEnabled($0) }
                    )
                )
                // Disabled while the password prompt is up. The switch would
                // otherwise accept a second click and stack a second prompt
                // behind the first, where it is invisible.
                .disabled(stayAwake.isBusy)

                featureRow(
                    .keyboardLock,
                    isOn: Binding(
                        get: { keyboardLockSettings.isEnabled },
                        set: { keyboardLockSettings.setEnabled($0) }
                    )
                )
            }

            Section("General") {
                // Reads and writes the same LaunchAtLogin instance the status
                // menu holds, so toggling either moves the other with no cached
                // copy in between.
                Toggle(
                    "Launch QuitGuard at login",
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    )
                )
                if launchAtLogin.requiresApproval {
                    Text("Waiting for approval in System Settings › General › Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Coming soon") {
                ForEach(FeatureIdea.allCases) { idea in
                    ideaRow(idea)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func featureRow(_ feature: Feature, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: feature.systemImage)
                    .frame(width: 22)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(feature.title)
                    Text(feature.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note = feature.requirementNote {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .toggleStyle(.switch)
    }

    /// Not a switch: nothing to turn on yet. The checkbox records interest so
    /// the next thing built is the thing wanted.
    private func ideaRow(_ idea: FeatureIdea) -> some View {
        Toggle(
            isOn: Binding(
                get: { wishlist.isWanted(idea) },
                set: { wishlist.setWanted($0, for: idea) }
            )
        ) {
            VStack(alignment: .leading, spacing: 2) {
                Text(idea.title)
                Text(idea.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
        .help("Tick if you would want this built")
    }
}
