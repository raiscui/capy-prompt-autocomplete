//
//  Picker.swift
//  CapyPrompts
//
//  Nonactivating completion picker hosted next to the Capy editor.
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Overlay picker for Capy prompt autocomplete suggestions.
///
/// The picker owns two pieces of UI:
///   * a nonactivating `NSPanel` shown near the Capy editor (a wrapped
///     *ghost preview* or a selectable candidate *list*), and
///   * a small status HUD for transient error feedback.
///
/// Hotkey handling uses scoped Carbon `RegisterEventHotKey` registrations.
/// Carbon hotkeys fire only for the exact combos below, so nothing else the
/// user types is observed (no keystroke logging), the pasteboard is never
/// touched, and a matched key is consumed before it reaches the editor — so
/// these keys can never type text (or Enter) into the Capy editor:
///
///   Ctrl+Option+Space    trigger   ask the parent to generate / open the full list
///   Ctrl+Option+1...3    accept    accept candidates 1-3 (in the list or ghost)
///   Ctrl+Option+Up/Down  move      move the list selection
///   Ctrl+Option+Return   accept    accept the highlighted candidate
///   Ctrl+Option+Esc      dismiss   dismiss the picker
///
/// Registration is *scoped*: keys are registered only while the parent's
/// `eligible()` callback reports the Capy editor frontmost, and the
/// accept/move/dismiss keys additionally only while the panel is visible.
/// Carbon registration is global. Activation notifications and the timer
/// unregister asynchronously, so a focus change can briefly leave a shortcut
/// reserved in another app. Eligibility is checked again before any action.
///
/// `refreshHotkeyRegistration()` is the documented re-evaluation entry point.
/// The picker already calls it on an internal 0.5 s timer and on
/// `NSWorkspace.didActivateApplicationNotification`, so a parent timer is
/// optional. Call it immediately after eligibility changes to shorten the
/// unregister window. The eligible callback must be inexpensive and cached.
final class Picker: NSObject {

    // MARK: - Errors

    enum InstallError: Error, CustomStringConvertible {
        case alreadyInstalled
        case eventHandlerInstallFailed(OSStatus)

        var description: String {
            switch self {
            case .alreadyInstalled:
                return "Picker.install() was already called."
            case .eventHandlerInstallFailed(let status):
                return "InstallEventHandler failed with OSStatus \(status)."
            }
        }
    }

    // MARK: - Hotkey model

    /// Carbon hotkey ids. Every combo uses Ctrl+Option so it cannot collide
    /// with normal typing or with the editor's plain-key shortcuts.
    fileprivate enum HotkeyID: UInt32, CaseIterable {
        case trigger = 1       // Ctrl+Option+Space
        case accept1           // Ctrl+Option+1
        case accept2           // Ctrl+Option+2
        case accept3           // Ctrl+Option+3
        case moveUp            // Ctrl+Option+Up
        case moveDown          // Ctrl+Option+Down
        case acceptSelection   // Ctrl+Option+Return
        case dismiss           // Ctrl+Option+Esc

        var keyCode: UInt32 {
            switch self {
            case .trigger:         return UInt32(kVK_Space)
            case .accept1:         return UInt32(kVK_ANSI_1)
            case .accept2:         return UInt32(kVK_ANSI_2)
            case .accept3:         return UInt32(kVK_ANSI_3)
            case .moveUp:          return UInt32(kVK_UpArrow)
            case .moveDown:        return UInt32(kVK_DownArrow)
            case .acceptSelection: return UInt32(kVK_Return)
            case .dismiss:         return UInt32(kVK_Escape)
            }
        }

        var modifiers: UInt32 { UInt32(controlKey | optionKey) }
    }

    // MARK: - Callbacks (set by install)

    private var trigger: (() -> Void)?
    private var accept: ((Int) -> Void)?
    private var onDismiss: (() -> Void)?
    private var eligible: (() -> Bool)?

