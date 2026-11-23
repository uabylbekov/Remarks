import SwiftUI
import RemarksCore

#if canImport(UIKit)
import UIKit
#endif

/// One title and symbol per formatting command, shared by the Mac toolbar and the iPhone keyboard bar.
extension MarkdownCommand {
    var title: String {
        switch self {
        case .heading: String(localized: "Heading")
        case .bold: String(localized: "Bold")
        case .italic: String(localized: "Italic")
        case .strikethrough: String(localized: "Strikethrough")
        case .checklist: String(localized: "Checklist")
        case .table: String(localized: "Table")
        case .bulletList: String(localized: "Bulleted List")
        case .numberedList: String(localized: "Numbered List")
        case .quote: String(localized: "Quote")
        case .inlineCode: String(localized: "Inline Code")
        case .codeBlock: String(localized: "Code Block")
        case .link: String(localized: "Link")
        case .math: String(localized: "Equation")
        case .diagram: String(localized: "Diagram")
        }
    }

    var systemImage: String {
        switch self {
        case .heading: "textformat"
        case .bold: "bold"
        case .italic: "italic"
        case .strikethrough: "strikethrough"
        case .checklist: "checklist"
        case .table: "tablecells"
        case .bulletList: "list.bullet"
        case .numberedList: "list.number"
        case .quote: "text.quote"
        case .inlineCode: "chevron.left.forwardslash.chevron.right"
        case .codeBlock: "curlybraces"
        case .link: "link"
        case .math: "function"
        case .diagram: "point.3.connected.trianglepath.dotted"
        }
    }
}

/// One command catalog for every surface that offers formatting. Add commands here so one surface cannot silently lose an
/// editing capability.
enum EditorCommandCatalog {
    /// Every command, in the order the keyboard bar shows them: the most used first, because the last ones are scrolled
    /// out of sight.
    static let keyboardBar: [MarkdownCommand] = [
        .heading, .bold, .italic, .checklist, .bulletList, .numberedList, .quote, .table,
        .codeBlock, .inlineCode, .link, .strikethrough, .math, .diagram,
    ]
}

extension AttachmentSource {
    var title: String {
        switch self {
        case .photoLibrary: String(localized: "Photo Library…")
        case .camera: String(localized: "Take Photo")
        case .file: String(localized: "Choose File…")
        }
    }

    var systemImage: String {
        switch self {
        case .photoLibrary: "photo.on.rectangle"
        case .camera: "camera"
        case .file: "doc"
        }
    }

    /// The places this device can add an attachment from. The camera is offered only where there is one.
    static var available: [AttachmentSource] {
        #if os(iOS)
        let hasCamera = UIImagePickerController.isSourceTypeAvailable(.camera)
        return [.photoLibrary] + (hasCamera ? [.camera] : []) + [.file]
        #else
        return [.photoLibrary, .file]
        #endif
    }
}

/// A button that runs one formatting command and reflects whether that formatting is active at the caret.
struct CommandButton: View {
    let command: MarkdownCommand
    var isActive: Bool = false
    let perform: (MarkdownCommand) -> Void

    init(_ command: MarkdownCommand, isActive: Bool = false, perform: @escaping (MarkdownCommand) -> Void) {
        self.command = command
        self.isActive = isActive
        self.perform = perform
    }

