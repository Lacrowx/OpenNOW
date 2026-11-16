import SwiftUI

// tvOS stand-ins for iOS-only SwiftUI API used by the shared sources, so those call
// sites compile unchanged. Each one is a no-op or the nearest tvOS equivalent.

enum TVTitleDisplayMode { case automatic, inline, large }
enum TVTextSelectability { case enabled, disabled }
enum TVSearchDrawerDisplayMode { case automatic, always }

extension View {
    func navigationBarTitleDisplayMode(_ mode: TVTitleDisplayMode) -> some View { self }
    func textSelection(_ selectability: TVTextSelectability) -> some View { self }
    func scrollContentBackground(_ visibility: Visibility) -> some View { self }
}

extension SearchFieldPlacement {
    static func navigationBarDrawer(displayMode: TVSearchDrawerDisplayMode) -> SearchFieldPlacement { .automatic }
}

extension ListStyle where Self == GroupedListStyle {
    static var insetGrouped: GroupedListStyle { .grouped }
    static var sidebar: GroupedListStyle { .grouped }
}

/// Stepped value chooser used where iOS has a slider. Controls side by side in a form row cannot be
/// focused one at a time on tvOS, so the values are offered as a menu, like the other settings.
struct TVSteppedPicker: View {
    /// A menu much longer than this is slower to use than the slider it replaces.
    private static let maximumChoices = 20

    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        let choices = choices
        TVLabeledPicker(title, selection: Binding(
            get: { choices.min { abs($0 - value) < abs($1 - value) } ?? value },
            set: { value = $0 })) {
            ForEach(choices, id: \.self) { Text(format($0)).tag($0) }
        }
    }

    /// Evenly spaced values across the range with both ends included, plus the current value when
    /// it lies between two of them, so the menu never shows a value other than the one in use.
    private var choices: [Double] {
        let steps = max(1, Int(((range.upperBound - range.lowerBound) / step).rounded()))
        let every = Int((Double(steps) / Double(Self.maximumChoices)).rounded(.up))
        var values = stride(from: 0, to: steps, by: every).map { range.lowerBound + Double($0) * step }
        values.append(range.upperBound)
        if range.contains(value), !values.contains(where: { abs($0 - value) < step / 2 }) {
            values.append(value)
            values.sort()
        }
        return values
    }
}

struct TextEditor: View {
    @Binding var text: String
    init(text: Binding<String>) { _text = text }
    var body: some View { TextField("", text: $text) }
}

/// Sharing is unavailable on tvOS; the control is omitted.
struct ShareLink<Label: View>: View {
    init<Item>(item: Item, @ViewBuilder label: () -> Label) {}
    var body: some View { EmptyView() }
}

/// iOS wraps the stream in a controller that owns orientation and pointer lock; tvOS has neither.
struct NativeStreamPresentation<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View { content }
}

/// Touch layout editor preview (launch-argument only) does not exist on tvOS.
struct NativeStreamTouchLayoutPreview: View {
    var body: some View { EmptyView() }
}

/// List editing mode is unavailable on tvOS.
struct EditButton: View {
    var body: some View { EmptyView() }
}

// tvOS has no system background colours; the app's dark surface stands in for them.
extension UIColor {
    static var systemBackground: UIColor { .black }
    static var systemGroupedBackground: UIColor { .black }
}

/// Settings chooser row: shows its value and opens the console choice panel. `SettingsView` uses
/// this in place of `Picker`.
struct TVLabeledPicker<SelectionValue: Hashable, Content: View>: View {
    private let title: String
    @Binding private var selection: SelectionValue
    private let content: Content

    init(_ title: String, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        self.title = title
        _selection = selection
        self.content = content()
    }

    var body: some View {
        TVConsolePickerRow(title: title, selection: $selection) { content }
    }
}

/// The WebRTC runtime is not part of the tvOS build; there is nothing to initialise.
enum NativeStreamWebRTCPolicy {
    static func initialize() {}
}

/// tvOS has no collapsible groups; the content is always shown under its label.
struct DisclosureGroup<Label: View, Content: View>: View {
    let label: Label
    let content: Content

    init(isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.label = label()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            label
            content
        }
    }
}

extension DisclosureGroup where Label == Text {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.label = Text(title)
        self.content = content()
    }
}
