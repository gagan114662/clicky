import AppKit
import Foundation

enum FreeformDiagramKind: String, Equatable {
    case multiplicationArray
    case fractionBar
    case derivativeSlope
    case conceptMap
}

struct FreeformDiagramSpec: Equatable {
    let kind: FreeformDiagramKind
    let title: String

    var promptContext: String {
        switch kind {
        case .multiplicationArray:
            return """
            Prepared Freeform diagram: "\(title)".
            Exact contents:
            - Left example card: 3 rows and 4 columns, total 12 dots, labeled "Example: 3 x 4" and "3 x 4 = 12 dots".
            - Right practice card: 5 rows and 6 columns, total 30 dots, labeled "Your turn" and "What fact? How many total?"
            Teaching constraint: use these exact numbers. Do not infer different row/column counts from the screenshot.
            """
        case .fractionBar:
            return """
            Prepared Freeform diagram: "\(title)".
            Exact contents: one whole bar compared with a three-of-four fraction bar, emphasizing equal parts.
            Teaching constraint: refer to the bars as equal-size parts and avoid changing the fraction shown.
            """
        case .derivativeSlope:
            return """
            Prepared Freeform diagram: "\(title)".
            Exact contents: a curved graph with a highlighted tangent line and nearby points, emphasizing derivative as local slope.
            Teaching constraint: explain the derivative as the slope the curve is trying to have at one instant.
            """
        case .conceptMap:
            return """
            Prepared Freeform diagram: "\(title)".
            Exact contents: a simple concept map with connected ideas and a practice/check area.
            Teaching constraint: use the map as a spatial anchor instead of narrating generic notes.
            """
        }
    }
}

enum LearningAction: Equatable {
    case none
    case scrollDown
    case scrollUp
    case pausePlay
    case nextPage
    case previousPage
    case zoomIn
    case zoomOut
    case openURL(String)
    case openNativeApp(String)
    case openScratchpad
    case writeScratchpad(String)
    case writeFreeformText(String)
    case prepareFreeformBoard(String)
    case prepareFreeformDiagram(FreeformDiagramSpec)

    var logLabel: String {
        switch self {
        case .none: return "none"
        case .scrollDown: return "scroll_down"
        case .scrollUp: return "scroll_up"
        case .pausePlay: return "pause_play"
        case .nextPage: return "next_page"
        case .previousPage: return "previous_page"
        case .zoomIn: return "zoom_in"
        case .zoomOut: return "zoom_out"
        case .openURL(let url): return "open_url:\(url)"
        case .openNativeApp(let appName): return "open_native_app:\(appName)"
        case .openScratchpad: return "open_scratchpad"
        case .writeScratchpad: return "write_scratchpad"
        case .writeFreeformText: return "write_freeform_text"
        case .prepareFreeformBoard: return "prepare_freeform_board"
        case .prepareFreeformDiagram(let spec): return "prepare_freeform_diagram:\(spec.kind.rawValue)"
        }
    }
}

