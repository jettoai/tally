import AppKit
import ApplicationServices
import Foundation

// Read or press one identified control in a running fixture app without synthesizing input.
guard CommandLine.arguments.count >= 2, let pid = Int32(CommandLine.arguments[1]) else { exit(2) }
guard AXIsProcessTrusted() else {
    print("{\"error\":\"Accessibility access is unavailable.\"}")
    exit(2)
}
let before = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
let app = AXUIElementCreateApplication(pid)
func attribute(_ element: AXUIElement, _ key: String) -> Any? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
    return value
}
var rows: [[String: Any]] = [], matches: [AXUIElement] = []
let target = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
func visit(_ element: AXUIElement, depth: Int) {
    guard depth < 35, rows.count < 2000 else { return }
    var row: [String: Any] = ["depth": depth]
    for key in ["AXRole", "AXTitle", "AXDescription", "AXIdentifier", "AXValue", "AXEnabled"] {
        if let value = attribute(element, key), value is String || value is NSNumber { row[key] = value }
    }
    rows.append(row)
    if let target {
        if target.hasPrefix("description:"), row["AXDescription"] as? String == String(target.dropFirst(12)),
           ["AXButton", "AXRadioButton"].contains(row["AXRole"] as? String ?? "") {
            matches.append(element)
        } else if row["AXIdentifier"] as? String == target { matches.append(element) }
    }
    for child in attribute(element, "AXChildren") as? [AXUIElement] ?? [] { visit(child, depth: depth + 1) }
}
for window in attribute(app, "AXWindows") as? [AXUIElement] ?? []
    where ["Settings", "設定"].contains(attribute(window, "AXTitle") as? String ?? "") {
    visit(window, depth: 0)
}
var result: [String: Any] = ["pid": pid, "frontmostBefore": before, "elements": rows]
if target != nil {
    guard matches.count == 1 else {
        print("{\"error\":\"Expected exactly one identified control.\",\"matches\":\(matches.count)}")
        exit(2)
    }
    result["actionStatus"] = AXUIElementPerformAction(matches[0], kAXPressAction as CFString).rawValue
}
let windows = CGWindowListCopyWindowInfo(.excludeDesktopElements, kCGNullWindowID) as? [[String: Any]] ?? []
result["windows"] = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }.map { row in
    row.filter { [kCGWindowNumber as String, kCGWindowBounds as String, kCGWindowName as String,
                  kCGWindowIsOnscreen as String, kCGWindowLayer as String].contains($0.key) }
}
result["frontmostAfter"] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([10]))
