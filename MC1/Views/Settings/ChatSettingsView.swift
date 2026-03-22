import SwiftUI

struct ChatSettingsView: View {
    @AppStorage("replyWithQuote") private var replyWithQuote = false
    @AppStorage("shareFormatDefault") private var shareFormatDefault = "webLink"

    var body: some View {
        List {
            Section {
                Toggle(isOn: $replyWithQuote) {
                    TintedLabel(L10n.Settings.ReplyWithQuote.toggle, systemImage: "text.quote")
                }
            } footer: {
                Text(L10n.Settings.ReplyWithQuote.footer)
            }

            Section {
                Picker(selection: $shareFormatDefault) {
                    Text("Web Link").tag("webLink")
                    Text("Text Only").tag("textOnly")
                } label: {
                    TintedLabel("Default Share Format", systemImage: "square.and.arrow.up")
                }
            } footer: {
                Text("Default format when sharing routes or repeater maps. You can override each time.")
            }

            LinkPreviewSettingsSection()
            BlockingSection()
        }
        .navigationTitle(L10n.Settings.ChatSettings.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
