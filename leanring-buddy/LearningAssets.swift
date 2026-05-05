import AppKit
import Foundation
import PDFKit

enum LearningAssetType: String, Equatable {
    case screen
    case youtube
    case browserPage
    case localDocument
    case whiteboard
    case code
    case unknown

    var displayName: String {
        switch self {
        case .screen: return "screen"
        case .youtube: return "YouTube"
        case .browserPage: return "web page"
        case .localDocument: return "document"
        case .whiteboard: return "whiteboard"
        case .code: return "code"
        case .unknown: return "screen"
        }
    }
}

struct LearningAssetContext: Equatable {
    let assetType: LearningAssetType
    let frontmostAppName: String?
    let candidateTopic: String?
    let browserTitle: String?
    let browserURL: String?
    let selectedFilePaths: [String]
    let selectedFilePreview: String?
    let screenContextLines: [String]
    let assetNotes: [String]

    init(
        assetType: LearningAssetType,
        frontmostAppName: String?,
        candidateTopic: String?,
        browserTitle: String?,
        browserURL: String?,
        selectedFilePaths: [String],
        selectedFilePreview: String?,
        screenContextLines: [String],
        assetNotes: [String] = []
    ) {
        self.assetType = assetType
        self.frontmostAppName = frontmostAppName
        self.candidateTopic = candidateTopic
        self.browserTitle = browserTitle
        self.browserURL = browserURL
        self.selectedFilePaths = selectedFilePaths
        self.selectedFilePreview = selectedFilePreview
        self.screenContextLines = screenContextLines
        self.assetNotes = assetNotes
    }

    var promptBlock: String {
        var lines: [String] = []
        lines.append("<learning-asset-context>")
        lines.append("asset_type: \(assetType.rawValue)")
        if let frontmostAppName {
            lines.append("frontmost_app: \(frontmostAppName)")
        }
        if let candidateTopic, !candidateTopic.isEmpty {
            lines.append("candidate_topic: \(candidateTopic)")
        }
        if let browserTitle, !browserTitle.isEmpty {
            lines.append("browser_title: \(browserTitle)")
        }
        if let browserURL, !browserURL.isEmpty {
            lines.append("browser_url: \(browserURL)")
        }
        if !selectedFilePaths.isEmpty {
            lines.append("selected_files:")
            selectedFilePaths.prefix(5).forEach { lines.append("- \($0)") }
        }
        if let selectedFilePreview, !selectedFilePreview.isEmpty {
            lines.append("selected_file_preview:")
            lines.append(selectedFilePreview)
        }
        if !assetNotes.isEmpty {
            lines.append("asset_notes:")
            assetNotes.prefix(12).forEach { lines.append("- \($0)") }
        }
        if !screenContextLines.isEmpty {
            lines.append("screen_context:")
            screenContextLines.forEach { lines.append("- \($0)") }
        }
        lines.append("</learning-asset-context>")
        return lines.joined(separator: "\n")
    }
}

