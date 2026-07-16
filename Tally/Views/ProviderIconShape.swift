import SwiftUI
import AppKit

/// Minimal SVG `<path d>` parser → `SwiftUI.Path`. Supports M/L/H/V/C/S/Q/T/Z (absolute + relative,
/// implicit command repetition). Arcs (A/a) are unsupported — our bundled marks don't use them (a
/// build-time check confirms). SwiftUI's `Path` is y-down like SVG, so no coordinate flip is needed.
/// Technique adapted from robinebers/openusage.
enum SVGPath {
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Path] = [:]

    /// Parse (memoized) — the same mark is rendered on every popover open and menu-bar refresh, so
    /// parsing its ~160-element path once instead of per-render matters, especially in debug builds.
    static func parse(_ d: String) -> Path {
        cacheLock.lock()
        if let cached = cache[d] { cacheLock.unlock(); return cached }
        cacheLock.unlock()
        let path = build(d)
        cacheLock.lock(); cache[d] = path; cacheLock.unlock()
        return path
    }

    private static func build(_ d: String) -> Path {
        var path = Path()
        let chars = Array(d)
        let n = chars.count
        var i = 0

        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastControl: CGPoint?
        var lastCommand: Character = " "
        var prevWasCubic = false
        var prevWasQuad = false

        func skipSeparators() {
            while i < n {
                let c = chars[i]
                if c == " " || c == "," || c == "\n" || c == "\t" || c == "\r" { i += 1 } else { break }
            }
        }

        func readNumber() -> CGFloat? {
            skipSeparators()
            var s = ""
            if i < n, chars[i] == "+" || chars[i] == "-" { s.append(chars[i]); i += 1 }
            var sawDot = false
            while i < n {
                let c = chars[i]
                if c.isNumber {
                    s.append(c); i += 1
                } else if c == "." && !sawDot {
                    sawDot = true; s.append(c); i += 1
                } else if c == "e" || c == "E" {
                    s.append(c); i += 1
                    if i < n, chars[i] == "+" || chars[i] == "-" { s.append(chars[i]); i += 1 }
                } else {
                    break
                }
            }
            guard let value = Double(s) else { return nil }
            return CGFloat(value)
        }

        func readPoint(relative: Bool) -> CGPoint? {
            guard let x = readNumber(), let y = readNumber() else { return nil }
            return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }

        func reflected() -> CGPoint {
            guard let lc = lastControl else { return current }
            return CGPoint(x: 2 * current.x - lc.x, y: 2 * current.y - lc.y)
        }

        while i < n {
            skipSeparators()
            if i >= n { break }

            if chars[i].isLetter {
                lastCommand = chars[i]
                i += 1
            }

            let cmd = lastCommand
            var failed = false
            var isCubic = false
            var isQuad = false

            switch cmd {
            case "M", "m":
                if let p = readPoint(relative: cmd == "m") {
                    path.move(to: p)
                    current = p
                    subpathStart = p
                    lastCommand = (cmd == "m") ? "l" : "L"   // implicit subsequent pairs are lineto
                } else { failed = true }

            case "L", "l":
                if let p = readPoint(relative: cmd == "l") {
                    path.addLine(to: p); current = p
                } else { failed = true }

            case "H", "h":
                if let x = readNumber() {
                    let nx = (cmd == "h") ? current.x + x : x
                    let p = CGPoint(x: nx, y: current.y)
                    path.addLine(to: p); current = p
                } else { failed = true }

            case "V", "v":
                if let y = readNumber() {
                    let ny = (cmd == "v") ? current.y + y : y
                    let p = CGPoint(x: current.x, y: ny)
                    path.addLine(to: p); current = p
                } else { failed = true }

            case "C", "c":
                if let c1 = readPoint(relative: cmd == "c"),
                   let c2 = readPoint(relative: cmd == "c"),
                   let end = readPoint(relative: cmd == "c") {
                    path.addCurve(to: end, control1: c1, control2: c2)
                    current = end; lastControl = c2; isCubic = true
                } else { failed = true }

            case "S", "s":
                if let c2 = readPoint(relative: cmd == "s"),
                   let end = readPoint(relative: cmd == "s") {
                    let c1 = prevWasCubic ? reflected() : current
                    path.addCurve(to: end, control1: c1, control2: c2)
                    current = end; lastControl = c2; isCubic = true
                } else { failed = true }

            case "Q", "q":
                if let c = readPoint(relative: cmd == "q"),
                   let end = readPoint(relative: cmd == "q") {
                    path.addQuadCurve(to: end, control: c)
                    current = end; lastControl = c; isQuad = true
                } else { failed = true }

            case "T", "t":
                if let end = readPoint(relative: cmd == "t") {
                    let c = prevWasQuad ? reflected() : current
                    path.addQuadCurve(to: end, control: c)
                    current = end; lastControl = c; isQuad = true
                } else { failed = true }

            case "Z", "z":
                path.closeSubpath()
                current = subpathStart

            default:
                failed = true
            }

            if failed { break }
            prevWasCubic = isCubic
            prevWasQuad = isQuad
        }

        return path
    }
}

/// A brand mark as a `Shape`, normalized against the parsed path's actual bounding box (the SVG
/// viewBox is ignored — some marks bake in uneven margins) then aspect-fit and centered into `rect`,
/// with a uniform `inset` for breathing room.
struct ProviderIconShape: Shape {
    let pathData: String
    var inset: CGFloat = 0.10

    func path(in rect: CGRect) -> Path {
        let raw = SVGPath.parse(pathData)
        let bounds = raw.cgPath.boundingBoxOfPath
        guard bounds.width > 0, bounds.height > 0 else { return raw }
        let target = rect.insetBy(dx: rect.width * inset, dy: rect.height * inset)
        let scale = min(target.width / bounds.width, target.height / bounds.height)
        let dx = target.midX - bounds.midX * scale
        let dy = target.midY - bounds.midY * scale
        return raw
            .applying(CGAffineTransform(scaleX: scale, y: scale))
            .applying(CGAffineTransform(translationX: dx, y: dy))
    }
}

/// A provider's brand mark for SwiftUI, falling back to the SF Symbol when no mark is registered.
/// The mark is rasterized to a template image once and cached — filling its ~160-element path live on
/// every card render / layout pass was a real cost on popover open.
struct ProviderIconView: View {
    let providerID: String
    var size: CGFloat = 15

    var body: some View {
        if let image = Self.templateImage(for: providerID) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        } else {
            Image(systemName: ProviderCatalog.iconName(for: providerID))
                .font(.system(size: size * 0.9))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }

    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor
    private static func templateImage(for providerID: String) -> NSImage? {
        if let cached = cache[providerID] { return cached }
        guard let mark = ProviderMarks.path(for: providerID) else { return nil }
        let renderer = ImageRenderer(
            content: ProviderIconShape(pathData: mark, inset: 0.08)
                .fill(Color.black)
                .frame(width: 48, height: 48))
        renderer.scale = 3
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        cache[providerID] = image
        return image
    }
}
