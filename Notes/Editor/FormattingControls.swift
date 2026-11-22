import SwiftUI
import NotesCore

#if canImport(UIKit)
import UIKit
#endif

/// One title and symbol per formatting command, shared by the Mac toolbar and the iPhone keyboard bar.
extension MarkdownCommand {
    var title: LocalizedStringKey {
        switch self {
        case .heading: "Heading"
        case .bold: "Bold"
        case .italic: "Italic"
        case .strikethrough: "Strikethrough"
        case .checklist: "Checklist"
        case .table: "Table"
        case .formatTable: "Format Table"
        case .bulletList: "Bulleted List"
        case .numberedList: "Numbered List"
        case .quote: "Quote"
        case .inlineCode: "Inline Code"
        case .codeBlock: "Code Block"
        case .link: "Link"
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
        case .formatTable: "tablecells.badge.ellipsis"
        case .bulletList: "list.bullet"
        case .numberedList: "list.number"
        case .quote: "text.quote"
        case .inlineCode: "chevron.left.forwardslash.chevron.right"
        case .codeBlock: "curlybraces"
        case .link: "link"
        }
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

    private var hasCamera: Bool {
        #if os(iOS)
        UIImagePickerController.isSourceTypeAvailable(.camera)
        #else
        false
        #endif
    }

    var body: some View {
        Menu("Attach", systemImage: "paperclip") {
            Button("Photo Library…", systemImage: "photo.on.rectangle") { attach(.photoLibrary) }
            if hasCamera {
                Button("Take Photo", systemImage: "camera") { attach(.camera) }
            }
            Button("Choose File…", systemImage: "doc") { attach(.file) }
        }
    }
}

#if os(macOS)
/// The Mac has no keyboard bar, so the formatting commands live in the window toolbar.
struct FormattingToolbarContent: ToolbarContent {
    let commands: EditorCommands

    var body: some ToolbarContent {
        // The most used first: the system folds the last buttons into the » menu when the window is narrow.
        ToolbarItemGroup(placement: .secondaryAction) {
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
                CommandButton(.formatTable, perform: commands.perform)
            }
        }
    }
}
#endif

#if os(iOS)
/// The row of Markdown controls above the iPhone keyboard. Scrolls sideways when it does not fit.
/// Typing ``` or # on a phone keyboard takes several taps, so these are one tap each.
struct KeyboardFormattingBar: View {
    let perform: (MarkdownCommand) -> Void
    let attach: (AttachmentSource) -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                // The most used first, because the last ones are off screen.
                HStack(spacing: 2) {
                    CommandButton(.heading, perform: perform)
                    CommandButton(.checklist, perform: perform)
                    CommandButton(.table, perform: perform)
                    AttachMenu(attach: attach)
                    CommandButton(.bold, perform: perform)
                    CommandButton(.italic, perform: perform)
                    CommandButton(.strikethrough, perform: perform)
                    CommandButton(.bulletList, perform: perform)
                    CommandButton(.numberedList, perform: perform)
                    CommandButton(.quote, perform: perform)
                    Button { perform(.codeBlock) } label: {
                        Text(verbatim: "```").font(.body.monospaced().weight(.semibold))
                    }
                    .accessibilityLabel(Text(MarkdownCommand.codeBlock.title))
                    CommandButton(.inlineCode, perform: perform)
                    CommandButton(.link, perform: perform)
                }
                .padding(.horizontal, 6)
            }
            .scrollIndicators(.hidden)

            Button("Hide Keyboard", systemImage: "keyboard.chevron.compact.down", action: dismiss)
                .padding(.trailing, 4)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .menuStyle(.button)
        .frame(height: 48)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}
#endif