enum LearningURLSanitizer {
    static func firstOpenableURLString(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>"']+"#) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: nsRange) {
            guard let range = Range(match.range, in: text) else { continue }
            let candidate = String(text[range])
            if let sanitizedURL = openableURLString(from: candidate) {
                return sanitizedURL
            }
        }
        return nil
    }

    static func openableURLString(from rawString: String) -> String? {
        let trimmed = rawString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>()[]{}\"'.,;:!?"))
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(),
              host.contains("."),
              isPlausibleHost(host),
              !host.contains("xn--") else {
            return nil
        }

        components.scheme = scheme
        components.host = host

        if isYouTubeHost(host) {
            return canonicalYouTubeURLString(from: components)
        }

        return components.url?.absoluteString
    }

    private static func canonicalYouTubeURLString(from components: URLComponents) -> String? {
        guard let host = components.host?.lowercased() else { return nil }
        let path = components.path

        if host == "youtu.be" || host.hasSuffix(".youtu.be") {
            guard let videoID = path
                .split(separator: "/")
                .first
                .map(String.init)
                .flatMap(plausibleYouTubeVideoID) else {
                return nil
            }
            return watchURLString(videoID: videoID, queryItems: components.queryItems)
        }

        if path == "/watch" || path.isEmpty || path == "/" {
            if path == "/watch" {
                guard let videoID = components.queryItems?
                    .first(where: { $0.name.lowercased() == "v" })?
                    .value
                    .flatMap(plausibleYouTubeVideoID) else {
                    return nil
                }
                return watchURLString(videoID: videoID, queryItems: components.queryItems)
            }
            return "https://www.youtube.com/"
        }

        if path == "/results" {
            guard components.queryItems?
                .contains(where: { $0.name.lowercased() == "search_query" && ($0.value?.isEmpty == false) }) == true else {
                return nil
            }
            var sanitized = URLComponents()
            sanitized.scheme = "https"
            sanitized.host = "www.youtube.com"
            sanitized.path = "/results"
            sanitized.queryItems = components.queryItems
            return sanitized.url?.absoluteString
        }

        let videoPathPrefixes = ["/shorts/", "/embed/", "/live/"]
        for prefix in videoPathPrefixes where path.hasPrefix(prefix) {
            let rawID = String(path.dropFirst(prefix.count))
                .split(separator: "/")
                .first
                .map(String.init)
            guard let videoID = rawID.flatMap(plausibleYouTubeVideoID) else { return nil }
            return watchURLString(videoID: videoID, queryItems: components.queryItems)
        }

        return nil
    }

    private static func isPlausibleHost(_ host: String) -> Bool {
        guard host.unicodeScalars.allSatisfy({ scalar in
            switch scalar.value {
            case 45, 46, 48...57, 65...90, 97...122:
                return true
            default:
                return false
            }
        }) else {
            return false
        }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy({ label in
                  !label.isEmpty && label.first != "-" && label.last != "-"
              }),
              let topLevelDomain = labels.last,
              topLevelDomain.count >= 2,
              topLevelDomain.allSatisfy({ $0.isLetter }) else {
            return false
        }

        return true
    }

    private static func watchURLString(videoID: String, queryItems: [URLQueryItem]?) -> String? {
        var sanitized = URLComponents()
        sanitized.scheme = "https"
        sanitized.host = "www.youtube.com"
        sanitized.path = "/watch"
        var items = [URLQueryItem(name: "v", value: videoID)]
        for item in queryItems ?? [] {
            let name = item.name.lowercased()
            if ["t", "start", "list"].contains(name), item.value?.isEmpty == false {
                items.append(item)
            }
        }
        sanitized.queryItems = items
        return sanitized.url?.absoluteString
    }

    private static func plausibleYouTubeVideoID(_ rawID: String) -> String? {
        let id = rawID.trimmingCharacters(in: CharacterSet(charactersIn: "<>()[]{}\"'.,;:!?"))
        guard (6...64).contains(id.count),
              id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            return nil
        }
        return id
    }

    private static func isYouTubeHost(_ host: String) -> Bool {
        host == "youtube.com"
            || host.hasSuffix(".youtube.com")
            || host == "youtu.be"
            || host.hasSuffix(".youtu.be")
    }
}

enum LearningActionTagParser {
    struct ParseResult: Equatable {
        let spokenText: String
        let action: LearningAction?
    }

    static func parse(from responseText: String) -> ParseResult {
        let pattern = #"\[LEARN_ACTION:([^\]]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(
                in: responseText,
                range: NSRange(responseText.startIndex..., in: responseText)
              ).last,
              let fullRange = Range(match.range, in: responseText),
              let actionRange = Range(match.range(at: 1), in: responseText) else {
            return ParseResult(spokenText: responseText, action: nil)
        }

