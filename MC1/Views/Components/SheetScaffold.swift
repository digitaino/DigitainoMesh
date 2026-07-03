import SwiftUI

/// Standard scaffolding for modal sheets: wraps content in a `NavigationStack` with a
/// navigation title (inline by default) and a toolbar.
///
/// Centralizes the navigation/title boilerplate repeated across the app's sheets while
/// leaving toolbar content fully caller-controlled, so each sheet keeps its own
/// cancel/confirm actions, validation/disabled state, and content-level modifiers
/// (alerts, sensory feedback, navigation destinations, etc.).
///
/// ```swift
/// SheetScaffold(L10n.Some.title) {
///     Form { ... }
///         .errorAlert($errorMessage)
/// } toolbar: {
///     ToolbarItem(placement: .cancellationAction) {
///         Button(L10n.Localizable.Common.cancel) { dismiss() }
///     }
/// }
/// ```
struct SheetScaffold<Content: View, Toolbar: ToolbarContent>: View {
    private let title: String
    private let titleDisplayMode: NavigationBarItem.TitleDisplayMode
    @ViewBuilder private let content: () -> Content
    @ToolbarContentBuilder private let toolbar: () -> Toolbar

    init(
        _ title: String,
        titleDisplayMode: NavigationBarItem.TitleDisplayMode = .inline,
        @ViewBuilder content: @escaping () -> Content,
        @ToolbarContentBuilder toolbar: @escaping () -> Toolbar
    ) {
        self.title = title
        self.titleDisplayMode = titleDisplayMode
        self.content = content
        self.toolbar = toolbar
    }

    var body: some View {
        NavigationStack {
            content()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(titleDisplayMode)
                .toolbar(content: toolbar)
        }
    }
}
