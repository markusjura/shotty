import SwiftUI

/// The top bar of either editor while cropping: the crop's size in pixels, an aspect ratio menu,
/// Cancel, and Apply. Return applies.
struct CropBar: View {
    let size: CGSize
    let aspect: CGFloat?
    let aspects: [(title: String, ratio: CGFloat?)]
    let resize: (_ width: CGFloat?, _ height: CGFloat?) -> Void
    let setAspect: (CGFloat?) -> Void
    let cancel: () -> Void
    let apply: () -> Void

    var body: some View {
        HStack(spacing: EditorBar.buttonSpacing) {
            Text("Crop")
            field("Width", size.width) { resize($0, nil) }
            Text("×").foregroundStyle(.secondary)
            field("Height", size.height) { resize(nil, $0) }
            OptionButton("Aspect ratio") {
                Text(aspects.first { $0.ratio == aspect }?.title ?? "Freeform")
            } menu: {
                let menu = OptionMenu.make(showsState: true)
                for choice in aspects {
                    menu.addItem(OptionMenu.item(choice.title, isOn: choice.ratio == aspect) { setAspect(choice.ratio) })
                }
                return menu
            }
            .padding(.leading, EditorBar.groupSpacing - EditorBar.buttonSpacing)
            Spacer()
            Button("Cancel", action: cancel).buttonStyle(.editorBar)
            Button("Apply", action: apply)
                .keyboardShortcut(.defaultAction).buttonStyle(.editorBarProminent)
        }
        .font(EditorBar.font)
    }

    /// A crop dimension in pixels, typed into a tinted capsule. Without grouping, as German
    /// formatting would show 5120 as 5.120.
    private func field(_ title: String, _ value: CGFloat, set: @escaping (CGFloat) -> Void) -> some View {
        TextField(title, value: Binding(get: { Double(value) }, set: { set(CGFloat($0)) }), format: .number.grouping(.never))
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .monospacedDigit()
            .frame(width: 64, height: EditorBar.buttonHeight)
            .editorBarCapsule()
    }
}
