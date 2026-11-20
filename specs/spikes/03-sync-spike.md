# Spike 03: Sync and conflicts (CloudKit via SwiftData)

Status: **Built, awaiting results (2026-11-19).** Needs the Mac and an iPhone signed into the same iCloud account.

## Purpose

Answer the questions Spec 01 and Spec 02 depend on:
1. Does the Spec 01 model sync correctly (notes, folders, tags, relationships)?
2. What happens when two devices edit the same note while offline? Is text lost?
3. Does a 2 MB note body sync (the CloudKit 1 MB record limit)?
4. Do duplicate tags appear when two devices create the same tag offline?
5. How long does sync take, and what does the event log show?

## What was built

Code in `Notes/Notes/Spikes/`: `SpikeSyncModels.swift` (the Spec 01 `Note`, `Folder`, `Tag`, with the real entity names), `SpikeSyncLabView.swift` (the UI and sync log), reached from the host picker as **Sync lab**.

- The lab uses the real container `iCloud.io.github.uabylbekov.notes` through an explicit `ModelConfiguration(cloudKitDatabase: .private(...))`.
- It shows the iCloud account status, counts, a list of notes, the selected note's body (first 2,000 characters), and a log of CloudKit setup, import, and export events with errors.
- **Device label** (editable) is written into every stamp, so you can see which device wrote which line.
- Buttons: New note, New 2 MB note, Add tag "swift", New folder. For a selected note: Append stamp, Replace body, Tag it, Delete.

**Development schema note:** running the lab creates the `Note`, `Folder`, and `Tag` record types in the CloudKit **development** environment. That is fine and resettable in the CloudKit Console (Reset Development Environment) if we change the model. Nothing reaches production until we promote the schema.

**Not covered:** `initializeCloudKitSchema` (the docs' step that creates every field up front). Optional fields that are never set, such as `deletedAt`, may not exist in the schema until they have a value. Add the call to the M0 release checklist.

## Setup

1. **Mac:** choose the **Notes** scheme and **My Mac**, press Run, and pick **Sync lab**.
2. **iPhone:** connect it, enable Developer Mode if asked (Settings > Privacy & Security), choose it as the run destination, and Run. The first install asks you to trust your developer certificate. Pick **Sync lab**.
3. Both devices must show `iCloud: available`. If one shows NO ACCOUNT, sign in to iCloud on it.
4. Debug builds use CloudKit's **development** environment, so both devices must run Xcode-built debug builds (not TestFlight).
5. Set the Device label to `Mac` on the Mac and `iPhone` on the iPhone.

## Test script

For each test, note what each device shows and roughly how long it took.

| # | Test | Steps | What to record |
|---|---|---|---|
| T1 | Basic sync | On the Mac tap **New note**. Wait up to a minute | Does it appear on the iPhone? Seconds taken. Log lines on both |
| T2 | Offline conflict, append | Select the same note on both. Turn Wi-Fi off on the Mac and airplane mode on the iPhone. Mac: **Append stamp** twice. iPhone: **Append stamp** twice. Turn both back on and wait | The note body on each device afterward. Which stamps survived? Did either device keep all four? |
| T3 | Offline conflict, replace vs append | Same offline setup. Mac: **Replace body**. iPhone: **Append stamp**. Reconnect and wait | Final body on both devices |
| T4 | Large note | On the Mac tap **New 2 MB note** | Does it reach the iPhone? Is the character count the same on both (about 2,000,000)? Any `FAILED` in the log? |
| T5 | Duplicate tags | Turn off networking on both. Tap **Add tag "swift"** once on each. Reconnect and wait | Tag count and names shown at the top on each device |
| T6 | Relationship | On the Mac select a note, tap **Tag it**. Check the iPhone | Does the iPhone note show the tag link? (Look at the tag count and whether it still works after relaunch) |
| T7 | Delete vs edit (optional) | Offline both. Mac deletes a note. iPhone appends to the same note. Reconnect | Does the note return, vanish, or show up half-empty? |

Also note any `FAILED` log lines and their messages.

## Results

Reported by the user (2026-11-19):

| Test | Result | Still to confirm |
|---|---|---|
| Setup | iPhone shows `iCloud: available` | Mac status |
| T4 large note (created on the iPhone) | A 2 MB note created on the iPhone **appeared on the Mac** | Character count equal on both (about 2,000,000)? Time taken? Any `FAILED` line in either log? Content intact at the end of the note? |
| T1 basic sync | User reports "they sync" (2026-11-19), meaning notes sync between the two devices | Direction and timing not detailed. Treat as pass for basic sync |
| T2 offline conflict, append (first run) | All four stamps present on both devices. **Not trusted**: the lab then had no offline proof | Superseded by the verified run below |
| T2 offline conflict, append (verified run, lab with network monitor) | User confirms all four edit log lines said `OFFLINE`, and after reconnecting both devices showed all four stamps (2 Mac, 2 iPhone). **Concurrent offline appends to the same `body` were merged without loss** | **Single run, mechanism unexplained.** The docs lead one to expect last-writer-wins on a single field, so this is better than predicted. Repeat with other timings before relying on it: reverse reconnect order, three edits per side, and T3 (replace vs. append) |
| T3, T5, T6, T7 | Not run yet | |

**Provisional conclusion (2026-11-19):** keep one `body` field for v1 (Spec 01 decision 6 holds), but **do not design Spec 02 around an unexplained behavior.** Spec 02 still includes a conflicted-copy safeguard (low-cost insurance), and the repeat runs above must pass before the decision is final.

**Early reading:** a 2 MB `String` body syncs at least in one direction, which supports the Spec 01 assumption that Core Data mirroring moves oversized strings into assets automatically. Not confirmed until the counts match and the logs are clean.

## Decision rules

- **If T2 shows one device's edits silently lost** (expected under field-level last-writer-wins): decide between accepting it, adding a conflicted-copy safeguard (Spec 02), or splitting the body into blocks (changes Spec 01 decision 6, before release).
- **If T4 fails:** cap the body size or move the body to an asset-backed field.
- **If T5 shows duplicate tags** (expected): the dedupe service in Spec 01 is mandatory, not optional.
- **If sync takes minutes:** Spec 02 must show sync status and set user expectations.
