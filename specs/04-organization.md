# Spec 04: Organization and Search

Status: **Approved to build (2026-11-19).** Milestone: M1.
Depends on: Spec 01 (data model), Spec 03 (editor), `00-platform-design.md` (iPhone Duo, Liquid Glass).

## Decisions

| Question | Decision |
|---|---|
| How are tags added to a note? | **Tag picker only.** A menu on the note adds and removes tags. A typed `#hashtag` is ordinary text. Inline hashtag parsing is a possible later feature |
| Where does search look? | **Everywhere by default**, with a scope switch that narrows it to the current folder or tag. Matches title, body, and tag names, ignoring case and accents |

## Structure

A three-column `NavigationSplitView`: **sidebar** (where notes live), **note list**, **editor**.

On iPhone and on the iPhone Duo outer display it collapses to one column at a time. On the Duo inner display and on iPad and Mac it shows two or three columns. It uses standard components only, so it follows Liquid Glass and the Duo layout rules automatically (D1 to D10, G1 to G5).

### Sidebar

| Section | Items |
|---|---|
| (top) | **All Notes**, **Unfiled** |
| Folders | The folder tree (unlimited depth, expandable), in manual order |
| Tags | All tags, alphabetical |
| (bottom) | **Recently Deleted** |

Virtual items (All Notes, Unfiled, Recently Deleted) are queries, not stored data (Spec 01).

### Note list

- Pinned notes first, then the rest, sorted by **date modified**, newest first. Sorting by date created or title is a later option.
- Row: title, a one-line snippet (or the matching text while searching), a pin mark, and the date.
- While searching, results are ranked: title matches first, then body and tag matches, each by date modified. Pinning does not reorder search results.
- Swipe: pin and unpin (leading edge), delete (trailing edge). In Recently Deleted: restore and delete forever.
- Context menu (touch and pointer): Pin, Move to a folder (including Unfiled), Tags, Delete.
- Empty states for no notes, no results, and an empty Recently Deleted.

### Folders

- Create (top level or inside a folder), rename, delete, and move notes into folders.
- Deleting a folder moves it and its subtree and notes to Recently Deleted together, and restoring undoes exactly that (Spec 01).
- Reordering and moving folders by drag is a follow-up. For now new folders append after their siblings.

### Tags

- A menu on the editor lists all tags with checkmarks for the ones on this note, and **New Tag…**.
- Tag names are matched ignoring case and accents. Creating a duplicate reuses the existing tag.
- Selecting a tag in the sidebar lists the notes that have it.
- Renaming and deleting a tag happen from its sidebar context menu. Deleting a tag removes it from all notes and never deletes a note.

### Search

- A search field above the note list.
- Every word typed must match somewhere in the note's title, body, or tag names (all words, any order).
- A scope switch under the field: **All Notes** (default) or **Here** (the selected folder or tag).
- Recently Deleted is searched only when it is the selected sidebar item.
- Case and accents are ignored: "cafe" finds "Café".

## Where the logic lives

Pure and tested in `NotesCore`: `NoteScope`, `NoteFilter` (scope, search, sorting, ranking), search snippets, and the folder and tag operations (rename, remove tag, delete tag, delete forever, empty trash). The views only call these, so the Siri and App Intents work (milestone 3) can reuse them.

## Keyboard shortcuts

⌘N new note, ⇧⌘N new folder, ⌘F search. Delete key moves the selected note to Recently Deleted.

## Acceptance criteria

1. Notes can be filed into folders, found by folder, by tag, and by search, and restored from Recently Deleted.
2. Search finds a word in the title, in the body, and in a tag name, ignoring case and accents, and requires all words.
3. Folder deletion, restore, and the tree behave as in Spec 01's tests, now visible in the UI.
4. A note created while a folder is selected goes into that folder. While a tag is selected it gets that tag.
5. Lists stay correct when a note changes on another device (sync) while visible.
6. Works on iPhone, iPhone Duo (outer and inner display, folded and open), iPad, and Mac window resizing.
7. VoiceOver reads each row as title, snippet, and date, and sidebar items with their counts.
8. 5,000 notes: scrolling and search remain responsive.

## Known gaps and later work

- Drag to reorder or nest folders, and drag notes onto folders.
- Sort options (created, title) and list density.
- Smart folders (saved searches), inline hashtags, and search operators such as `tag:` or `in:`.
- A real full-text index. v1 filters in memory, which is fine for thousands of notes. Spotlight indexing in Spec 06 will add system-level search.
- Multi-select actions on the note list.
