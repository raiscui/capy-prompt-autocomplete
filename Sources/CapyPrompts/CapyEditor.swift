import AppKit
import ApplicationServices

struct EditorSnapshot {
    let thread: String
    let prefix: String
    let suffix: String
    let context: String
    fileprivate let processID: pid_t
    fileprivate let window: AXUIElement
    fileprivate let webArea: AXUIElement
    fileprivate let editor: AXUIElement
    fileprivate let url: String
    fileprivate let selection: CFRange

    func matches(_ other: EditorSnapshot) -> Bool {
        processID == other.processID && thread == other.thread && url == other.url &&
        CFEqual(window, other.window) && CFEqual(webArea, other.webArea) &&
        CFEqual(editor, other.editor) && prefix == other.prefix && suffix == other.suffix &&
        selection.location == other.selection.location && selection.length == other.selection.length
    }
}

@MainActor
final class CapyEditor {
    private var cachedScroller: (webArea: AXUIElement, url: String, element: AXUIElement)?

    enum InsertionError: LocalizedError {
        case changed
        case unsupportedText
        case unavailable
        case writeFailed
        case unconfirmed

        var errorDescription: String? {
            switch self {
            case .changed: return "The Capy message or cursor changed. Generate suggestions again."
            case .unsupportedText: return "This editor cannot insert multiline text without accessibility text insertion."
            case .unavailable: return "Text insertion is unavailable for this Capy message."
            case .writeFailed: return "Capy could not confirm the insertion. Check the message before trying again."
            case .unconfirmed: return "Could not confirm the insertion. Check the message before trying again."
            }
        }
    }

    func snapshot() -> EditorSnapshot? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == "ai.capy.desktop" else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = element(application, kAXFocusedWindowAttribute),
              let editor = element(application, kAXFocusedUIElementAttribute),
              string(editor, kAXRoleAttribute) == kAXTextAreaRole as String,
              string(editor, kAXTitleAttribute) == "Message",
              let text = string(editor, kAXValueAttribute),
              let selection = range(editor, kAXSelectedTextRangeAttribute),
              selection.location >= 0, selection.length == 0,
              selection.location <= (text as NSString).length,
              let index = Range(NSRange(location: selection.location, length: 0), in: text)?.lowerBound,
              let webArea = ancestorWebArea(of: editor),
              let url = urlString(webArea),
              let thread = threadIdentity(url) else { return nil }

