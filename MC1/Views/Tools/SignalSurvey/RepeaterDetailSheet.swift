import MC1Services
import SwiftUI

/// Detail sheet shown when tapping a repeater annotation on the survey map.
struct RepeaterDetailSheet: View {
    let contact: ContactDTO
    let onNavigateToContact: (ContactDTO) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Name", value: contact.displayName)
                    LabeledContent("Type", value: "Repeater")
                }

                Section("Public Key") {
                    Text(contact.publicKeyHex)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                if contact.hasLocation {
                    Section("Location") {
                        LabeledContent("Latitude", value: String(format: "%.6f", contact.latitude))
                        LabeledContent("Longitude", value: String(format: "%.6f", contact.longitude))
                    }
                }

                Section {
                    Button {
                        onNavigateToContact(contact)
                    } label: {
                        HStack {
                            Label("View Contact Card", systemImage: "person.crop.rectangle")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(contact.displayName)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
