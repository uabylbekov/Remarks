#if canImport(UIKit)
import UIKit

/// Hosts native text input across the whole area SwiftUI allocates, which reaches under the bars and the keyboard.
/// The text view is the scroll view, so UIKit turns the safe area into its content inset: text starts clear of the bars,
/// scrolls beneath them, and stays clear of the keyboard while it is up. The bars' safe area comes from UIKit. The
/// keyboard adds a bottom content inset so the final line can scroll clear of it and the accessory bar.
final class NativeEditorViewController: UIViewController {
    let textView: UITextView
    // A constrained view makes keyboard-guide movement participate in this controller's layout,
    // even though the scrolling text view itself continues to fill the whole viewport.
    private let keyboardTrackingView = UIView()

    init(textView: UITextView) {
        self.textView = textView
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        textView.translatesAutoresizingMaskIntoConstraints = false
        // `.automatic` skips content that is shorter than the view, which would start a short note under the bars.
        textView.contentInsetAdjustmentBehavior = .always
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // With no keyboard the guide sits at the view's bottom edge, so it reports no overlap.
        view.keyboardLayoutGuide.usesBottomSafeArea = false
        keyboardTrackingView.isUserInteractionEnabled = false
        keyboardTrackingView.isAccessibilityElement = false
        keyboardTrackingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyboardTrackingView)
        NSLayoutConstraint.activate([
            keyboardTrackingView.topAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            keyboardTrackingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            keyboardTrackingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardTrackingView.widthAnchor.constraint(equalToConstant: 0),
        ])
    }

    /// Raises the keyboard once the screen has finished appearing. The keyboard and its bar are glass, so raising them
    /// while the screen is still sliding in has them draw over the transition, tinted grey, until it ends.
    func focusTextView() {
        if view.window != nil, transitionCoordinator == nil {
            textView.becomeFirstResponder()
        } else {
            focusesOnAppearance = true
        }
    }

    private var focusesOnAppearance = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard focusesOnAppearance else { return }
        focusesOnAppearance = false
        textView.becomeFirstResponder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateKeyboardScrollSpace(overlap: max(0, view.bounds.maxY - view.keyboardLayoutGuide.layoutFrame.minY))
    }

    static let endOfNoteSpace: CGFloat = 120

    /// Add actual scrollable space, without changing the document or feeding keyboard overlap back into the safe area.
    func updateKeyboardScrollSpace(overlap: CGFloat) {
        let systemBottom = max(0, textView.adjustedContentInset.bottom - textView.contentInset.bottom)
        let keyboardInset = max(0, overlap - systemBottom)
        // Spare room below the last line, so the end of a note can be scrolled up and edited away from the screen edge.
        let bottomInset = keyboardInset + Self.endOfNoteSpace
        if textView.contentInset.bottom != bottomInset {
            textView.contentInset.bottom = bottomInset
            textView.verticalScrollIndicatorInsets.bottom = keyboardInset
        }
    }
}
#endif
