import AppKit
import ApplicationServices

@MainActor
final class Companion: NSObject, NSApplicationDelegate {
    private let editor = CapyEditor()
    private let catalog = ThreadSkillCatalog()
    private var offeredSkills: [ThreadSkill] = []
    private let picker = Picker()
    private var generator: Generator?
    private var timer: Timer?
    private var request: Task<Void, Never>?
    private var generation = 0
    private var current: EditorSnapshot?
    private var choices: [String] = []
    private var statusItem: NSStatusItem?
    private var enabled = true
    private var adHider: AdHider?
    private var adHideStatus: AdHider.Status = .starting
    private var lastError: String?
    private let diagnostics = ProcessInfo.processInfo.environment["CAPY_PROMPT_DIAGNOSTICS"] == "1"

    private func trace(_ event: String) {
        if diagnostics { FileHandle.standardError.write(Data((event + "\n").utf8)) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Capy ✎"
        item.button?.toolTip = "Capy Prompts"
        let menu = NSMenu()
        menu.addItem(withTitle: "Pause suggestions", action: #selector(toggle(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Capy Prompts", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
        let hider = AdHider(report: { [weak self] status in
            Task { @MainActor in self?.updateAdHideStatus(status) }
        }, diagnostic: { [weak self] message in
            Task { @MainActor in self?.trace(message) }
        })
        adHider = hider
        Task { await hider.start() }
        do {
            generator = try Generator()
            try picker.install(trigger: { [weak self] in self?.openList() }, accept: { [weak self] index in self?.accept(index) }, dismiss: { [weak self] in self?.invalidate() }, eligible: { [weak self] in self?.eligible == true })
        } catch {
            report(error.localizedDescription)
            return
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) { report("Allow Accessibility for Capy Prompts to use the Capy editor.") }
        let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private var eligible: Bool {
        enabled && current != nil && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "ai.capy.desktop"
    }

    private func report(_ message: String) {
        lastError = message
        statusItem?.button?.toolTip = tooltipText
        FileHandle.standardError.write(Data((message + "\n").utf8))
        picker.status(message)
    }

    private var tooltipText: String {
        let adStatus: String
        switch adHideStatus {
        case .active(let windows):
            adStatus = "Capy Prompts · hiding ads in \(windows) window\(windows == 1 ? "" : "s")"
        case .starting:
            adStatus = "Capy Prompts · hiding ads: attaching (0 windows hidden)"
        case .noDebugger:
            adStatus = "Capy Prompts · ad hide off: start Capy with a debug port on 127.0.0.1:9333"
        case .notCapy:
            adStatus = "Capy Prompts · ad hide off: port 9333 is not Capy"
        }
        return lastError.map { "\($0) · \(adStatus)" } ?? adStatus
    }

    private func updateAdHideStatus(_ status: AdHider.Status) {
        adHideStatus = status
        let text = tooltipText
        statusItem?.button?.toolTip = text
        trace("ad-hide \(text)")
    }

    @objc private func toggle(_ sender: NSMenuItem) {
        enabled.toggle()
        sender.title = enabled ? "Pause suggestions" : "Resume suggestions"
        invalidate()
        current = nil
    }

    private func invalidate() {
        generation += 1
        request?.cancel()
        request = nil
        choices.removeAll()
        offeredSkills.removeAll()
        picker.hide()
    }

    private func refresh() {
        guard enabled, let latest = editor.snapshot() else {
            if current != nil { invalidate(); current = nil; picker.refreshHotkeyRegistration() }
            return
        }
        if let current, current.matches(latest), current.context == latest.context { return }
        begin(latest, full: false)
    }

    private func openList() {
        guard enabled, let latest = editor.snapshot() else { return }
        begin(latest, full: true)
    }

    private func begin(_ snapshot: EditorSnapshot, full: Bool) {
        invalidate()
        current = snapshot
        picker.refreshHotkeyRegistration()
        guard let generator else { return }
        if snapshot.prefix.isEmpty && snapshot.suffix.isEmpty && snapshot.context.isEmpty {
            if full { picker.status("This thread has no conversation to suggest a next step from.") }
            return
        }
        if full { picker.status("Getting suggestions…") }
        let version = generation
        trace("request \(version) full=\(full) prefix=\(snapshot.prefix.count) suffix=\(snapshot.suffix.count) background=\(snapshot.context.count)")
        request = Task { [weak self] in
            do {
                if !full { try await Task.sleep(nanoseconds: 350_000_000) }
                guard let self, self.generation == version else { return }
                let skills = await self.readCatalog(for: snapshot.thread, refresh: full)
                try Task.checkCancellation()
                guard self.generation == version, let before = self.editor.snapshot(), snapshot.matches(before), snapshot.context == before.context else { return }
                let generated = try await generator.candidates(prefix: snapshot.prefix, suffix: snapshot.suffix, context: snapshot.context, full: full, skills: skills)
                try Task.checkCancellation()
                var confirmed = skills
                if generated.contains(where: { $0.contains("$") }) {
                    confirmed = await self.readCatalog(for: snapshot.thread, refresh: true)
                }
                let results = generated.filter { Generator.validSkillReferences(in: $0, skills: confirmed) }
                try Task.checkCancellation()
                guard self.generation == version, let live = self.editor.snapshot(), snapshot.matches(live), live.context == snapshot.context else { return }
                self.trace("response \(version) candidates=\(results.count)")
                self.choices = results
                self.offeredSkills = confirmed
                if results.isEmpty {
                    if full { self.picker.status("No suggestion for this draft.") } else { self.picker.hide() }
                } else {
                    self.picker.show(results, full: full)
                }
            } catch {
                guard !Task.isCancelled, let self, self.generation == version else { return }
                self.report(error.localizedDescription)
            }
        }
    }

    private func readCatalog(for thread: String, refresh: Bool) async -> [ThreadSkill] {
        do {
            let skills = try await catalog.skills(for: thread, refresh: refresh)
            trace("catalog entries=\(skills.count)")
            return skills
        } catch {
            if !Task.isCancelled { trace("catalog unavailable: \(error.localizedDescription)") }
            return []
        }
    }

    private func accept(_ index: Int) {
        guard enabled, choices.indices.contains(index), let current else { return }
        let text = choices[index]
        let skills = offeredSkills
        invalidate()
        do {
            guard let live = editor.snapshot(), current.matches(live), current.context == live.context else { return }
            try editor.insert(text, into: current, skills: skills)
            trace("accepted candidate \(index + 1)")
            self.current = editor.snapshot()
        } catch { report(error.localizedDescription) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        request?.cancel()
        adHider?.shutdown()
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let companion = Companion()
    application.delegate = companion
    withExtendedLifetime(companion) { application.run() }
}