        // Chromium exposes an empty contenteditable as a lone newline.
        let prefix = text == "\n" ? "" : String(text[..<index])
        let suffix = text == "\n" ? "" : String(text[index...])
        return EditorSnapshot(thread: thread, prefix: prefix,
                              suffix: suffix, context: transcript(in: webArea, url: url),
                              processID: app.processIdentifier, window: window, webArea: webArea,
                              editor: editor, url: url, selection: selection)
    }

    func insert(_ text: String, into expected: EditorSnapshot, skills: [ThreadSkill] = []) throws {
        guard !text.isEmpty, let current = snapshot(), expected.matches(current) else { throw InsertionError.changed }
        let content = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard content.unicodeScalars.allSatisfy({ $0 == "\n" || !CharacterSet.controlCharacters.contains($0) }), let source = CGEventSource(stateID: .privateState) else { throw InsertionError.unsupportedText }
        let application = AXUIElementCreateApplication(current.processID)
        func live() -> Bool {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == current.processID &&
            element(application, kAXFocusedWindowAttribute).map { CFEqual($0, current.window) } == true &&
            urlString(current.webArea) == current.url
        }
        func editorFocused() -> Bool {
            element(application, kAXFocusedUIElementAttribute).map { CFEqual($0, current.editor) } == true
        }
        func typeText(_ part: Substring) throws {
            for ch in part {
                guard live(), editorFocused() else { throw InsertionError.changed }
                let newline = ch == "\n"
                for down in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: source, virtualKey: newline ? 36 : 0, keyDown: down) else { throw InsertionError.unavailable }
                    event.flags = newline ? .maskShift : []
                    if !newline { let units = Array(String(ch).utf16); units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress!) } }
                    event.postToPid(current.processID)
                }
            }
        }
        func value() -> String? { string(current.editor, kAXValueAttribute) }
        func awaitValue(_ target: String) throws {
            for _ in 0..<25 { guard live() else { throw InsertionError.changed }; if value() == target { return }; Thread.sleep(forTimeInterval: 0.02) }
            throw InsertionError.unconfirmed
        }
        let names = Set(skills.map(\.name))
        var prefix = current.prefix
        var start = content.startIndex
        for match in Self.skillToken.matches(in: content, range: NSRange(content.startIndex..., in: content)) {
            guard let token = Range(match.range, in: content), let nameRange = Range(match.range(at: 1), in: content), names.contains(String(content[nameRange])) else { continue }
            let name = String(content[nameRange]); let before = content[start..<token.lowerBound]
            try typeText(before); prefix += before
            // The first '$' opens Capy's suggestion surface; type the complete query before selecting a row.
            try typeText(content[token]); try awaitValue(prefix + "$" + name + current.suffix)
            let focusedRow = try skillRow(name: name, app: application, snapshot: current, live: live)
            guard live(), AXUIElementPerformAction(focusedRow, kAXPressAction as CFString) == .success else { throw InsertionError.unconfirmed }
            var committed: String?
            for _ in 0..<30 {
                guard live() else { throw InsertionError.changed }
                if editorFocused(), let actual = value(), actual != prefix + "$" + name + current.suffix,
                   actual.hasPrefix(prefix), actual.hasSuffix(current.suffix) {
                    let middle = actual.dropFirst(prefix.count).dropLast(current.suffix.count)
                    if [name, "@"+name, "$"+name, "\u{fffc}"].contains(String(middle).trimmingCharacters(in: .whitespaces)) { committed = String(actual.dropLast(current.suffix.count)); break }
                }
                Thread.sleep(forTimeInterval: 0.025)
            }
            guard let committed else { throw InsertionError.unconfirmed }; prefix = committed
            start = token.upperBound
            if start < content.endIndex, content[start] == " ", prefix.last?.isWhitespace == true { start = content.index(after: start) }
        }
        let tail = content[start...]; try typeText(tail); try awaitValue(prefix + tail + current.suffix)
    }

    private static let skillToken = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_/])\$([a-z0-9][a-z0-9_-]*(?:[./][a-z0-9_-]+)*)"#)

    private func skillRow(name: String, app: AXUIElement, snapshot: EditorSnapshot, live: () -> Bool) throws -> AXUIElement {
        for _ in 0..<24 {
            guard live() else { throw InsertionError.changed }
            if let row = element(app, kAXFocusedUIElementAttribute), !CFEqual(row, snapshot.editor),
               let web = ancestorWebArea(of: row), CFEqual(web, snapshot.webArea),
               string(row, kAXRoleAttribute) == kAXStaticTextRole as String,
               let title = string(row, kAXValueAttribute) ?? string(row, kAXTitleAttribute),
               title == name || title.hasPrefix(name + " ") { return row }
            Thread.sleep(forTimeInterval: 0.025)
        }
        throw InsertionError.unconfirmed
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(parent, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private func range(_ element: AXUIElement, _ name: String) -> CFRange? {
        guard let raw = attribute(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = raw as! AXValue
        guard AXValueGetType(value) == .cfRange else { return nil }
        var result = CFRange()
        return AXValueGetValue(value, .cfRange, &result) ? result : nil
    }

    private func ancestorWebArea(of editor: AXUIElement) -> AXUIElement? {
        var cursor = editor
        for _ in 0..<80 {
            guard let parent = element(cursor, kAXParentAttribute) else { return nil }
            if string(parent, kAXRoleAttribute) == "AXWebArea" { return parent }
            cursor = parent
        }
        return nil
    }

    private func urlString(_ webArea: AXUIElement) -> String? {
        guard let raw = attribute(webArea, kAXURLAttribute) else { return nil }
        if let url = raw as? URL { return url.absoluteString }
        return raw as? String
    }

    private func threadIdentity(_ rawURL: String) -> String? {
        guard let url = URLComponents(string: rawURL) else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0] == "thread", !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private func hasClass(_ element: AXUIElement, _ name: String) -> Bool {
        let raw = attribute(element, "AXDOMClassList")
        if let classes = raw as? [String] { return classes.contains(name) }
        if let classes = raw as? String { return classes.split(whereSeparator: \.isWhitespace).contains(Substring(name)) }
        return false
    }

    private func transcript(in webArea: AXUIElement, url: String) -> String {
        var scroller: AXUIElement?
        if let cached = cachedScroller, cached.url == url, CFEqual(cached.webArea, webArea),
           hasClass(cached.element, "chat-scroller"),
           let parentWebArea = ancestorWebArea(of: cached.element), CFEqual(parentWebArea, webArea) {
            scroller = cached.element
        } else {
            cachedScroller = nil
            var pending = [webArea]
            var searched = 0
            while let item = pending.popLast(), searched < 4_000 {
                searched += 1
                if hasClass(item, "chat-scroller") {
                    scroller = item
                    cachedScroller = (webArea, url, item)
                    break
                }
                pending.append(contentsOf: children(item).reversed())
            }
        }
        guard let scroller else { return "" }
        var inspected = 0
        var items = [scroller]
        var chunks: [String] = []
        inspected = 0
        while let item = items.popLast(), inspected < 6_000 {
            inspected += 1
            if (attribute(item, kAXHiddenAttribute) as? Bool) == true { continue }
            let role = string(item, kAXRoleAttribute)
            if role == kAXButtonRole as String || role == kAXTextAreaRole as String ||
               role == kAXTextFieldRole as String { continue }
            // Sponsored cards (e.g. Gravity ads): skip the whole anchor subtree so
            // headline / description / "Ad" / "domain ↗" never enter the transcript.
            if role == "AXLink" && isSponsoredLink(item) { continue }
            if role == kAXStaticTextRole as String {
                if let text = string(item, kAXValueAttribute), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    chunks.append(text)
                }
                continue
            }
            items.append(contentsOf: children(item).reversed())
        }
        let joined = chunks.joined(separator: "\n")
        return String(joined.suffix(4_000))
    }

    private func isSponsoredLink(_ element: AXUIElement) -> Bool {
        if hasClass(element, "group/ad") { return true }
        if let rel = attribute(element, "AXDOMRelationship") as? String,
           rel.split(whereSeparator: \.isWhitespace).contains("sponsored") { return true }
        guard let raw = attribute(element, kAXURLAttribute) else { return false }
        let urlString = (raw as? URL)?.absoluteString ?? (raw as? String) ?? ""
        guard let host = URLComponents(string: urlString)?.host?.lowercased() else { return false }
        return Self.sponsoredHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static let sponsoredHosts: [String] = [
        "trygravity.ai",
    ]
}