    var body: some View {
        Button(command.title, systemImage: command.systemImage) { perform(command) }
            .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// The paperclip menu of places to add an attachment from.
struct AttachMenu: View {
    let attach: (AttachmentSource) -> Void

    var body: some View {
        Menu("Attach", systemImage: "paperclip") {
            ForEach(AttachmentSource.available, id: \.self) { source in
                Button(source.title, systemImage: source.systemImage) { attach(source) }
            }
        }
    }
}

#if os(macOS)
/// The Mac has no keyboard bar, so the formatting commands live in the window toolbar.
struct FormattingToolbarContent: ToolbarContent {
    let commands: EditorCommands?
    /// Off while no note is open or a note is in Recently Deleted, so the toolbar is there but inactive, as in Apple Notes.
    var isEnabled = true

    private var isDisabled: Bool {
        !isEnabled || commands == nil || commands?.isEditingTableCell == true || commands?.isReadOnly == true
    }

    private func isActive(_ command: MarkdownCommand) -> Bool {
        !isDisabled && commands?.activeCommands.contains(command) == true
    }

    var body: some ToolbarContent {
        // The most used first: the system folds the last buttons into the » menu when the window is narrow.
        ToolbarItemGroup(placement: .secondaryAction) {
            Group {
                CommandButton(.heading, isActive: isActive(.heading)) { commands?.perform($0) }
                CommandButton(.bold, isActive: isActive(.bold)) { commands?.perform($0) }
                CommandButton(.italic, isActive: isActive(.italic)) { commands?.perform($0) }
                CommandButton(.checklist, isActive: isActive(.checklist)) { commands?.perform($0) }
                CommandButton(.table, isActive: isActive(.table)) { commands?.perform($0) }
                AttachMenu { commands?.attach(from: $0) }
                CommandButton(.bulletList, isActive: isActive(.bulletList)) { commands?.perform($0) }
                CommandButton(.numberedList, isActive: isActive(.numberedList)) { commands?.perform($0) }
                Menu("More", systemImage: "ellipsis") {
                    // macOS 27 hides SF Symbols in menus by default unless explicitly opted in.
                    Group {
                        CommandButton(.strikethrough, isActive: isActive(.strikethrough)) { commands?.perform($0) }
                        CommandButton(.quote, isActive: isActive(.quote)) { commands?.perform($0) }
                        CommandButton(.inlineCode, isActive: isActive(.inlineCode)) { commands?.perform($0) }
                        CommandButton(.codeBlock, isActive: isActive(.codeBlock)) { commands?.perform($0) }
                        CommandButton(.math, isActive: isActive(.math)) { commands?.perform($0) }
                        CommandButton(.diagram, isActive: isActive(.diagram)) { commands?.perform($0) }
                        CommandButton(.link, isActive: isActive(.link)) { commands?.perform($0) }
                    }
                    .labelStyle(.titleAndIcon)
                }
            }
            .disabled(isDisabled)
        }
    }
}
#endif

#if os(iOS)
private extension View {
    /// A square the size of the smallest comfortable tap, as the Human Interface Guidelines ask.
    func touchTarget() -> some View {
        frame(width: 44, height: 44).contentShape(.rect)
    }
}

/// The bar above the keyboard: every command in a scrolling glass capsule, attachments after the lists and tables, and
/// a separate Hide Keyboard button. It floats with a gap above the keyboard, like the system's own bars.
struct KeyboardFormattingBar: View {
    let commands: EditorCommands?
    let perform: (MarkdownCommand) -> Void
    let attach: (AttachmentSource) -> Void
    let dismiss: () -> Void

    private var formattingDisabled: Bool {
        commands?.isEditingTableCell == true || commands?.isReadOnly == true
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(EditorCommandCatalog.keyboardBar, id: \.self) { command in
                            let active = !formattingDisabled && commands?.activeCommands.contains(command) == true
                            CommandButton(command, isActive: active, perform: perform)
                                .touchTarget()
                                .background {
                                    if active {
                                        Circle()
                                            .fill(.tint.opacity(0.16))
                                            .padding(4)
                                    }
                                }
                            if command == .table {
                                AttachMenu(attach: attach)
                                    .touchTarget()
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .scrollIndicators(.hidden)
                .glassEffect(.regular, in: .capsule)
                // While a table cell owns input or a note is read-only, disable formatting while keeping Hide Keyboard active.
                .disabled(formattingDisabled)

                Button("Hide Keyboard", systemImage: "keyboard.chevron.compact.down", action: dismiss)
                    .touchTarget()
                    .glassEffect(.regular.interactive(), in: .circle)
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .menuStyle(.button)
        .font(.title3)
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
}
#endif