        let rawAction = String(responseText[actionRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var spokenText = responseText
        spokenText.removeSubrange(fullRange)
        spokenText = spokenText
            .replacingOccurrences(
                of: #"[ \t]*\n[ \t]*\n[ \t]*\n+"#,
                with: "\n\n",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ParseResult(spokenText: spokenText, action: action(from: rawAction))
    }

    private static func action(from rawAction: String) -> LearningAction {
        let normalized = rawAction
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")

        if normalized.hasPrefix("open_url:") {
            let urlString = String(rawAction.dropFirst("open_url:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .openURL(LearningURLSanitizer.openableURLString(from: urlString) ?? urlString)
        }
        if normalized.hasPrefix("open_native_app:") {
            let appName = String(rawAction.dropFirst("open_native_app:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .openNativeApp(appName)
        }
        if normalized.hasPrefix("scratchpad:") {
            let scratchpadText = String(rawAction.dropFirst("scratchpad:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .writeScratchpad(scratchpadText)
        }
        if normalized.hasPrefix("write_scratchpad:") {
            let scratchpadText = String(rawAction.dropFirst("write_scratchpad:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .writeScratchpad(scratchpadText)
        }
        if normalized.hasPrefix("freeform_text:") {
            let freeformText = String(rawAction.dropFirst("freeform_text:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .writeFreeformText(freeformText)
        }
        if normalized.hasPrefix("write_freeform_text:") {
            let freeformText = String(rawAction.dropFirst("write_freeform_text:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .writeFreeformText(freeformText)
        }
        if normalized.hasPrefix("freeform_board:") {
            let freeformText = String(rawAction.dropFirst("freeform_board:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .prepareFreeformBoard(freeformText)
        }
        if normalized.hasPrefix("prepare_freeform_board:") {
            let freeformText = String(rawAction.dropFirst("prepare_freeform_board:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .prepareFreeformBoard(freeformText)
        }
        if normalized.hasPrefix("freeform_diagram:") {
            let diagramText = String(rawAction.dropFirst("freeform_diagram:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .prepareFreeformDiagram(diagramSpec(from: diagramText))
        }
        if normalized.hasPrefix("prepare_freeform_diagram:") {
            let diagramText = String(rawAction.dropFirst("prepare_freeform_diagram:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .prepareFreeformDiagram(diagramSpec(from: diagramText))
        }

        switch normalized {
        case "none": return .none
        case "scroll_down": return .scrollDown
        case "scroll_up": return .scrollUp
        case "pause_play", "play_pause", "pause", "play": return .pausePlay
        case "next_page", "next", "advance": return .nextPage
        case "previous_page", "previous", "back": return .previousPage
        case "zoom_in": return .zoomIn
        case "zoom_out": return .zoomOut
        case "open_scratchpad", "scratchpad", "show_scratchpad": return .openScratchpad
        default: return .none
        }
    }

    private static func diagramSpec(from rawDiagramText: String) -> FreeformDiagramSpec {
        let pieces = rawDiagramText
            .split(separator: ":", maxSplits: 1)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let rawKind = pieces.first?.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_") ?? ""
        let title = pieces.count > 1 && !pieces[1].isEmpty ? pieces[1] : "Lesson diagram"

        switch rawKind {
        case "multiplication", "multiplication_array", "array":
            return FreeformDiagramSpec(kind: .multiplicationArray, title: title)
        case "fraction", "fractions", "fraction_bar":
            return FreeformDiagramSpec(kind: .fractionBar, title: title)
        case "derivative", "derivatives", "slope", "calculus":
            return FreeformDiagramSpec(kind: .derivativeSlope, title: title)
        default:
            return FreeformDiagramSpec(kind: .conceptMap, title: title)
        }
    }
}

enum FreeformDiagramRenderer {
    static func render(_ spec: FreeformDiagramSpec) -> NSImage {
        let size = NSSize(width: 2_200, height: 1_400)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        drawBackground(size: size)
        drawHeader(title: spec.title, subtitle: subtitle(for: spec.kind), size: size)

        switch spec.kind {
        case .multiplicationArray:
            drawMultiplicationArray()
        case .fractionBar:
            drawFractionBar()
        case .derivativeSlope:
            drawDerivativeSlope()
        case .conceptMap:
            drawConceptMap(title: spec.title)
        }

        return image
    }

    private static func subtitle(for kind: FreeformDiagramKind) -> String {
        switch kind {
        case .multiplicationArray:
            return "Rows, columns, and total dots"
        case .fractionBar:
            return "Equal parts make the denominator visible"
        case .derivativeSlope:
            return "Slope becomes a local rate of change"
        case .conceptMap:
            return "Parts, relationships, and a next move"
        }
    }

    private static func drawBackground(size: NSSize) {
        NSColor(calibratedRed: 0.98, green: 0.97, blue: 0.94, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        let border = NSBezierPath(roundedRect: NSRect(x: 28, y: 28, width: size.width - 56, height: size.height - 56), xRadius: 28, yRadius: 28)
        NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.16, alpha: 0.08).setStroke()
        border.lineWidth = 3
        border.stroke()
    }

    private static func drawHeader(title: String, subtitle: String, size: NSSize) {
        drawText(
            title,
            in: NSRect(x: 110, y: size.height - 160, width: size.width - 220, height: 82),
            fontSize: 64,
            weight: .bold,
            color: NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.16, alpha: 1)
        )
        drawText(
            subtitle,
            in: NSRect(x: 114, y: size.height - 222, width: size.width - 228, height: 52),
            fontSize: 34,
            weight: .medium,
            color: NSColor(calibratedRed: 0.36, green: 0.39, blue: 0.45, alpha: 1)
        )
    }

    private static func drawMultiplicationArray() {
        drawCard(NSRect(x: 90, y: 120, width: 960, height: 1_020), title: "Example: 3 x 4")
        drawDotArray(origin: CGPoint(x: 285, y: 505), rows: 3, columns: 4, dotSize: 86, spacing: 180, color: blue)
        drawText("3 rows", in: NSRect(x: 120, y: 645, width: 150, height: 55), fontSize: 36, weight: .bold, color: ink, alignment: .right)
        drawArrow(from: CGPoint(x: 285, y: 685), to: CGPoint(x: 825, y: 685), color: blue)
        drawText("4 in each row", in: NSRect(x: 300, y: 315, width: 510, height: 58), fontSize: 38, weight: .bold, color: ink, alignment: .center)
        drawText("3 x 4 = 12 dots", in: NSRect(x: 200, y: 210, width: 740, height: 76), fontSize: 56, weight: .bold, color: orange, alignment: .center)

        drawCard(NSRect(x: 1_150, y: 120, width: 960, height: 1_020), title: "Your turn")
        drawDotArray(origin: CGPoint(x: 1_300, y: 390), rows: 5, columns: 6, dotSize: 62, spacing: 118, color: green)
        drawText("5 rows", in: NSRect(x: 1_174, y: 615, width: 120, height: 55), fontSize: 34, weight: .bold, color: ink, alignment: .right)
        drawArrow(from: CGPoint(x: 1_300, y: 625), to: CGPoint(x: 1_890, y: 625), color: green)
        drawText("6 in each row", in: NSRect(x: 1_340, y: 255, width: 600, height: 56), fontSize: 36, weight: .bold, color: ink, alignment: .center)
        drawText("What fact? How many total?", in: NSRect(x: 1_250, y: 175, width: 760, height: 62), fontSize: 42, weight: .bold, color: purple, alignment: .center)
    }

    private static func drawFractionBar() {
        drawCard(NSRect(x: 90, y: 120, width: 2_020, height: 1_020), title: "3/4 means three of four equal parts")
        let barFrame = NSRect(x: 250, y: 595, width: 1_700, height: 190)
        for index in 0..<4 {
            let segment = NSRect(x: barFrame.minX + CGFloat(index) * barFrame.width / 4, y: barFrame.minY, width: barFrame.width / 4, height: barFrame.height)
            (index < 3 ? green : NSColor.white).setFill()
            NSBezierPath(rect: segment).fill()
            NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.18, alpha: 1).setStroke()
            let path = NSBezierPath(rect: segment)
            path.lineWidth = 7
            path.stroke()
        }
        drawText("selected parts", in: NSRect(x: 350, y: 410, width: 650, height: 70), fontSize: 50, weight: .bold, color: green, alignment: .center)
        drawArrow(from: CGPoint(x: 675, y: 505), to: CGPoint(x: 675, y: 585), color: green)
        drawText("all four parts are equal", in: NSRect(x: 1_050, y: 410, width: 700, height: 70), fontSize: 50, weight: .bold, color: blue, alignment: .center)
        drawArrow(from: CGPoint(x: 1_395, y: 505), to: CGPoint(x: 1_395, y: 585), color: blue)
        drawText("Your turn: what would 2/5 look like?", in: NSRect(x: 260, y: 205, width: 1_680, height: 86), fontSize: 62, weight: .bold, color: purple, alignment: .center)
    }

    private static func drawDerivativeSlope() {
        drawCard(NSRect(x: 90, y: 120, width: 2_020, height: 1_020), title: "Derivative = slope right here")
        drawAxis(origin: CGPoint(x: 320, y: 310), width: 1_540, height: 530)

        let curve = NSBezierPath()
        curve.move(to: CGPoint(x: 360, y: 350))
        curve.curve(to: CGPoint(x: 1_760, y: 830), controlPoint1: CGPoint(x: 720, y: 300), controlPoint2: CGPoint(x: 1_240, y: 960))
        blue.setStroke()
        curve.lineWidth = 14
        curve.stroke()

        drawLine(from: CGPoint(x: 880, y: 455), to: CGPoint(x: 1_530, y: 775), color: orange, width: 13)
        drawDot(center: CGPoint(x: 1_125, y: 575), size: 54, color: orange)
        drawText("tangent slope", in: NSRect(x: 1_280, y: 820, width: 430, height: 70), fontSize: 52, weight: .bold, color: orange)
        drawArrow(from: CGPoint(x: 1_310, y: 810), to: CGPoint(x: 1_165, y: 620), color: orange)
        drawText("If this line gets steeper, what happens to the derivative?", in: NSRect(x: 250, y: 205, width: 1_700, height: 82), fontSize: 58, weight: .bold, color: purple, alignment: .center)
    }

    private static func drawConceptMap(title: String) {
        drawCard(NSRect(x: 90, y: 120, width: 2_020, height: 1_020), title: title)
        let center = CGPoint(x: 1_100, y: 650)
        let nodes = [
            ("Parts", CGPoint(x: 540, y: 790), blue),
            ("Relationship", CGPoint(x: 1_100, y: 360), green),
            ("Change", CGPoint(x: 1_660, y: 790), orange)
        ]
        for (_, point, color) in nodes {
            drawLine(from: center, to: point, color: color, width: 10)
        }
        drawPill("Core idea", center: center, width: 420, color: purple)
        for (text, point, color) in nodes {
            drawPill(text, center: point, width: 420, color: color)
        }
        drawText("Say what connects the three nodes.", in: NSRect(x: 280, y: 205, width: 1_640, height: 78), fontSize: 56, weight: .bold, color: ink, alignment: .center)
    }

    private static func drawCard(_ rect: NSRect, title: String) {
        NSColor.white.setFill()
        let card = NSBezierPath(roundedRect: rect, xRadius: 24, yRadius: 24)
        card.fill()
        NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.18, alpha: 0.12).setStroke()
        card.lineWidth = 4
        card.stroke()
        drawText(title, in: NSRect(x: rect.minX + 44, y: rect.maxY - 112, width: rect.width - 88, height: 76), fontSize: 54, weight: .bold, color: ink)
    }

    private static func drawDotArray(origin: CGPoint, rows: Int, columns: Int, dotSize: CGFloat, spacing: CGFloat, color: NSColor) {
        for row in 0..<rows {
            for column in 0..<columns {
                let center = CGPoint(x: origin.x + CGFloat(column) * spacing, y: origin.y + CGFloat(rows - row - 1) * spacing)
                drawDot(center: center, size: dotSize, color: color)
            }
        }
    }

    private static func drawDot(center: CGPoint, size: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)).fill()
    }

    private static func drawAxis(origin: CGPoint, width: CGFloat, height: CGFloat) {
        drawArrow(from: origin, to: CGPoint(x: origin.x + width, y: origin.y), color: ink)
        drawArrow(from: origin, to: CGPoint(x: origin.x, y: origin.y + height), color: ink)
    }

    private static func drawPill(_ text: String, center: CGPoint, width: CGFloat, color: NSColor) {
        let rect = NSRect(x: center.x - width / 2, y: center.y - 52, width: width, height: 104)
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 24, yRadius: 24).fill()
        drawText(text, in: NSRect(x: rect.minX + 20, y: rect.minY + 31, width: rect.width - 40, height: 44), fontSize: 36, weight: .bold, color: .white, alignment: .center)
    }

    private static func drawArrow(from start: CGPoint, to end: CGPoint, color: NSColor) {
        drawLine(from: start, to: end, color: color, width: 10)
        let angle = atan2(end.y - start.y, end.x - start.x)
        let arrowLength: CGFloat = 38
        let left = CGPoint(
            x: end.x - arrowLength * cos(angle - .pi / 6),
            y: end.y - arrowLength * sin(angle - .pi / 6)
        )
        let right = CGPoint(
            x: end.x - arrowLength * cos(angle + .pi / 6),
            y: end.y - arrowLength * sin(angle + .pi / 6)
        )
        drawLine(from: left, to: end, color: color, width: 10)
        drawLine(from: right, to: end, color: color, width: 10)
    }

    private static func drawLine(from start: CGPoint, to end: CGPoint, color: NSColor, width: CGFloat) {
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        path.lineWidth = width
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }

    private static func drawText(
        _ text: String,
        in rect: NSRect,
        fontSize: CGFloat,
        weight: NSFont.Weight,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment
        paragraphStyle.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }

    private static let ink = NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.16, alpha: 1)
    private static let blue = NSColor(calibratedRed: 0.16, green: 0.43, blue: 0.92, alpha: 1)
    private static let green = NSColor(calibratedRed: 0.09, green: 0.64, blue: 0.42, alpha: 1)
    private static let orange = NSColor(calibratedRed: 0.93, green: 0.42, blue: 0.16, alpha: 1)
    private static let purple = NSColor(calibratedRed: 0.47, green: 0.24, blue: 0.86, alpha: 1)
}

@MainActor
enum LearningActionExecutor {
    private struct NativeLearningApp {
        let displayName: String
        let bundleIdentifier: String?
    }

    private struct FreeformTextPlacement {
        let slotNumber: Int
        let label: String
        let appKitPoint: CGPoint
    }

    private static var freeformTextPlacementIndex = 0

    static func execute(_ action: LearningAction) async -> String {
        switch action {
        case .none:
            return "no learning action"
        case .scrollDown:
            CGEventActions.scrollVertical(byUnits: -420)
            await settle()
            return "scrolled down"
        case .scrollUp:
            CGEventActions.scrollVertical(byUnits: 420)
            await settle()
            return "scrolled up"
        case .pausePlay:
            CGEventActions.pressKeyCombo("space")
            await settle()
            return "toggled play/pause"
        case .nextPage:
            CGEventActions.pressKeyCombo("right")
            await settle()
            return "advanced"
        case .previousPage:
            CGEventActions.pressKeyCombo("left")
            await settle()
            return "went back"
        case .zoomIn:
            CGEventActions.pressKeyCombo("cmd+=")
            await settle()
            return "zoomed in"
        case .zoomOut:
            CGEventActions.pressKeyCombo("cmd+-")
            await settle()
            return "zoomed out"
        case .openURL(let urlString):
            guard let sanitizedURLString = LearningURLSanitizer.openableURLString(from: urlString),
                  let url = URL(string: sanitizedURLString),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme) else {
                return "blocked invalid learning URL"
            }
            NSWorkspace.shared.open(url)
            await settle()
            return "opened \(sanitizedURLString)"
        case .openNativeApp(let appName):
            return await openNativeLearningApp(appName)
        case .openScratchpad:
            return await openScratchpad()
        case .writeScratchpad(let scratchpadText):
            return await writeScratchpad(scratchpadText)
        case .writeFreeformText(let freeformText):
            return await writeFreeformText(freeformText)
        case .prepareFreeformBoard(let freeformText):
            return await prepareFreeformBoard(freeformText)
        case .prepareFreeformDiagram(let spec):
            return await prepareFreeformDiagram(spec)
        }
    }

    @MainActor
    static func dismissPreparedLessonSurface() {
        let freeformBundleIdentifier = "com.apple.freeform"
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: freeformBundleIdentifier) {
            app.hide()
            FileLogger.log("🎓 Hid prepared Freeform lesson surface")
        }
    }

    private static func settle() async {
        try? await Task.sleep(nanoseconds: 250_000_000)
    }

    private static func openNativeLearningApp(_ rawAppName: String) async -> String {
        let normalizedName = rawAppName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let allowedAppsByName: [String: NativeLearningApp] = [
            "freeform": NativeLearningApp(displayName: "Freeform", bundleIdentifier: "com.apple.freeform"),
            "textedit": NativeLearningApp(displayName: "TextEdit", bundleIdentifier: "com.apple.TextEdit"),
            "text edit": NativeLearningApp(displayName: "TextEdit", bundleIdentifier: "com.apple.TextEdit"),
            "preview": NativeLearningApp(displayName: "Preview", bundleIdentifier: "com.apple.Preview"),
            "calculator": NativeLearningApp(displayName: "Calculator", bundleIdentifier: "com.apple.calculator")
        ]

        guard let app = allowedAppsByName[normalizedName] else {
            return "blocked non-learning native app \(rawAppName)"
        }

        let activated = await activateNativeLearningApp(app)
        if app.displayName == "Freeform" {
            return activated ? "activated Freeform whiteboard" : "could not activate Freeform whiteboard"
        }
        return activated ? "activated \(app.displayName)" : "could not activate \(app.displayName)"
    }

    private static func activateNativeLearningApp(_ app: NativeLearningApp) async -> Bool {
        if let runningApp = runningApplication(for: app) {
            bringNativeLearningAppToFront(runningApp)
        } else if let bundleIdentifier = app.bundleIdentifier,
                  let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            await openNativeLearningApplication(at: appURL, label: app.displayName)
        } else {
            return false
        }

        for _ in 0..<120 {
            if let runningApp = runningApplication(for: app) {
                bringNativeLearningAppToFront(runningApp)
            }
            if isFrontmost(app) {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return runningApplication(for: app)?.isActive == true
    }

    private static func bringNativeLearningAppToFront(_ runningApp: NSRunningApplication) {
        runningApp.unhide()
        runningApp.activate(options: [.activateAllWindows])
    }

    private static func openNativeLearningApplication(at url: URL, label: String) async {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error {
                    print("⚠️ Learning action openApplication failed for \(label): \(error)")
                }
                continuation.resume()
            }
        }
    }

    private static func runningApplication(for app: NativeLearningApp) -> NSRunningApplication? {
        if let bundleIdentifier = app.bundleIdentifier,
           let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
            return runningApp
        }
        return NSWorkspace.shared.runningApplications.first { runningApp in
            runningApp.localizedName?.lowercased() == app.displayName.lowercased()
        }
    }

    private static func isFrontmost(_ app: NativeLearningApp) -> Bool {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            return false
        }
        if let bundleIdentifier = app.bundleIdentifier,
           frontmostApplication.bundleIdentifier == bundleIdentifier {
            return true
        }
        return frontmostApplication.localizedName?.lowercased() == app.displayName.lowercased()
    }

    private static func ensureFreshFreeformCanvasReady() async -> Bool {
        let freeformApp = NativeLearningApp(displayName: "Freeform", bundleIdentifier: "com.apple.freeform")
        guard await activateNativeLearningApp(freeformApp) else {
            return false
        }

        CGEventActions.pressKeyCombo("cmd+n")
        try? await Task.sleep(nanoseconds: 900_000_000)
        resetFreeformTextPlacement()
        focusMainScreenCenter()
        try? await Task.sleep(nanoseconds: 150_000_000)
        return isFrontmost(freeformApp)
    }

    private static func focusMainScreenCenter() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let center = CGPoint(x: frame.midX, y: frame.midY)
        CGEventActions.leftClick(atGlobalPoint: center)
    }

    private static func openScratchpad() async -> String {
        do {
            let scratchpadURL = try ensureScratchpadExists()
            openInTextEdit(scratchpadURL)
            await settle()
            return "opened lesson scratchpad"
        } catch {
            return "could not open lesson scratchpad: \(error.localizedDescription)"
        }
    }

    private static func writeScratchpad(_ rawText: String) async -> String {
        do {
            let scratchpadURL = try ensureScratchpadExists()
            let text = normalizedScratchpadText(rawText)
            if !text.isEmpty {
                let entry = "\n---\n\(Self.timestampString())\n\(text)\n"
                let handle = try FileHandle(forWritingTo: scratchpadURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(entry.utf8))
                try handle.close()
            }
            openInTextEdit(scratchpadURL)
            await settle()
            return text.isEmpty ? "opened lesson scratchpad" : "wrote lesson scratchpad"
        } catch {
            return "could not write lesson scratchpad: \(error.localizedDescription)"
        }
    }

    private static func writeFreeformText(_ rawText: String) async -> String {
        let text = normalizedFreeformText(rawText)
        guard !text.isEmpty else {
            return "blocked empty Freeform text"
        }

        if NSWorkspace.shared.frontmostApplication?.localizedName?.lowercased().contains("freeform") != true {
            let freeformApp = NativeLearningApp(displayName: "Freeform", bundleIdentifier: "com.apple.freeform")
            guard await activateNativeLearningApp(freeformApp) else {
                return "could not activate Freeform; text not pasted"
            }
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return "could not find screen for Freeform text placement"
        }
        let placement = nextFreeformTextPlacement(on: screen)
        await clearFreeformSelection()
        insertFreeformTextBox(on: screen)
        try? await Task.sleep(nanoseconds: 250_000_000)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        CGEventActions.pressKeyCombo("cmd+v")
        try? await Task.sleep(nanoseconds: 180_000_000)
        CGEventActions.pressKeyCombo("escape")
        try? await Task.sleep(nanoseconds: 120_000_000)
        moveSelectedFreeformTextBox(to: placement.appKitPoint, on: screen)
        await settle()
        return isFreeformFrontmost()
            ? "wrote visible Freeform text in slot \(placement.slotNumber) (\(placement.label))"
            : "attempted Freeform text in slot \(placement.slotNumber) (\(placement.label)) but Freeform lost focus"
    }

    private static func prepareFreeformBoard(_ rawText: String) async -> String {
        let text = normalizedScratchpadText(rawText)
        guard !text.isEmpty else {
            return "blocked empty Freeform board"
        }

        guard await ensureFreshFreeformCanvasReady() else {
            return "could not activate Freeform; board not prepared"
        }
        resetFreeformTextPlacement()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        CGEventActions.pressKeyCombo("cmd+v")
        await settle()
        return isFreeformFrontmost() ? "prepared visible Freeform board" : "attempted Freeform board but Freeform lost focus"
    }

    private static func prepareFreeformDiagram(_ spec: FreeformDiagramSpec) async -> String {
        guard await ensureFreshFreeformCanvasReady() else {
            return "could not activate Freeform; diagram not pasted"
        }
        resetFreeformTextPlacement()

        let image = FreeformDiagramRenderer.render(spec)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        if let tiffData = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            pasteboard.setData(pngData, forType: .png)
        }

        focusMainScreenCenter()
        CGEventActions.pressKeyCombo("cmd+v")
        try? await Task.sleep(nanoseconds: 650_000_000)
        await enlargeSelectedFreeformObjectForTeaching()
        await zoomSelectedFreeformDiagramForTeaching()
        await clearFreeformSelection()
        try? await Task.sleep(nanoseconds: 250_000_000)
        return isFreeformFrontmost() ? "prepared visible Freeform diagram" : "attempted Freeform diagram but Freeform lost focus"
    }

    private static func isFreeformFrontmost() -> Bool {
        isFrontmost(NativeLearningApp(displayName: "Freeform", bundleIdentifier: "com.apple.freeform"))
    }

    private static func zoomSelectedFreeformDiagramForTeaching() async {
        for _ in 0..<5 {
            CGEventActions.pressKeyCombo("cmd+shift+=")
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let frame = screen.frame
        let visibleFrame = screen.visibleFrame
        let zoomPlusButton = CGPoint(
            x: visibleFrame.minX + 360,
            y: visibleFrame.minY + 122
        )
        let zoomPlusFallbacks = [
            zoomPlusButton,
            CGPoint(x: zoomPlusButton.x - 12, y: zoomPlusButton.y),
            CGPoint(x: zoomPlusButton.x + 12, y: zoomPlusButton.y)
        ]
        for index in 0..<12 {
            let button = zoomPlusFallbacks[index % zoomPlusFallbacks.count]
            CGEventActions.leftClick(atGlobalPoint: appKitPointToCGHIDPoint(button, screenFrame: frame))
            try? await Task.sleep(nanoseconds: 160_000_000)
        }
    }

    private static func enlargeSelectedFreeformObjectForTeaching() async {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.frame
        let startAppKit = CGPoint(
            x: frame.midX + min(320, frame.width * 0.12),
            y: frame.midY - min(90, frame.height * 0.05)
        )
        let endAppKit = CGPoint(
            x: min(frame.maxX - 160, frame.midX + frame.width * 0.28),
            y: max(frame.minY + 240, frame.midY - frame.height * 0.24)
        )
        CGEventActions.leftClickDrag(
            fromGlobalPoint: appKitPointToCGHIDPoint(startAppKit, screenFrame: frame),
            toGlobalPoint: appKitPointToCGHIDPoint(endAppKit, screenFrame: frame)
        )
        try? await Task.sleep(nanoseconds: 350_000_000)
    }

    private static func appKitPointToCGHIDPoint(_ point: CGPoint, screenFrame: CGRect) -> CGPoint {
        CGPoint(
            x: point.x,
            y: screenFrame.origin.y + screenFrame.height - (point.y - screenFrame.origin.y)
        )
    }

    private static func resetFreeformTextPlacement() {
        freeformTextPlacementIndex = 0
    }

    private static func clearFreeformSelection() async {
        for _ in 0..<3 {
            CGEventActions.pressKeyCombo("escape")
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
    }

    private static func insertFreeformTextBox(on screen: NSScreen) {
        let visibleFrame = screen.visibleFrame
        let textToolPoint = CGPoint(
            x: visibleFrame.midX + min(48, visibleFrame.width * 0.025),
            y: visibleFrame.maxY - 86
        )
        CGEventActions.leftClick(
            atGlobalPoint: appKitPointToCGHIDPoint(textToolPoint, screenFrame: screen.frame)
        )
    }

    private static func moveSelectedFreeformTextBox(to appKitPoint: CGPoint, on screen: NSScreen) {
        let visibleFrame = screen.visibleFrame
        let defaultTextBoxCenter = CGPoint(
            x: visibleFrame.midX + min(90, visibleFrame.width * 0.04),
            y: visibleFrame.midY + min(150, visibleFrame.height * 0.10)
        )
        CGEventActions.leftClickDrag(
            fromGlobalPoint: appKitPointToCGHIDPoint(defaultTextBoxCenter, screenFrame: screen.frame),
            toGlobalPoint: appKitPointToCGHIDPoint(appKitPoint, screenFrame: screen.frame)
        )
    }

    private static func nextFreeformTextPlacement(on screen: NSScreen) -> FreeformTextPlacement {
        let visibleFrame = screen.visibleFrame
        let canvasLeft = visibleFrame.minX + max(620, visibleFrame.width * 0.24)
        let canvasRight = visibleFrame.maxX - max(620, visibleFrame.width * 0.22)
        let noteTop = visibleFrame.maxY - max(360, visibleFrame.height * 0.24)
        let noteMiddle = visibleFrame.midY + max(260, visibleFrame.height * 0.16)
        let noteBottom = visibleFrame.minY + max(300, visibleFrame.height * 0.22)

        let baseSlots: [(String, CGPoint)] = [
            ("upper-left note lane", CGPoint(x: canvasLeft, y: noteTop)),
            ("upper-right note lane", CGPoint(x: canvasRight, y: noteTop)),
            ("middle-left note lane", CGPoint(x: canvasLeft, y: noteMiddle)),
            ("middle-right note lane", CGPoint(x: canvasRight, y: noteMiddle)),
            ("lower-left note lane", CGPoint(x: canvasLeft, y: noteBottom)),
            ("lower-right note lane", CGPoint(x: canvasRight, y: noteBottom))
        ]

        let rawIndex = freeformTextPlacementIndex
        freeformTextPlacementIndex += 1
        let slotIndex = rawIndex % baseSlots.count
        let wrapCount = rawIndex / baseSlots.count
        let (label, basePoint) = baseSlots[slotIndex]
        let stagger = CGFloat(wrapCount) * 34
        let staggeredPoint = CGPoint(
            x: min(visibleFrame.maxX - 360, max(visibleFrame.minX + 560, basePoint.x + stagger)),
            y: max(visibleFrame.minY + 220, min(visibleFrame.maxY - 280, basePoint.y - stagger))
        )

        return FreeformTextPlacement(
            slotNumber: rawIndex + 1,
            label: label,
            appKitPoint: staggeredPoint
        )
    }

    private static func ensureScratchpadExists() throws -> URL {
        let ipopDirectoryURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".ipop-ai", isDirectory: true)
        try FileManager.default.createDirectory(
            at: ipopDirectoryURL,
            withIntermediateDirectories: true
        )

        let scratchpadURL = ipopDirectoryURL.appendingPathComponent("lesson-scratchpad.txt")
        if !FileManager.default.fileExists(atPath: scratchpadURL.path) {
            let header = """
            iPOP Lesson Scratchpad
            This is a local scratchpad iPOP can use for temporary lesson notes.

            """
            try Data(header.utf8).write(to: scratchpadURL, options: .atomic)
        }
        return scratchpadURL
    }

    private static func normalizedScratchpadText(_ rawText: String) -> String {
        rawText
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: " | ", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(2_000)
            .description
    }

    private static func normalizedFreeformText(_ rawText: String) -> String {
        let normalized = normalizedScratchpadText(rawText)
        guard normalized.count > 520 else { return normalized }
        return String(normalized.prefix(520)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func openInTextEdit(_ url: URL) {
        let script = """
        tell application "TextEdit"
            activate
            open POSIX file "\(AppleScriptLearningBridge.escape(url.path))"
        end tell
        """
        if AppleScriptLearningBridge.run(script) == nil {
            NSWorkspace.shared.open(url)
        }
    }

    private static func timestampString() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        return formatter.string(from: Date())
    }
}
