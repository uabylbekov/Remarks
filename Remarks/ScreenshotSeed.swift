#if DEBUG
import Foundation
import SwiftData
import UniformTypeIdentifiers
import RemarksCore

/// Populates a warm, realistic blend of personal, student, and developer notes (including
/// embedded cover photos for list thumbnails) for App Store screenshots.
/// Compiled only in DEBUG builds and triggered explicitly via `-ScreenshotDemo` (in-memory)
/// or `-SeedSimulators` (simulator persistent store).
@MainActor
enum ScreenshotSeed {
    static func populate(_ context: ModelContext, replacingExisting: Bool = false) throws {
        if replacingExisting {
            for attachment in try context.fetch(FetchDescriptor<Attachment>()) { context.delete(attachment) }
            for note in try context.fetch(FetchDescriptor<Note>()) { context.delete(note) }
            for folder in try context.fetch(FetchDescriptor<Folder>()) { context.delete(folder) }
            for tag in try context.fetch(FetchDescriptor<Tag>()) { context.delete(tag) }
            try context.save()
        }

        let library = Library(context: context)
        let attachments = AttachmentStore(context: context)
        let now = Date.now
        func ago(days: Double = 0, hours: Double = 0) -> Date {
            now.addingTimeInterval(-(hours * 3600 + days * 86400))
        }

        // Folders
        let personal = try library.createFolder(named: "Personal", now: ago(days: 14))
        let travel = try library.createFolder(named: "Travel", in: personal, now: ago(days: 12))
        let recipes = try library.createFolder(named: "Recipes", in: personal, now: ago(days: 11))
        let study = try library.createFolder(named: "Study", now: ago(days: 10))
        let calculus = try library.createFolder(named: "Calculus & Physics", in: study, now: ago(days: 9))
        let cs201 = try library.createFolder(named: "CS 201", in: study, now: ago(days: 8))
        let work = try library.createFolder(named: "Work & Ideas", now: ago(days: 7))

        func add(
            body: String,
            folder: Folder?,
            tags: [String],
            pinned: Bool = false,
            coverImage: (data: Data, title: String)? = nil,
            date: Date
        ) throws {
            let note = library.createNote(body: "", in: folder, now: date)
            var finalBody = body
            if let coverImage, !coverImage.data.isEmpty {
                let attachment = try attachments.add(
                    data: coverImage.data,
                    fileName: "\(coverImage.title).jpg",
                    typeIdentifier: UTType.jpeg.identifier,
                    to: note,
                    now: date
                )
                let imageLine = AttachmentStore.markdown(for: attachment)
                finalBody = imageLine + "\n\n" + body
            }
            note.setBody(finalBody, now: date)
            if pinned { note.setPinned(true, now: date) }
            for name in tags {
                try library.addTag(named: name, to: note, now: date)
            }
        }

        // 1. Pinned — Warm Travel Note with Kyoto Autumn Cover Thumbnail
        try add(
            body: #"""
Four quiet days wandering cedar lanes, small neighborhood cafés, and temple gardens in November.

## Packing Checklist
- [x] Passport & ICOCA transit card
- [x] Comfortable walking shoes
- [x] Compact umbrella & light rain shell
- [ ] Portable battery pack & USB-C cable
- [ ] Small sketchbook + 0.5 mm pen

## Rough Itinerary

| Day | Morning | Evening |
| :--- | :--- | :--- |
| Thu | Arrive at Kyoto Station & check in | Walk around Pontocho Alley |
| Fri | Philosopher's Path & Nanzen-ji | Ramen near Higashiyama |
| Sat | Arashiyama bamboo grove at 7:00 AM | Sunset from Kiyomizu-dera |
| Sun | Nishiki Market & coffee beans | Shinkansen back to Tokyo |

> Start temple walks before 8:00 AM—the light through the maple trees is worth the early alarm.
"""#,
            folder: travel,
            tags: ["travel", "weekend"],
            pinned: true,
            coverImage: (ScreenshotSeedImages.kyotoAutumn, "Kyoto Autumn Trip"),
            date: ago(hours: 1)
        )

        // 2. Pinned — Student Calculus Note with Clean KaTeX Math
        try add(
            body: #"""
# Calculus II: Integration Notes

Review sheet for Friday's midterm. Remember to check whether simple substitution $u = g(x)$ works before trying parts.

## Integration by Parts

$$
\int u\, dv = uv - \int v\, du
$$

Choose $u$ using **LIATE**: Logarithms, Inverse trig, Algebraic, Trig, Exponentials.

## Fundamental Theorem of Calculus

If $F'(x) = f(x)$ on $[a, b]$, then:

$$
\int_a^b f(x)\, dx = F(b) - F(a)
$$

## Study Checklist
- [x] Review $u$-substitution practice problems (Section 5.5)
- [x] Re-derive integration by parts examples from lecture
- [ ] Finish Problem Set 6 (#12–18)
- [ ] Office hours with Prof. Chen — Thursday at 2:00 PM
"""#,
            folder: calculus,
            tags: ["study", "math"],
            pinned: true,
            date: ago(hours: 2)
        )

        // 3. Today — Warm Everyday Recipe with Coffee & Croissant Thumbnail
        try add(
            body: #"""
Slow Sunday morning ritual—bright washed Ethiopian beans, warm ceramic mug, and flaky almond croissants from the corner bakery.

## Brew Ratio

| Ingredient | Amount | Notes |
| :--- | :--- | :--- |
| Coffee | 20 g | Medium-fine grind |
| Water | 320 g | 93 °C (just off boil) |
| Ratio | 1 : 16 | Total brew ~3:00 |

## Steps
1. Rinse the paper filter with hot water to warm the carafe.
2. Pour **50 g** of water to bloom for 45 seconds and swirl gently.
3. Pour slowly in concentric circles to **200 g** by 1:30.
4. Top up to **320 g** by 2:15 and enjoy while warm.

> Favorite local roaster this month: *Heart Roasters — Stereo Blend* (tastes like peach and milk chocolate).
"""#,
            folder: recipes,
            tags: ["recipes", "weekend"],
            coverImage: (ScreenshotSeedImages.morningCoffee, "Sunday Coffee & Croissants"),
            date: ago(hours: 3.5)
        )

        // 4. Today — Simple Humane Daily Note
        try add(
            body: #"""
# Weekly Errands & Notes

Keep this week light and focused—one big thing each morning before checking email.

## To-Do
- [x] Pick up sourdough, avocados, lemons, and oat milk
- [x] Call Mom about Thanksgiving flight times
- [ ] Return library books before Thursday
- [ ] Book dentist appointment for next month
- [ ] Drop off winter coat at the dry cleaner

## Small Wins
- Finished the whole 5k loop around the lake without checking my phone
- Cooked dinner at home four nights in a row
"""#,
            folder: personal,
            tags: ["weekend"],
            date: ago(hours: 5)
        )

        // 5. Today — Clean Builder / CS Note (Mermaid + Swift)
        try add(
            body: #"""
# App Sync & Offline Flow

Keep writing fast even on an airplane—every edit saves locally first and syncs quietly through iCloud once back online.

```mermaid
flowchart LR
    Write[Markdown Editor] --> Local[(Local Store)]
    Local --> Cloud((Private iCloud))
    Cloud --> All[iPhone, iPad & Mac]
```

## Saving Edits Safely

```swift
func saveNote(_ note: Note, body: String) throws {
    note.setBody(body, now: .now)
    try context.save()
}
```

- Works with zero account setup
- Keeps local drafts intact while offline
- Export anytime as plain `.md` files
"""#,
            folder: work,
            tags: ["swift"],
            date: ago(hours: 6.5)
        )

        // 6. Yesterday — Outdoor Day Hike with Alpine Lake Thumbnail
        try add(
            body: #"""
Crisp sunrise hike up to the alpine basin—glassy turquoise water and almost nobody on the trail before 9 AM.

## Trail Quick Facts

| Detail | Info |
| :--- | :--- |
| Distance | 7.4 miles round trip |
| Elevation Gain | 1,780 ft |
| Best Window | Arrive at trailhead by 6:30 AM |

## Daypack Essentials
- [x] 2L water + electrolytes
- [x] Warm fleece layer for the summit breeze
- [x] Trail mix, apples & peanut butter wraps
- [ ] Download offline trail map before leaving town

Stop at the bakery in Marblemount on the drive home for warm cinnamon rolls.
"""#,
            folder: travel,
            tags: ["travel", "weekend"],
            coverImage: (ScreenshotSeedImages.alpineTrail, "Cascade Pass Day Hike"),
            date: ago(days: 1, hours: 2)
        )

        // 7. Yesterday — Student CS 201 Study Sheet (Python + Math + Table)
        try add(
            body: #"""
# CS 201: Binary Search & Big-O

Binary search halves the search range every step, giving $\mathcal{O}(\log n)$ worst-case time on a sorted array.

```python
def binary_search(items, target):
    low, high = 0, len(items) - 1
    while low <= high:
        mid = (low + high) // 2
        if items[mid] == target:
            return mid
        if items[mid] < target:
            low = mid + 1
        else:
            high = mid - 1
    return -1
```

## Common Runtimes to Memorize

| Algorithm | Time | Space |
| :--- | :--- | :--- |
| Binary Search | $\mathcal{O}(\log n)$ | $\mathcal{O}(1)$ |
| Merge Sort | $\mathcal{O}(n \log n)$ | $\mathcal{O}(n)$ |
| Hash Table Lookup | $\mathcal{O}(1)$ avg | $\mathcal{O}(n)$ |
"""#,
            folder: cs201,
            tags: ["study", "math"],
            date: ago(days: 1, hours: 6)
        )

        // 8. 3 Days Ago — Reading & Film Log with Sunlit Desk Thumbnail
        try add(
            body: #"""
Quiet reads and cozy films for rainy autumn evenings with a mug of jasmine tea.

## Books
- [x] *Piranesi* — Susanna Clarke
- [x] *The Elements of Typographic Style* — Robert Bringhurst
- [ ] *Tomorrow, and Tomorrow, and Tomorrow* — Gabrielle Zevin
- [ ] *Braiding Sweetgrass* — Robin Wall Kimmerer

## Films to Rewatch
- *Whisper of the Heart* (Studio Ghibli)
- *Lost in Translation*
- *Perfect Days* — Wim Wenders

> "The beauty of the House is immeasurable; its Kindness infinite."
"""#,
            folder: study,
            tags: ["books"],
            coverImage: (ScreenshotSeedImages.studyDesk, "Autumn Reading & Film Log"),
            date: ago(days: 3)
        )

        // 9. 5 Days Ago — Simple Weeknight Recipe
        try add(
            body: #"""
# Weeknight Lemon Garlic Pasta

Ready in 15 minutes with pantry staples—bright, silky, and even better with toasted breadcrumbs.

## Ingredients
- [ ] 250 g spaghetti or linguine
- [ ] 3 cloves garlic, thinly sliced
- [ ] Zest & juice of 1 fresh lemon
- [ ] 3 tbsp olive oil + knob of butter
- [ ] Handful of grated parmesan & fresh parsley

## Steps
1. Boil pasta in well-salted water until *al dente*; save a cup of pasta water.
2. Warm olive oil over low heat and gently toast the garlic for 1 minute.
3. Toss in pasta, butter, lemon zest, lemon juice, and splashes of pasta water until glossy.
4. Finish with parmesan, cracked black pepper, and chopped parsley.
"""#,
            folder: recipes,
            tags: ["recipes"],
            date: ago(days: 5)
        )

        try context.save()
    }
}
#endif
