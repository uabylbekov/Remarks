# Device test checklist

Everything here is built and passes automated tests or previews, but has **not been tried on a real device**. Use a Mac and an iPhone signed into the same iCloud account. Mark each line **Pass**, **Fail**, or **Odd**, and write down what you saw for anything that isn't Pass.

Run the app from Xcode on each device first. Do the iPhone checks on the iPhone and the Mac checks on the Mac, unless a line says both.

## 1. Sync (Spec 02)

| # | Do this | Expect |
|---|---|---|
| 1.1 | Create a note on the iPhone | It appears on the Mac within about a minute |
| 1.2 | Edit it on the Mac | The change reaches the iPhone |
| 1.3 | Turn on Airplane Mode on the iPhone and edit a note, then reconnect | The edit reaches the Mac once the iPhone is back online. (The app shows no sync status of its own; iCloud settings do) |

## 2. Editor conflict fix (Spec 06)

This is the riskiest change. It decides what happens when a note changes while it is open.

| # | Do this | Expect |
|---|---|---|
| 2.1 | Open a note on the Mac and don't type. Edit the same note on the iPhone | The Mac editor updates to the new text |
| 2.2 | Open a note on the Mac and type a few words (don't wait). On the iPhone, add a line and an attachment to the same note | Your typed words stay. If both sides changed from the editor's last known text, the incoming version is preserved as a separate note with working attachments |
| 2.3 | Type, then immediately switch to another note | Nothing you typed is lost |

## 3. Siri and Shortcuts (Spec 06)

| # | Do this | Expect |
|---|---|---|
| 3.1 | Open the Shortcuts app and look for the app's actions | Create Note, Add to Note, Find Notes, Get Note Text, Open Note, Move Note to Recently Deleted |
| 3.2 | Run **Create Note** with some text | A note appears in the app and the result shows its title |
| 3.3 | Quit the app fully, then say "Create a note in Notes" to Siri | The note is created without the app opening to a blank screen |
| 3.4 | Run **Add to Note** on a note | The text is added at the end, on a new line |
| 3.5 | Run **Add to Note** while that note is open and focused | The text is not lost (see 2.2) |
| 3.6 | In Shortcuts, add **Find Notes** and filter by title, pinned, or folder | The right notes come back, newest first |
| 3.7 | Run **Get Note Text** | The Markdown text comes back |
| 3.8 | Run **Open Note** | The app opens on that note |
| 3.9 | Run **Move Note to Recently Deleted** | It asks first; the note is in Recently Deleted afterward |
| 3.10 | Run an action on a note that is in Recently Deleted | A clear message, not a generic failure |

## 4. Editor look and feel

| # | Do this | Expect |
|---|---|---|
| 4.1 | Type a fenced code block on the iPhone (use the ``` button on the keyboard bar) | A card appears with a language label when you tap outside it |
| 4.2 | Tap into the code block, then out again | The card does not change size and nothing below it moves |
| 4.3 | Put blank lines inside a code block | No thin lines between the code lines |
| 4.4 | Look at the keyboard bar | Native formatting and attachment menus, checklist/table buttons, and keyboard dismissal work; the top toolbar also exposes formatting and attachments with the keyboard hidden |
| 4.5 | Type `- [ ]` and Return | A new checkbox line; tapping a box toggles it |
| 4.6 | Select text and press ⌘B, ⌘I (Mac) | Bold and italic wrap the selection |

## 5. Appearance settings (Spec 11)

| # | Do this | Expect |
|---|---|---|
| 5.1 | iPhone: tap the **Aa** button in the sidebar. Mac: press ⌘, | Settings opens with a live preview |
| 5.2 | Change the text font, size, and code theme with a note open behind it | The open note restyles right away |
| 5.3 | Pick **Fira Code**, **JetBrains Mono**, and **IBM Plex Mono** for code | The code font changes; `->` shows as an arrow in Fira Code |
| 5.4 | Change a setting on the Mac, wait a minute, open the app on the iPhone | The same setting is there (this one can take a while) |
| 5.5 | **Reset to Defaults** | Everything returns to the default look |

## 6. Sidebar and navigation

| # | Do this | Expect |
|---|---|---|
| 6.1 | iPhone: open a folder, then go back | The sidebar does not jump while going back |
| 6.2 | Create a folder, a tag, and move notes between them | Counts update; Recently Deleted restores |
| 6.3 | Search "cafe" with a note titled "Café" | It is found; the All Notes / Here switch works |
| 6.4 | Rotate the iPad (or resize the Mac window) | Columns adapt |

## 7. Attachments (Spec 07)

| # | Do this | Expect |
|---|---|---|
| 7.1 | iPhone: tap the paperclip on the keyboard bar, choose **Photo Library**, pick a photo | The photo appears inline in the note, on its own line |
| 7.2 | Paperclip, **Take Photo** (iPhone) | The camera asks for permission once, then the photo is added |
| 7.3 | Paperclip, **Choose File**, pick a PDF | A chip with the file name and size appears; tapping it opens Quick Look (the same panel on the Mac) |
| 7.4 | Mac: paperclip in the toolbar, **Photo Library…** and **Choose File…** | The same results; clicking a chip opens the Quick Look panel |
| 7.5 | Mac: drag a file from Finder into the note | It is added at the caret |
| 7.6 | Move the caret up and down through the picture and chip lines | Nothing around them shifts; the raw `![…](attachment://…)` text shows only while the caret is on the line |
| 7.7 | Add a very large file (over 25 MB) | A message says it is too large and nothing is added |
| 7.8 | Add a note with a photo on the Mac, open it on the iPhone | The text arrives first, then the picture fills in |
| 7.9 | Delete the picture's line, then undo | The picture comes back |
| 7.10 | Look at the note in the list | The row shows the attachment's name, not a link |
| 7.11 | Copy a picture (screenshot or from another app), tap into a note, paste | It is added as an attachment, on its own line |
| 7.12 | Mac: copy a file in Finder, paste into a note | It is added as an attachment |
| 7.13 | Copy text from a web page that has pictures, paste | Only the text is pasted |
| 7.14 | Note menu, **Export as Markdown…**, pick a place | A folder with the `.md` file and an `attachments` folder; opening the `.md` in another editor shows the pictures |

## 8. Tables and the formatting toolbar

| # | Do this | Expect |
|---|---|---|
| 8.1 | Mac: look at the editor toolbar | Heading, Bold, Italic, Checklist, **Table**, **Attach** (paperclip), the two lists, and a **More** menu. Narrow the window: the last buttons fold into the » menu first |
| 8.2 | iPhone: look at the keyboard bar | Heading, Checklist, **Table**, **paperclip** come first, then the other buttons |
| 8.3 | Tap **Table** | A 3 by 3 table is inserted with "Column 1" selected, drawn as a card with a bold header |
| 8.4 | Add a photo or file, and the caret ends on the line after it | The attachment shows as a picture or chip, not as raw text |
| 8.5 | A wide table on an iPhone | The row is cut at the edge (it does not scroll sideways yet) |

## 9. Spotlight (Spec 06)

| # | Do this | Expect |
|---|---|---|
| 9.1 | Create a note called "Zebra plan", wait a few seconds, search "Zebra" in Spotlight | The note appears; choosing it opens the app on that note |
| 9.2 | Move the note to Recently Deleted and search again | It is gone from Spotlight |
| 9.3 | Settings, turn off **Show Notes in Spotlight**, search again | Nothing from the app appears; turning it back on brings the notes back |
| 9.4 | Search for a word that is only in the middle of a note's text | It is not found (only titles, previews, and tags are indexed) |

## 10. Editor polish, spacing, and settings

| # | Do this | Expect |
|---|---|---|
| 10.1 | Type `- ` and some text | A dot appears in place of the dash; the stored text still has the dash |
| 10.2 | Type `> ` and some text, on two lines | A bar at the left of both lines, softer text, and no shifting when the caret enters or leaves |
| 10.3 | Type `---` on its own line, then move away | A horizontal line across the text |
| 10.4 | Tap a link in a line the caret is not on (iPhone), or click it (Mac) | It opens. In the line the caret is on, a tap only places the caret |
| 10.5 | A table with many columns on the iPhone | The font shrinks to fit (down to 60%); rotate the phone and it re-fits |
| 10.6 | Settings, drag **Line Spacing** | Open notes re-space at once; typing the first letter on a new empty line does not move the line |
| 10.7 | Settings, turn **Ligatures** off with Fira Code or JetBrains Mono | `->` and `!=` in code show as separate characters |
| 10.8 | Install over an older build that has notes (schema migration) | The app opens and the notes are all there |

## When something fails

Note the device, the iOS or macOS version, and the exact steps. For 2.x and 3.x also note whether the app was open and which note was focused. Anything marked **Fail** or **Odd** goes to the top of the next session.
