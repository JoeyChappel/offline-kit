import SwiftUI

/// The square tick box used in Prepare's lists, as a real Toggle: VoiceOver reads "Water, checkbox, ticked"
/// instead of "square, button", and the box keeps its look.
struct SquareCheckStyle: ToggleStyle {
    /// False draws only the box (the row shows its own words); the label is still what VoiceOver reads.
    var showsLabel = true
    var alignment: VerticalAlignment = .center

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: alignment, spacing: 10) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(configuration.isOn ? Color.accentColor : .secondary).imageScale(.large)
                if showsLabel {
                    configuration.label.multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}