    // MARK: - State

    private var candidates: [String] = []
    private var selectedIndex = 0
    private var panelVisible = false
    private var showingList = false
    private var installed = false

    private var eventHandler: EventHandlerRef?
    private var registeredHotkeys: [HotkeyID: EventHotKeyRef] = [:]
    private var eligibilityTimer: Timer?
    private var activationObserver: NSObjectProtocol?

    private let panel = NonactivatingPanel()
    private let statusPanel = NonactivatingPanel()
    private var rowViews: [CandidateRowView] = []
    private var statusLabel: NSTextField!
    private var statusHideWork: DispatchWorkItem?


    // MARK: - Init

    override init() {
        super.init()
        buildStatusPanel()
    }

    deinit {
        if let observer = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        eligibilityTimer?.invalidate()
        for (_, ref) in registeredHotkeys { UnregisterEventHotKey(ref) }
        if let h = eventHandler { RemoveEventHandler(h) }
    }

    // MARK: - Public API

    /// Wires the picker up. Must be called once, on the main thread.
    ///
    /// - Parameters:
    ///   - trigger:  user pressed the "open/generate completions" combo.
    ///   - accept:   user accepted candidate at the given index into the array
    ///               last passed to `show(_:full:)`.
    ///   - dismiss:  user dismissed the picker (the picker hides itself first).
    ///   - eligible: called to decide whether the Capy editor is frontmost;
    ///               consulted before every registration refresh and again at
    ///               each hotkey press.
    func install(trigger: @escaping () -> Void,
                 accept: @escaping (Int) -> Void,
                 dismiss: @escaping () -> Void,
                 eligible: @escaping () -> Bool) throws {
        assert(Thread.isMainThread, "Picker.install() must be called on the main thread")
        guard !installed else { throw InstallError.alreadyInstalled }

        self.trigger = trigger
        self.accept = accept
        self.onDismiss = dismiss
        self.eligible = eligible

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(),
                                         capyPickerHotkeyProc,
                                         1, &spec,
                                         Unmanaged.passUnretained(self).toOpaque(),
                                         &eventHandler)
        guard status == noErr else {
            self.trigger = nil; self.accept = nil; self.onDismiss = nil; self.eligible = nil
            throw InstallError.eventHandlerInstallFailed(status)
        }
        installed = true

