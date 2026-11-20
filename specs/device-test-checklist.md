# Device test checklist

Everything here is built and passes automated tests or previews, but has **not been tried on a real device**. Use a Mac and an iPhone signed into the same iCloud account. Mark each line **Pass**, **Fail**, or **Odd**, and write down what you saw for anything that isn't Pass.

Run the app from Xcode on each device first. Do the iPhone checks on the iPhone and the Mac checks on the Mac, unless a line says both.

## 1. Sync (Spec 02)

| # | Do this | Expect |
|---|---|---|
| 1.1 | Create a note on the iPhone | It appears on the Mac within about a minute |
| 1.2 | Edit it on the Mac | The change reaches the iPhone |
| 1.3 | Turn on Airplane Mode on the iPhone. The sidebar footer should say **Offline** and **Last synced …** | The footer wording matches; the app still works |
| 1.4 | Edit the note while offline, then reconnect | The footer goes through **Syncing…** to **Synced** and the Mac gets the edit |
| 1.5 | Sign out of iCloud in Settings, reopen the app | Footer says **Not syncing**; tapping it explains why; notes still work |
| 1.6 | Tap the footer | A popover explains the state in plain language |

## 2. Editor conflict fix (Spec 06)

This is the riskiest change. It decides what happens when a note changes while it is open.

| # | Do this | Expect |
|---|---|---|
| 2.1 | Open a note on the Mac and don't type. Edit the same note on the iPhone | The Mac editor updates to the new text |
| 2.2 | Open a note on the Mac and type a few words (don't wait). On the iPhone, add a line to the same note | Your typed words stay. A notice says another change was saved to Version History |
| 2.3 | Open that note's Version History | The other version is listed as "Changed at the same time as your edit" |
| 2.4 | Type, then immediately switch to another note | Nothing you typed is lost |

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
| 4.4 | Look at the keyboard bar | A floating rounded bar of Liquid Glass above the keyboard; every button works |
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
| 6.1 | iPhone: open a folder, then go back | The sync text at the bottom does **not** jump while going back |
| 6.2 | Create a folder, a tag, and move notes between them | Counts update; Recently Deleted restores |
| 6.3 | Search "cafe" with a note titled "Café" | It is found; the All Notes / Here switch works |
| 6.4 | Rotate the iPad (or resize the Mac window) | Columns adapt; the footer stays at the bottom |

## When something fails

Note the device, the iOS or macOS version, and the exact steps. For 2.x and 3.x also note whether the app was open and which note was focused. Anything marked **Fail** or **Odd** goes to the top of the next session.
