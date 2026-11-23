import SwiftUI
import SwiftData
import NotesCore

/// One note in the list, laid out like Apple Notes: the title, then the date and the start of the text on one line, then
/// the folder when the list mixes folders.
struct NoteRow: View {
    let note: Note
    let now: Date
    @Environment(\.calendar) private var calendar
    /// The search text. Matching words are highlighted in the title and preview.
    let query: String
    /// Shows the folder name, for lists that mix folders (All Notes and search results).
    let showsFolder: Bool
    /// Shows a pin beside the title. The grouped list already has a Pinned section, so only a flat list needs it.
    let showsPin: Bool
    /// Uses `deletedAt` instead of `modifiedAt` for rows in Recently Deleted.
    var showsDeletedDate = false

    var body: some View {
        if !note.isDeleted, note.modelContext != nil {
            let searchWords = NoteSearch.words(in: query)
            let displayDate = showsDeletedDate ? (note.deletedAt ?? note.modifiedAt) : note.modifiedAt
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if showsPin && note.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.caption)
                                .foregroundStyle(.tint)
                                .accessibilityLabel("Pinned")
                        }
                        titleView(words: searchWords)
                            .font(.headline)
                            .lineLimit(1)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Self.dateText(for: displayDate, now: now, calendar: calendar))
                            .layoutPriority(1)
                        previewView(words: searchWords)
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .lineLimit(1)

                    if showsFolder, let folder = note.folder, !folder.isDeleted, folder.modelContext != nil {
                        Label {
                            Text(verbatim: folder.displayName)
                        } icon: {
                            Image(systemName: "folder")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // A picture at the very start of the note shows at the end of its row, as in Apple Notes.
                if let imageID = NoteText.leadingImageID(in: note.body) {
                    NoteThumbnail(note: note, imageID: imageID)
                        .id(imageID)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func titleView(words: [String]) -> some View {
        if note.title.isEmpty {
            Text("New Note")
        } else if words.isEmpty {
            Text(verbatim: note.title)
        } else {
            Text(Self.highlighted(note.title, words: words, emphasizeWithTint: true))
        }
    }

    @ViewBuilder
    private func previewView(words: [String]) -> some View {
        let text = words.isEmpty
            ? note.snippet
            : (NoteSearch.snippet(in: note.body, query: query, skippingTitleLine: true) ?? note.snippet)
        if text.isEmpty {
            Text("No additional text")
        } else if words.isEmpty {
            Text(verbatim: text)
        } else {
            Text(Self.highlighted(text, words: words, emphasizeWithTint: false))
        }
    }

    private static func highlighted(_ text: String, words: [String], emphasizeWithTint: Bool) -> AttributedString {
        var attributed = AttributedString(text)
        for word in words {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let found = text[searchStart...].localizedStandardRange(of: word),
                  let range = Range(found, in: attributed) {
                if emphasizeWithTint {
                    attributed[range].foregroundColor = .accentColor
                } else {
                    attributed[range].inlinePresentationIntent = .stronglyEmphasized
                }
                searchStart = found.upperBound
            }
        }
        return attributed
    }

    /// The time today, Yesterday, the weekday for the rest of the week, then the date.
    static func dateText(for date: Date, now: Date, calendar: Calendar) -> String {
        switch NoteRowDateStyle(date: date, now: now, calendar: calendar) {
        case .time: date.formatted(date: .omitted, time: .shortened)
        case .yesterday: String(localized: "Yesterday")
        case .weekday: date.formatted(.dateTime.weekday(.wide))
        case .date: date.formatted(date: .numeric, time: .omitted)
        }
    }
}

extension NoteDateGroup {
    /// The section heading for this group.
    func title(calendar: Calendar) -> Text {
        switch self {
        case .today: Text("Today")
        case .yesterday: Text("Yesterday")
        case .previous7Days: Text("Previous 7 Days")
        case .previous30Days: Text("Previous 30 Days")
        case .month(let year, let month):
            Text(calendar.date(from: DateComponents(year: year, month: month)) ?? .now, format: .dateTime.month(.wide))
        case .year(let year): Text(verbatim: String(year))
        }
    }
}
