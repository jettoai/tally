import AppKit
import Foundation

// The Accounts table's column names must fit their columns in every shipped language (B-4474): the
// header is 28 high, so a name may take two lines of 11 points but may neither be cut off nor break
// inside a word. Measured with the real column widths (`AccountTableStyle`) and the real catalog.

var failed = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failed += 1 }
}

let t = AccountTableStyle.current
let skeleton = SettingsChrome.skeleton
let fixed = t.lead + t.nameColumn + t.plan + 2 * t.cell + t.share + 2 * t.toggle + t.actions + t.handle
let flexible = t.cardWidth - 2 * t.inset - fixed - 10 * t.gap
check("the card is the 700 content column", t.cardWidth == skeleton.contentWidth && t.cardWidth == 700)
check("the address column gets what the others leave (162)", flexible == 162)
check("the header and a row are the skeleton's 28 and 36",
      t.headerHeight == 28 && t.rowHeight == 36)

check("the sharing name's bleed leaves its neighbours 2 points", t.gap - t.shareBleed >= 2)
let columns: [(key: String, width: CGFloat)] = [
    ("Name", t.nameColumn), ("Account", flexible), ("Plan", t.plan), ("5 hours", t.cell),
    ("Week", t.cell), ("Sharing", t.share + 2 * t.shareBleed), ("Menu bar", t.toggle),
    ("Enabled", t.toggle),
]

let data = try! Data(contentsOf: URL(fileURLWithPath: "Tally/Resources/Localizable.xcstrings"))
let catalog = (try! JSONSerialization.jsonObject(with: data) as! [String: Any])["strings"] as! [String: Any]
func translation(_ key: String, _ language: String) -> String? {
    if language == "en" { return key }
    let entry = catalog[key] as? [String: Any]
    let localizations = entry?["localizations"] as? [String: Any]
    let unit = (localizations?[language] as? [String: Any])?["stringUnit"] as? [String: Any]
    return unit?["value"] as? String
}

let font = NSFont.systemFont(ofSize: 11)
func width(_ text: String) -> CGFloat {
    ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
}
/// Kana and ideographs break between any two characters; every other script breaks at spaces only.
func breaksAnywhere(_ text: String) -> Bool {
    text.unicodeScalars.allSatisfy { $0.value >= 0x2E80 && $0.value <= 0xA4CF || $0.value >= 0xFF00 }
}
let lineHeight = ceil(NSAttributedString(string: "Ag", attributes: [.font: font])
    .boundingRect(with: NSSize(width: 1000, height: 1000), options: [.usesLineFragmentOrigin]).height)
let twoLines = 2 * lineHeight
check("two lines of 11 points fit the 28 high header", twoLines <= t.headerHeight)

// What the measurement can tell: an invented string wider than any column must fail it.
check("the measure rejects a word wider than its column", width("Paylaşımlarımız") > t.share)

for language in ["en", "zh-Hant", "zh-Hans", "ja", "ko", "tr"] {
    for column in columns {
        guard let text = translation(column.key, language) else {
            check("\(language) has \(column.key)", false)
            continue
        }
        let words = text.split(separator: " ").map(String.init)
        let wholeWords = words.allSatisfy { breaksAnywhere($0) || width($0) <= column.width }
        let box = NSAttributedString(string: text, attributes: [.font: font]).boundingRect(
            with: NSSize(width: column.width, height: 10_000), options: [.usesLineFragmentOrigin])
        check("\(language) '\(text)' fits \(Int(column.width))pt in two lines without splitting a word",
              wholeWords && ceil(box.height) <= twoLines)
    }
}
exit(failed == 0 ? 0 : 1)