        // Eligibility can drift without any notification (Capy loses focus to
        // a menu, a dock icon click, …), so keep a cheap 0.5 s poll. A parent
        // timer calling refreshHotkeyRegistration() is equally sufficient;
        // both paths end in the same diff-based sync.
        eligibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshHotkeyRegistration()
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.refreshHotkeyRegistration() }

        refreshHotkeyRegistration()
    }

    /// Shows candidates near the Capy editor.
    /// - Parameter full: `false` renders a wrapped preview of the first
    ///   candidate; `true` renders the selectable list.
    func show(_ candidates: [String], full: Bool) {
        onMain { [self] in
            guard eligible?() == true else { hide(); return }
            guard !candidates.isEmpty else {
                hide()
                status("no candidates")
                return
            }
            self.candidates = candidates
            self.selectedIndex = 0
            self.showingList = full
            presentPanel()
            refreshHotkeyRegistration()
        }
    }

    /// Hides the panel. Eligible hotkeys reduce back to the trigger combo.
    func hide() {
        onMain { [self] in
            panel.orderOut(nil)
            panelVisible = false
            refreshHotkeyRegistration()
        }
    }

    /// Transient error feedback. Shown in a small HUD; auto-hides after 4 s.
    func status(_ message: String) {
        onMain { [self] in
            statusLabel.stringValue = message
            layoutStatusPanel()
            statusPanel.orderFrontRegardless()
            statusHideWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.statusPanel.orderOut(nil) }
            statusHideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
        }
    }

    /// Re-evaluates `eligible()` (and panel visibility) and synchronises the
    /// Carbon hotkey registrations to match: registers the missing combos,
    /// unregisters the ones no longer wanted. Documented for a parent-driven
    /// timer; the picker also calls it internally every 0.5 s, on every
    /// workspace activation change, and whenever the panel shows or hides.
    func refreshHotkeyRegistration() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refreshHotkeyRegistration() }
            return
        }
        guard installed else { return }
        var desired = Set<HotkeyID>()
        if eligible?() ?? false {
            desired.insert(.trigger)
            if panelVisible { desired.formUnion(HotkeyID.allCases) }
        }
        for id in HotkeyID.allCases where desired.contains(id) && registeredHotkeys[id] == nil {
            register(id)
        }
        for id in HotkeyID.allCases where !desired.contains(id) {
            if let ref = registeredHotkeys.removeValue(forKey: id) {
                UnregisterEventHotKey(ref)
            }
        }
        if !(eligible?() ?? false), panelVisible {
            panel.orderOut(nil)
            panelVisible = false
        }
    }

    // MARK: - Hotkey plumbing

    private func register(_ id: HotkeyID) {
        var ref: EventHotKeyRef?
        let err = RegisterEventHotKey(id.keyCode, id.modifiers,
                                      EventHotKeyID(signature: kPickerHotkeySignature, id: id.rawValue),
                                      GetApplicationEventTarget(), 0, &ref)
        if err == noErr {
            registeredHotkeys[id] = ref
        } else {
            status("hotkey registration failed (\(err))")
        }
    }

    /// Called on the main run loop by the Carbon event handler.
    fileprivate func handleHotkey(_ id: HotkeyID) {
        // Race guard: eligibility may have flipped since the last refresh.
        guard eligible?() ?? false else {
            refreshHotkeyRegistration()
            return
        }
        switch id {
        case .trigger:
            trigger?()
        case .accept1, .accept2, .accept3:
            let index = Int(id.rawValue) - Int(HotkeyID.accept1.rawValue)
            acceptCandidate(index)
        case .moveUp:
            moveSelection(-1)
        case .moveDown:
            moveSelection(+1)
        case .acceptSelection:
            acceptCandidate(selectedIndex)
        case .dismiss:
            hide()
            onDismiss?()
        }
    }

    private func acceptCandidate(_ index: Int) {
        guard panelVisible, eligible?() == true, candidates.indices.contains(index) else { return }
        accept?(index)
    }

    private func moveSelection(_ delta: Int) {
        guard panelVisible, showingList, !rowViews.isEmpty else { return }
        let count = rowViews.count
        selectRow((selectedIndex + delta + count) % count)
    }

    // MARK: - Panel presentation

    private func presentPanel() {
        guard let placement = panelPlacement() else { return }
        let bounds = placement.bounds
        let font = NSFont.systemFont(ofSize: 13)
        let displayed = showingList ? candidates : Array(candidates.prefix(1))
        let longest = displayed.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let width = min(bounds.width, 600, max(320, ceil(longest) + 84))
        let footer = hintLabel(showingList ? "⌃⌥1–3 insert · ⌃⌥↑↓ choose · ⌃⌥⏎ insert · ⌃⌥Esc dismiss" : "⌃⌥Space list · ⌃⌥1 insert · ⌃⌥Esc dismiss")
        let headerHeight: CGFloat = showingList ? 22 : 4
        let footerHeight: CGFloat = 24
        let document = FlippedDocument()
        rowViews.removeAll()
        let rowWidth = max(1, width - 28)
        var y: CGFloat = 0
        for (index, text) in displayed.enumerated() {
            let row = CandidateRowView()
            row.wantsLayer = true
            row.layer?.cornerRadius = 5
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = font
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            let badgeWidth: CGFloat = showingList ? 40 : 0
            let textWidth = max(1, rowWidth - 12 - badgeWidth)
            let textHeight = ceil(label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: .greatestFiniteMagnitude)).height)
            let height = max(22, textHeight + 8)
            row.frame = NSRect(x: 0, y: y, width: rowWidth, height: height)
            label.frame = NSRect(x: 6, y: 4, width: textWidth, height: height - 8)
            row.addSubview(label)
            if showingList {
                let badge = hintLabel("⌃⌥\(index + 1)")
                badge.frame = NSRect(x: rowWidth - badgeWidth, y: height - 19, width: badgeWidth, height: 16)
                row.addSubview(badge)
                row.onSelect = { [weak self] in self?.selectRow(index) }
                row.onAccept = { [weak self] in self?.acceptCandidate(index) }
            }
            document.addSubview(row)
            rowViews.append(row)
            y += height + 2
        }
        document.frame.size = NSSize(width: rowWidth, height: y)
        let viewport = min(y, max(1, floor(bounds.height * 0.60) - headerHeight - footerHeight))
        let size = NSSize(width: width, height: headerHeight + viewport + footerHeight)
        let effect = styledEffectView()
        effect.frame.size = size
        let scroll = NSScrollView(frame: NSRect(x: 8, y: footerHeight, width: width - 16, height: viewport))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = y > viewport
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        effect.addSubview(scroll)
        if showingList {
            let title = hintLabel("Completions")
            title.frame = NSRect(x: 12, y: size.height - headerHeight, width: width - 24, height: headerHeight - 2)
            effect.addSubview(title)
            updateRowHighlights()
        }
        footer.frame = NSRect(x: 12, y: 4, width: width - 24, height: footerHeight - 6)
        effect.addSubview(footer)
        panel.contentView = effect
        panel.setFrame(CGRect(origin: panelOrigin(size: size, placement: placement), size: size), display: true)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        panel.orderFrontRegardless()
        panelVisible = true
    }

    private func selectRow(_ index: Int) {
        guard eligible?() == true, rowViews.indices.contains(index) else { return }
        selectedIndex = index
        updateRowHighlights()
        let row = rowViews[index]
        row.scrollToVisible(NSRect(x: 0, y: max(0, row.bounds.height - 18), width: 1, height: 18))
    }

    // MARK: - Anchoring

    /// Best-effort anchor near the Capy editor, in screen (top-left-origin)
    /// coordinates: focused UI element → focused window → largest on-screen
    /// window of the frontmost app → mouse location.
    private func editorAnchor() -> CGRect? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let app = AXUIElementCreateApplication(front.processIdentifier)

        var focusedWindow: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
           let window = focusedWindow {
            let axWindow = window as! AXUIElement
            if let focused = copyAXElement(app, kAXFocusedUIElementAttribute),
               let frame = axFrame(focused) {
                return frame
            }
            return axFrame(axWindow)
        }
        return nil
    }

    private func copyAXElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let v = value else { return nil }
        return (v as! AXUIElement)
    }

    /// AX frames use top-left-origin screen coordinates.
    private func axFrame(_ element: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let posValue, let sizeValue else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Largest on-screen layer-0 window of the frontmost app, via window
    /// server bounds (available without Accessibility permission).
    private func frontmostWindowFrame() -> CGRect? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]] else { return nil }
        var best: CGRect?
        for info in infos {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let w = bounds["Width"], let h = bounds["Height"], w > 100, h > 100,
                  let x = bounds["X"], let y = bounds["Y"] else { continue }
            let f = CGRect(x: x, y: y, width: w, height: h)
            if f.width * f.height > (best?.width ?? 0) * (best?.height ?? 0) { best = f }
        }
        return best
    }

    private func panelPlacement() -> (anchor: CGRect, bounds: CGRect)? {
        guard let primary = NSScreen.screens.first else { return nil }
        let anchor: CGRect
        if let ax = editorAnchor() ?? frontmostWindowFrame() {
            anchor = CGRect(x: ax.minX, y: primary.frame.maxY - ax.maxY, width: ax.width, height: ax.height)
        } else {
            anchor = CGRect(origin: NSEvent.mouseLocation, size: CGSize(width: 1, height: 1))
        }
        let screen = NSScreen.screens.max { a, b in
            let left = a.frame.intersection(anchor), right = b.frame.intersection(anchor)
            return left.width * left.height < right.width * right.height
        } ?? primary
        return (anchor, screen.visibleFrame.insetBy(dx: 8, dy: 8))
    }

    private func panelOrigin(size: NSSize, placement: (anchor: CGRect, bounds: CGRect)) -> NSPoint {
        let (anchor, bounds) = placement
        let below = anchor.minY - size.height - 6
        let preferredY = below >= bounds.minY ? below : anchor.maxY + 6
        return NSPoint(x: min(max(anchor.minX, bounds.minX), bounds.maxX - size.width),
                       y: min(max(preferredY, bounds.minY), bounds.maxY - size.height))
    }

    // MARK: - Views

    private func styledEffectView() -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.state = .active
        v.blendingMode = .behindWindow
        v.wantsLayer = true
        v.layer?.cornerRadius = 9
        v.layer?.masksToBounds = true
        return v
    }

    private func hintLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 10)
        l.textColor = .tertiaryLabelColor
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    private func updateRowHighlights() {
        for (i, row) in rowViews.enumerated() {
            row.layer?.backgroundColor = (i == selectedIndex)
                ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).cgColor
                : NSColor.clear.cgColor
        }
    }

    // MARK: - Status HUD

    private func buildStatusPanel() {
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .systemRed
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        let effect = styledEffectView()
        effect.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -10),
            statusLabel.topAnchor.constraint(equalTo: effect.topAnchor, constant: 6),
            statusLabel.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -6),
        ])
        statusPanel.contentView = effect
    }

    private func layoutStatusPanel() {
        let size = statusPanel.contentView?.fittingSize ?? NSSize(width: 200, height: 24)
        let capped = NSSize(width: min(size.width, 480), height: size.height)
        var origin: NSPoint
        if panelVisible {
            let f = panel.frame
            origin = NSPoint(x: f.minX, y: f.maxY + 4)
        } else {
            origin = panelPlacement().map { panelOrigin(size: capped, placement: $0) } ?? .zero
        }
        statusPanel.setFrame(CGRect(origin: origin, size: capped), display: true)
    }

    // MARK: - Helpers

    /// The app's UI contract is main-thread only; callers are tolerated from
    /// other threads by hopping to main.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}

