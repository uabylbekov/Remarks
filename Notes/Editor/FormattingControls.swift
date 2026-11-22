import SwiftUI
import NotesCore

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
        }
    }

    var systemImage: String {
        switch self {
        case .heading: "h.square"
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
        .codeBlock, .inlineCode, .link, .strikethrough,
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
        #else
        let hasCamera = false
        #endif
        return [.photoLibrary] + (hasCamera ? [.camera] : []) + [.file]
    }
}

/// A button that runs one formatting command.
struct CommandButton: View {
    let command: MarkdownCommand
    let perform: (MarkdownCommand) -> Void

    init(_ command: MarkdownCommand, perform: @escaping (MarkdownCommand) -> Void) {
        self.command = command
        self.perform = perform
    }

    var body: some View {
        Button(command.title, systemImage: command.systemImage) { perform(command) }
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
    let commands: EditorCommands
    /// Off while no note is open, so the toolbar is there but does nothing, as in Apple Notes.
    var isEnabled = true

    var body: some ToolbarContent {
        // The most used first: the system folds the last buttons into the » menu when the window is narrow.
        ToolbarItemGroup(placement: .secondaryAction) {
            Group {
                CommandButton(.heading, perform: commands.perform)
                CommandButton(.bold, perform: commands.perform)
                CommandButton(.italic, perform: commands.perform)
                CommandButton(.checklist, perform: commands.perform)
                CommandButton(.table, perform: commands.perform)
                AttachMenu(attach: commands.attach)
                CommandButton(.bulletList, perform: commands.perform)
                CommandButton(.numberedList, perform: commands.perform)
                Menu("More", systemImage: "ellipsis") {
                    CommandButton(.strikethrough, perform: commands.perform)
                    CommandButton(.quote, perform: commands.perform)
                    CommandButton(.inlineCode, perform: commands.perform)
                    CommandButton(.codeBlock, perform: commands.perform)
                    CommandButton(.link, perform: commands.perform)
                }
            }
            .disabled(!isEnabled)
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

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(EditorCommandCatalog.keyboardBar, id: \.self) { command in
                            CommandButton(command, perform: perform)
                                .touchTarget()
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
        // While a table cell owns input, a command would reach the document, not the cell.
        .disabled(commands?.isEditingTableCell == true)
    }
}
#endif