@MainActor
enum LearningAssetContextBuilder {
    static func build(
        frontmostAppName: String?,
        screenCaptures: [CompanionScreenCapture]
    ) -> LearningAssetContext {
        let browserPage = BrowserLearningConnector.currentPage(frontmostAppName: frontmostAppName)
        let selectedFilePaths = LocalDocumentLearningConnector.selectedFinderPaths(
            frontmostAppName: frontmostAppName
        )
        let selectedFilePreview = LocalDocumentLearningConnector.previewText(for: selectedFilePaths.first)
        let screenLines = ScreenLearningConnector.contextLines(from: screenCaptures)

        let assetType: LearningAssetType
        if let browserURL = browserPage?.url, YouTubeLearningConnector.isYouTubeURL(browserURL) {
            assetType = .youtube
        } else if WhiteboardLearningConnector.isWhiteboardApp(frontmostAppName) {
            assetType = .whiteboard
        } else if CodeLearningConnector.isCodeApp(frontmostAppName) {
            assetType = .code
        } else if !selectedFilePaths.isEmpty || LocalDocumentLearningConnector.isDocumentApp(frontmostAppName) {
            assetType = .localDocument
        } else if browserPage != nil {
            assetType = .browserPage
        } else {
            assetType = screenCaptures.isEmpty ? .unknown : .screen
        }

        let candidateTopic = candidateTopic(
            assetType: assetType,
            frontmostAppName: frontmostAppName,
            browserPage: browserPage,
            selectedFilePaths: selectedFilePaths
        )
        let assetNotes = assetNotes(
            assetType: assetType,
            frontmostAppName: frontmostAppName,
            browserPage: browserPage,
            selectedFilePaths: selectedFilePaths,
            selectedFilePreview: selectedFilePreview
        )

        return LearningAssetContext(
            assetType: assetType,
            frontmostAppName: frontmostAppName,
            candidateTopic: candidateTopic,
            browserTitle: browserPage?.title,
            browserURL: browserPage?.url,
            selectedFilePaths: selectedFilePaths,
            selectedFilePreview: selectedFilePreview,
            screenContextLines: screenLines,
            assetNotes: assetNotes
        )
    }

    private static func candidateTopic(
        assetType: LearningAssetType,
        frontmostAppName: String?,
        browserPage: BrowserLearningConnector.Page?,
        selectedFilePaths: [String]
    ) -> String? {
        if assetType == .youtube, let title = browserPage?.title, !title.isEmpty {
            return title
        }
        if let title = browserPage?.title, !title.isEmpty {
            return title
        }
        if let firstPath = selectedFilePaths.first {
            return URL(fileURLWithPath: firstPath).lastPathComponent
        }
        if assetType == .whiteboard {
            return "whiteboard in \(frontmostAppName ?? "current app")"
        }
        if assetType == .code {
            return "code in \(frontmostAppName ?? "current app")"
        }
        if let frontmostAppName {
            return "\(assetType.displayName) in \(frontmostAppName)"
        }
        return nil
    }

    private static func assetNotes(
        assetType: LearningAssetType,
        frontmostAppName: String?,
        browserPage: BrowserLearningConnector.Page?,
        selectedFilePaths: [String],
        selectedFilePreview: String?
    ) -> [String] {
        var notes: [String] = []

        if let browserPage {
            if assetType == .youtube {
                notes.append("youtube_title: \(browserPage.title)")
                notes.append("youtube_url: \(browserPage.url)")
                if let captions = browserPage.youtubeCaptions, !captions.isEmpty {
                    notes.append("visible_youtube_captions: \(captions)")
                }
                if let transcript = browserPage.youtubeTranscript, !transcript.isEmpty {
                    notes.append("visible_youtube_transcript: \(transcript)")
                }
                if browserPage.youtubeCaptions?.isEmpty != false
                    && browserPage.youtubeTranscript?.isEmpty != false {
                    notes.append("youtube_transcript_status: no visible captions or transcript were readable; use the video title, visible frame, page text, URL, and screenshots only.")
                }
            } else {
                notes.append("browser_page_title: \(browserPage.title)")
                notes.append("browser_page_url: \(browserPage.url)")
            }

            if let selectedText = browserPage.selectedText, !selectedText.isEmpty {
                notes.append("selected_browser_text: \(selectedText)")
            }
            if let visibleText = browserPage.visibleText, !visibleText.isEmpty {
                notes.append("visible_page_text: \(visibleText)")
            }
        }

        if assetType == .whiteboard {
            notes.append(contentsOf: WhiteboardLearningConnector.currentBoardContext(frontmostAppName: frontmostAppName))
        }

        if assetType == .localDocument {
            if !selectedFilePaths.isEmpty {
                notes.append("document_selection: user selected \(selectedFilePaths.count) file(s) in Finder.")
            }
            if selectedFilePreview?.isEmpty == false {
                notes.append("document_preview_status: text preview is included above.")
            }
        }

        if assetType == .code {
            notes.append("code_surface: use the visible code, errors, selected text, and screenshots as the lesson material; teach the underlying mental model before the fix.")
        }

        return notes
    }
}

