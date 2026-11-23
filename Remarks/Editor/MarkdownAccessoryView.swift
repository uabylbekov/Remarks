#if canImport(UIKit)
import SwiftUI
import UIKit
import RemarksCore

/// Hosts `KeyboardFormattingBar` above the keyboard. A UIKit text view has no SwiftUI focus, so the `.keyboard` toolbar
/// placement does not apply to it, and an input accessory view is the supported way to attach a bar to its keyboard.
final class MarkdownAccessoryView: UIInputView {
    private let host: UIHostingController<KeyboardFormattingBar>

    init(
        commands: EditorCommands?,
        onCommand: @escaping (MarkdownCommand) -> Void,
        onAttach: @escaping (AttachmentSource) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        host = UIHostingController(rootView: KeyboardFormattingBar(commands: commands, perform: onCommand, attach: onAttach, dismiss: onDismiss))
        // The default style draws no background of its own, so only the glass is visible.
        super.init(frame: .zero, inputViewStyle: .default)
        allowsSelfSizing = true
        // With a zero frame, the default autoresizing constraints would pin the height to zero over the bar's own height.
        autoresizingMask = .flexibleHeight

        // The keyboard's safe area is not the bar's concern.
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// The keyboard asks for a height, and the bar is the only thing that knows it, so it is measured from the SwiftUI view.
    override var intrinsicContentSize: CGSize {
        let width = bounds.width > 0 ? bounds.width : 320
        let height = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width != lastWidth {
            lastWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }

    private var lastWidth: CGFloat = 0

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
#endif
