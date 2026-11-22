#if canImport(UIKit)
import SwiftUI
import UIKit
import NotesCore

/// Hosts `KeyboardFormattingBar` above the keyboard. A text view built on UIKit has no SwiftUI focus, so the
/// `.keyboard` toolbar placement would not show for it, and an input accessory view is the way to attach the bar.
final class MarkdownAccessoryView: UIInputView {
    private let host: UIHostingController<KeyboardFormattingBar>

    init(
        onCommand: @escaping (MarkdownCommand) -> Void,
        onAttach: @escaping (AttachmentSource) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        host = UIHostingController(rootView: KeyboardFormattingBar(perform: onCommand, attach: onAttach, dismiss: onDismiss))
        // The default style draws no background of its own, so only the glass bar is visible.
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 56), inputViewStyle: .default)
        allowsSelfSizing = true
        backgroundColor = .clear
        isOpaque = false

        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 8),
            host.view.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -8),
            host.view.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            host.view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
#endif