enum ScreenLearningConnector {
    static func contextLines(from screenCaptures: [CompanionScreenCapture]) -> [String] {
        screenCaptures.map { capture in
            "\(capture.label), image \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels"
        }
    }
}

enum BrowserLearningConnector {
    struct Page: Equatable {
        let title: String
        let url: String
        let selectedText: String?
        let visibleText: String?
        let youtubeCaptions: String?
        let youtubeTranscript: String?

        init(
            title: String,
            url: String,
            selectedText: String? = nil,
            visibleText: String? = nil,
            youtubeCaptions: String? = nil,
            youtubeTranscript: String? = nil
        ) {
            self.title = title
            self.url = url
            self.selectedText = selectedText
            self.visibleText = visibleText
            self.youtubeCaptions = youtubeCaptions
            self.youtubeTranscript = youtubeTranscript
        }
    }

    fileprivate struct DOMContext {
        let selectedText: String?
        let visibleText: String?
        let youtubeCaptions: String?
        let youtubeTranscript: String?
    }

    @MainActor
    static func currentPage(frontmostAppName: String?) -> Page? {
        guard let appName = frontmostAppName else { return nil }
        let lowercasedName = appName.lowercased()

        if lowercasedName.contains("safari") {
            return safariCurrentPage() ?? browserAddressBarFallbackPage(appName: appName)
        }

        if lowercasedName.contains("chrome")
            || lowercasedName.contains("arc")
            || lowercasedName.contains("brave")
            || lowercasedName.contains("edge") {
            return chromiumCurrentPage(appName: appName) ?? browserAddressBarFallbackPage(appName: appName)
        }

        return nil
    }

    @MainActor
    private static func safariCurrentPage() -> Page? {
        let script = """
        tell application "Safari"
            if not (exists front window) then return ""
            set pageTitle to name of current tab of front window
            set pageURL to URL of current tab of front window
            return pageTitle & "\n" & pageURL
        end tell
        """
        guard let page = page(fromAppleScriptOutput: AppleScriptLearningBridge.run(script)) else {
            return nil
        }
        return page.withDOMContext(safariDOMContext())
    }

    @MainActor
    private static func chromiumCurrentPage(appName: String) -> Page? {
        let escapedAppName = AppleScriptLearningBridge.escape(appName)
        let script = """
        tell application "\(escapedAppName)"
            if not (exists front window) then return ""
            set pageTitle to title of active tab of front window
            set pageURL to URL of active tab of front window
            return pageTitle & "\n" & pageURL
        end tell
        """
        guard let page = page(fromAppleScriptOutput: AppleScriptLearningBridge.run(script)) else {
            return nil
        }
        return page.withDOMContext(chromiumDOMContext(appName: appName))
    }

    private static func page(fromAppleScriptOutput output: String?) -> Page? {
        guard let output, !output.isEmpty else { return nil }
        let lines = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else { return nil }
        return Page(title: lines[0], url: lines[1])
    }

    @MainActor
    private static func browserAddressBarFallbackPage(appName: String) -> Page? {
        let pasteboard = NSPasteboard.general
        let previousString = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        CGEventActions.pressKeyCombo("cmd+l")
        Thread.sleep(forTimeInterval: 0.12)
        CGEventActions.pressKeyCombo("cmd+c")
        Thread.sleep(forTimeInterval: 0.12)
        let urlString = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        CGEventActions.pressKeyCombo("esc")

        pasteboard.clearContents()
        if let previousString {
            pasteboard.setString(previousString, forType: .string)
        }

        guard let urlString,
              let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            return nil
        }

