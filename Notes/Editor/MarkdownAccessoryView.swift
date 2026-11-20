#if canImport(UIKit)
import UIKit
import NotesCore

/// The row of Markdown controls above the iPhone keyboard. Scrolls sideways when it does not fit.
/// Typing ``` or # on a phone keyboard takes several taps, so these are one tap each.
final class MarkdownAccessoryView: UIInputView {
    private struct Item {
        let command: MarkdownCommand
        let label: String
        let symbol: String?
        /// Shown instead of a symbol when the control reads better as text, such as the code fence.
        let title: String?
    }

    private static let items: [Item] = [
        Item(command: .codeBlock, label: "Code block", symbol: nil, title: "```"),
        Item(command: .inlineCode, label: "Inline code", symbol: "chevron.left.forwardslash.chevron.right", title: nil),
        Item(command: .heading, label: "Heading", symbol: "textformat.size", title: nil),
        Item(command: .bold, label: "Bold", symbol: "bold", title: nil),
        Item(command: .italic, label: "Italic", symbol: "italic", title: nil),
        Item(command: .strikethrough, label: "Strikethrough", symbol: "strikethrough", title: nil),
        Item(command: .bulletList, label: "Bulleted list", symbol: "list.bullet", title: nil),
        Item(command: .numberedList, label: "Numbered list", symbol: "list.number", title: nil),
        Item(command: .checklist, label: "Checklist", symbol: "checklist", title: nil),
        Item(command: .quote, label: "Quote", symbol: "text.quote", title: nil),
        Item(command: .link, label: "Link", symbol: "link", title: nil),
    ]

    init(onCommand: @escaping (MarkdownCommand) -> Void, onDismiss: @escaping () -> Void) {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 48), inputViewStyle: .keyboard)
        allowsSelfSizing = true

        let stack = UIStackView(arrangedSubviews: Self.items.map { Self.button(for: $0, action: onCommand) })
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        var dismissConfiguration = UIButton.Configuration.plain()
        dismissConfiguration.image = UIImage(systemName: "keyboard.chevron.compact.down")
        let dismiss = UIButton(configuration: dismissConfiguration, primaryAction: UIAction { _ in onDismiss() })
        dismiss.accessibilityLabel = "Hide keyboard"
        dismiss.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroll)
        addSubview(dismiss)
        NSLayoutConstraint.activate([
            dismiss.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            dismiss.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismiss.widthAnchor.constraint(equalToConstant: 48),

            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: dismiss.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static func button(for item: Item, action: @escaping (MarkdownCommand) -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        if let symbol = item.symbol {
            configuration.image = UIImage(systemName: symbol)
        } else if let title = item.title {
            var attributed = AttributedString(title)
            attributed.uiKit.font = UIFont.monospacedSystemFont(ofSize: 17, weight: .semibold)
            configuration.attributedTitle = attributed
        }
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action(item.command) })
        button.accessibilityLabel = item.label
        return button
    }
}
#endif
