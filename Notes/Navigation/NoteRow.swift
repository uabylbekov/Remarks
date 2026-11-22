import SwiftUI
import NotesCore

/// One note in the list, laid out like Apple Notes: the title, then the date and the start of the text on one line, then
/// the folder when the list mixes folders.
struct NoteRow: View {
    let note: Note
    let now: Date
    @Environment(\.calendar) private var calendar
    /// The search text. Its words are shown in bold in the preview.
    let query: String
    /// Shows the folder name, for lists that mix folders (All Notes and search results).
    let showsFolder: Bool
    /// Shows a pin beside the title. The grouped list already has a Pinned section, so only a flat list needs it.
    let showsPin: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if showsPin && note.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Pinned")
                }
                if note.title.isEmpty {
                    Text("New Note").font(.headline).lineLimit(1)
                } else {
                    Text(verbatim: note.title).font(.headline).lineLimit(1)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Self.dateText(for: note.modifiedAt, now: now, calendar: calendar))
                    .layoutPriority(1)
                Text(preview)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .lineLimit(1)

            if showsFolder, let folder = note.folder {
                Label {
                    Text(verbatim: folder.name)
                } icon: {
                    Image(systemName: "folder")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The text around the first match while searching, otherwise the note's own preview.
    private var preview: AttributedString {
        let text = NoteSearch.snippet(in: note.body, query: query) ?? note.snippet
        var preview = AttributedString(text)
        for word in NoteSearch.words(in: query) {
            var searchStart = text.startIndex
            while let found = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<text.endIndex),
                  let range = Range(found, in: preview) {
                preview[range].inlinePresentationIntent = .stronglyEmphasized
                searchStart = found.upperBound
            }
        }
        return preview
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