        return Page(title: "\(appName) page", url: url.absoluteString)
    }

    @MainActor
    private static func safariDOMContext() -> DOMContext? {
        let escapedJavaScript = AppleScriptLearningBridge.escape(browserContextJavaScript)
        let script = """
        tell application "Safari"
            if not (exists front window) then return ""
            return do JavaScript "\(escapedJavaScript)" in current tab of front window
        end tell
        """
        return domContext(fromJSONOutput: AppleScriptLearningBridge.run(script))
    }

    @MainActor
    private static func chromiumDOMContext(appName: String) -> DOMContext? {
        let escapedAppName = AppleScriptLearningBridge.escape(appName)
        let escapedJavaScript = AppleScriptLearningBridge.escape(browserContextJavaScript)
        let script = """
        tell application "\(escapedAppName)"
            if not (exists front window) then return ""
            return execute active tab of front window javascript "\(escapedJavaScript)"
        end tell
        """
        return domContext(fromJSONOutput: AppleScriptLearningBridge.run(script))
    }

    private static func domContext(fromJSONOutput output: String?) -> DOMContext? {
        guard let output,
              let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return DOMContext(
            selectedText: compactText(object["selectedText"] as? String, limit: 1_200),
            visibleText: compactText(object["visibleText"] as? String, limit: 2_400),
            youtubeCaptions: compactText(object["youtubeCaptions"] as? String, limit: 1_200),
            youtubeTranscript: compactText(object["youtubeTranscript"] as? String, limit: 2_400)
        )
    }

    private static var browserContextJavaScript: String {
        let source = """
        (() => {
            const normalize = (value) => String(value || '').replace(/\\s+/g, ' ').trim();
            const limit = (value, count) => {
                const text = normalize(value);
                return text.length > count ? text.slice(0, count) + ' [truncated]' : text;
            };
            const textFromNodes = (selector, maxNodes = 80) =>
                Array.from(document.querySelectorAll(selector))
                    .filter((node) => {
                        const rect = node.getBoundingClientRect();
                        const style = window.getComputedStyle(node);
                        return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none';
                    })
                    .slice(0, maxNodes)
                    .map((node) => node.innerText || node.textContent || '')
                    .map(normalize)
                    .filter(Boolean)
                    .join(' | ');
            const selectedText = limit(String(window.getSelection ? window.getSelection() : ''), 1200);
            const youtubeCaptions = limit(textFromNodes('.ytp-caption-segment', 20), 1200);
            const youtubeTranscript = limit(textFromNodes('ytd-transcript-segment-renderer .segment-text, ytd-transcript-segment-renderer yt-formatted-string', 120), 2400);
            const headings = textFromNodes('h1, h2, h3, [role="heading"]', 30);
            const bodyText = textFromNodes('article p, main p, article li, main li, p, li, figcaption, pre, code', 80);
            const visibleText = limit([headings, bodyText].filter(Boolean).join(' | '), 2400);
            return JSON.stringify({ selectedText, visibleText, youtubeCaptions, youtubeTranscript });
        })();
        """
        return source
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: " ")
    }

    private static func compactText(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let compacted = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compacted.isEmpty else { return nil }
        if compacted.count <= limit {
            return compacted
        }
        return String(compacted.prefix(limit)) + " [truncated]"
    }
}

fileprivate extension BrowserLearningConnector.Page {
    func withDOMContext(_ context: BrowserLearningConnector.DOMContext?) -> BrowserLearningConnector.Page {
        BrowserLearningConnector.Page(
            title: title,
            url: url,
            selectedText: context?.selectedText,
            visibleText: context?.visibleText,
            youtubeCaptions: context?.youtubeCaptions,
            youtubeTranscript: context?.youtubeTranscript
        )
    }
}

enum YouTubeLearningConnector {
    static func isYouTubeURL(_ urlString: String) -> Bool {
        let lowercased = urlString.lowercased()
        return lowercased.contains("youtube.com") || lowercased.contains("youtu.be")
    }
}