// MARK: - Carbon entry point

private let kPickerHotkeySignature: FourCharCode = 0x4350_4143 // 'CPAC'

private func capyPickerHotkeyProc(_ nextHandler: EventHandlerCallRef?,
                                  _ event: EventRef?,
                                  _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotkeyID = EventHotKeyID()
    let err = GetEventParameter(event, OSType(kEventParamDirectObject),
                                OSType(typeEventHotKeyID), nil,
                                MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)
    guard err == noErr,
          hotkeyID.signature == kPickerHotkeySignature,
          let id = Picker.HotkeyID(rawValue: hotkeyID.id) else {
        return OSStatus(eventNotHandledErr)
    }
    Unmanaged<Picker>.fromOpaque(userData).takeUnretainedValue().handleHotkey(id)
    return noErr
}

// MARK: - Supporting views

/// Borderless floating panel that never activates the app or takes keyboard
/// focus away from the Capy editor.
private final class NonactivatingPanel: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One selectable list row. The panel is nonactivating but still receives
/// mouse events, so single-click selects and double-click accepts.
private final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
}

private final class CandidateRowView: NSView {
    var onSelect: (() -> Void)?
    var onAccept: (() -> Void)?
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if event.clickCount >= 2 { onAccept?() } else { onSelect?() }
    }
}
