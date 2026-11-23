# Remarks — App Store Connect Metadata (Wave 1)

Positioning: **Remarks: Notes, Upgraded** — familiar simplicity of Apple Notes, built for Markdown, code, math, and diagrams. Paid once, no subscriptions, private iCloud sync.

## Quick Reference (Character-Limit Checked)

Limits: **Name ≤ 30**, **Subtitle ≤ 30**, **Promotional Text ≤ 170**, **Keywords ≤ 100** (comma-separated, no spaces after commas).

| Locale | File | App Name | Subtitle |
| :--- | :--- | :--- | :--- |
| English (`en-US`) | [en-US.md](en-US.md) | `Remarks: Notes, Upgraded` | `Markdown, Code, Math & iCloud` |
| Japanese (`ja`) | [ja.md](ja.md) | `Remarks - 進化したメモ` | `Markdown・コード・数式・iCloud` |
| German (`de-DE`) | [de-DE.md](de-DE.md) | `Remarks: Mehr als Notizen` | `Markdown, Code, Mathe & iCloud` |
| Simplified Chinese (`zh-Hans`) | [zh-Hans.md](zh-Hans.md) | `Remarks - 进阶笔记` | `Markdown、代码、公式与 iCloud` |
| Traditional Chinese (`zh-Hant`) | [zh-Hant.md](zh-Hant.md) | `Remarks - 進階筆記` | `Markdown、程式碼、公式與 iCloud` |
| Korean (`ko`) | [ko.md](ko.md) | `Remarks - 더 강력한 노트` | `Markdown, 코드, 수식 및 iCloud` |
| French (`fr-FR`) | [fr-FR.md](fr-FR.md) | `Remarks : Notes avancées` | `Markdown, code, maths, iCloud` |

## App Store Connect Setup Notes

* **Monetization:** Paid-up-front Universal Purchase (iPhone, iPad, and Mac under one price).
* **Regional Pricing Tip:** Keep the base USD equivalent in US, EU, JP, KR, and TW; consider setting China mainland (`zh-Hans`) ~30–40% lower to improve upfront conversion.
* **App Privacy Questionnaire:** Select **Data Not Collected** (notes stay on-device and in the user’s private iCloud database; no third-party SDKs, analytics, or tracking).
* **Privacy Manifests:** Both `Remarks/PrivacyInfo.xcprivacy` and `RemarksCore/PrivacyInfo.xcprivacy` declare `NSPrivacyAccessedAPICategoryUserDefaults` (`CA92.1`).