enum LocalDocumentLearningConnector {
    @MainActor
    static func selectedFinderPaths(frontmostAppName: String?) -> [String] {
        guard frontmostAppName?.lowercased().contains("finder") == true else { return [] }
        let script = """
        tell application "Finder"
            set selectedItems to selection
            set outputText to ""
            repeat with selectedItem in selectedItems
                set outputText to outputText & POSIX path of (selectedItem as alias) & "\n"
            end repeat
            return outputText
        end tell
        """
        guard let output = AppleScriptLearningBridge.run(script), !output.isEmpty else { return [] }
        return output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func isDocumentApp(_ appName: String?) -> Bool {
        guard let appName = appName?.lowercased() else { return false }
        let documentApps = ["preview", "acrobat", "books", "pages", "keynote", "numbers"]
        return documentApps.contains { appName.contains($0) }
    }

    static func previewText(for path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        if url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: url) else { return nil }
            var pages: [String] = []
            for index in 0..<min(document.pageCount, 5) {
                if let rawPageText = document.page(at: index)?.string {
                    let pageText = rawPageText
                        .components(separatedBy: .whitespacesAndNewlines)
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    if !pageText.isEmpty {
                        pages.append(pageText)
                    }
                }
            }
            let joined = pages.joined(separator: "\n")
            guard !joined.isEmpty else { return nil }
            let maxCharacters = 4_000
            return joined.count <= maxCharacters ? joined : String(joined.prefix(maxCharacters)) + "\n[pdf preview truncated]"
        }
        let allowedExtensions: Set<String> = [
            "txt", "md", "markdown", "swift", "py", "js", "ts", "tsx",
            "html", "css", "json", "csv", "yaml", "yml"
        ]
        guard allowedExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= 300_000 else {
            return nil
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let maxCharacters = 4_000
        if text.count <= maxCharacters { return text }
        return String(text.prefix(maxCharacters)) + "\n[preview truncated]"
    }
}

enum WhiteboardLearningConnector {
    static func isWhiteboardApp(_ appName: String?) -> Bool {
        guard let appName = appName?.lowercased() else { return false }
        let whiteboardApps = ["freeform", "miro", "figma", "figjam", "excalidraw", "concepts"]
        return whiteboardApps.contains { appName.contains($0) }
    }

    @MainActor
    static func currentBoardContext(frontmostAppName: String?) -> [String] {
        guard let frontmostAppName, isWhiteboardApp(frontmostAppName) else { return [] }
        var notes = [
            "whiteboard_surface: use screenshots as the primary learning asset; reason about visible text, clusters, arrows, shapes, spacing, and relationships."
        ]

        if let windowTitle = currentWindowTitle(appName: frontmostAppName), !windowTitle.isEmpty {
            notes.append("whiteboard_window_title: \(windowTitle)")
        }

        if frontmostAppName.lowercased().contains("freeform") {
            notes.append("freeform_capability: iPOP may open Freeform and paste short lesson text onto the board when useful.")
        }

        return notes
    }

    @MainActor
    private static func currentWindowTitle(appName: String) -> String? {
        let normalizedAppName = appName.lowercased()
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for window in windowInfo {
            let ownerName = (window[kCGWindowOwnerName as String] as? String)?.lowercased() ?? ""
            guard !ownerName.isEmpty else { continue }
            guard ownerName == normalizedAppName
                || ownerName.contains(normalizedAppName)
                || normalizedAppName.contains(ownerName) else {
                continue
            }
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }
            if let title = window[kCGWindowName as String] as? String,
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return title
            }
        }
        return nil
    }
}

enum CodeLearningConnector {
    static func isCodeApp(_ appName: String?) -> Bool {
        guard let appName = appName?.lowercased() else { return false }
        let codeApps = ["xcode", "visual studio code", "cursor", "zed", "sublime", "terminal", "iterm"]
        return codeApps.contains { appName.contains($0) }
    }
}

enum AppleScriptLearningBridge {
    @MainActor
    static func run(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            print("⚠️ Learning connector AppleScript failed: \(errorInfo)")
            return nil
        }
        return result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func escape(_ rawString: String) -> String {
        rawString.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
