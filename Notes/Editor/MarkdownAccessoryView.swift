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

    /// The most used first, because the bar scrolls sideways and the last ones are off screen. The paperclip goes in after
    /// the third (see `init`).
    private static let items: [Item] = [
        Item(command: .heading, label: "Heading", symbol: "h.square", title: nil),
        Item(command: .checklist, label: "Checklist", symbol: "checklist", title: nil),
        Item(command: .table, label: "Table", symbol: "tablecells", title: nil),
        Item(command: .bold, label: "Bold", symbol: "bold", title: nil),
        Item(command: .italic, label: "Italic", symbol: "italic", title: nil),
        Item(command: .strikethrough, label: "Strikethrough", symbol: "strikethrough", title: nil),
        Item(command: .bulletList, label: "Bulleted list", symbol: "list.bullet", title: nil),
        Item(command: .numberedList, label: "Numbered list", symbol: "list.number", title: nil),
        Item(command: .quote, label: "Quote", symbol: "text.quote", title: nil),
        Item(command: .codeBlock, label: "Code block", symbol: nil, title: "```"),
        Item(command: .inlineCode, label: "Inline code", symbol: "chevron.left.forwardslash.chevron.right", title: nil),
        Item(command: .link, label: "Link", symbol: "link", title: nil),
    ]

    init(
        onCommand: @escaping (MarkdownCommand) -> Void,
        onAttach: @escaping (AttachmentSource) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        // The default style draws no background of its own, so only the glass bar below is visible.
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 56), inputViewStyle: .default)
        allowsSelfSizing = true
        backgroundColor = .clear
        isOpaque = false

        // A floating capsule of Liquid Glass, as the system's own toolbars use.
        let glass = UIGlassEffect()
        glass.isInteractive = true
        let bar = UIVisualEffectView(effect: glass)
        bar.cornerConfiguration = .capsule()
        bar.translatesAutoresizingMaskIntoConstraints = false

        var buttons = Self.items.map { Self.button(for: $0, action: onCommand) }
        buttons.insert(Self.attachButton(onAttach), at: 3)
        let stack = UIStackView(arrangedSubviews: buttons)
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

        addSubview(bar)
        bar.contentView.addSubview(scroll)
        bar.contentView.addSubview(dismiss)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -8),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),

            dismiss.trailingAnchor.constraint(equalTo: bar.contentView.trailingAnchor, constant: -4),
            dismiss.centerYAnchor.constraint(equalTo: bar.contentView.centerYAnchor),
            dismiss.widthAnchor.constraint(equalToConstant: 44),

            scroll.leadingAnchor.constraint(equalTo: bar.contentView.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: dismiss.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.contentView.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.contentView.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// A paperclip that opens a menu of places to add an attachment from.
    private static func attachButton(_ onAttach: @escaping (AttachmentSource) -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        configuration.image = UIImage(systemName: "paperclip")
        let button = UIButton(configuration: configuration)
        var actions = [
            UIAction(title: String(localized: "Photo Library"), image: UIImage(systemName: "photo.on.rectangle")) { _ in onAttach(.photoLibrary) },
        ]
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            actions.append(UIAction(title: String(localized: "Take Photo"), image: UIImage(systemName: "camera")) { _ in onAttach(.camera) })
        }
        actions.append(UIAction(title: String(localized: "Choose File"), image: UIImage(systemName: "doc")) { _ in onAttach(.file) })
        button.menu = UIMenu(children: actions)
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = String(localized: "Attach")
        return button
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
