import Foundation

/// Continuously hides Gravity SponsoredCard ads inside Capy Desktop through the
/// Chrome DevTools Protocol endpoint on 127.0.0.1:9333.
///
/// The hider polls /json/version to confirm the debuggable app really is Capy,
/// then /json/list for capy:// page targets (one per window). Each target gets a
/// persistent WebSocket session that registers an idempotent stylesheet through
/// Page.addScriptToEvaluateOnNewDocument — so hiding survives reloads and in-app
/// navigation — and evaluates the same script once for the already-loaded
/// document. The session stays open to keep the registration valid; when a
/// window is replaced or a socket drops, the next poll attaches a fresh session.
/// A target only counts as hidden once both CDP calls succeeded and the
/// immediate evaluate reported no Runtime exception.
///
/// The injected script only appends a <style> element with the verified
/// sponsored-card selector. It never reads page content, and no URL, target id,
/// or page data is logged anywhere.
actor AdHider {
    /// Lifecycle states surfaced to the menu bar. Deliberately coarse — never
    /// carries page data.
    enum Status: Equatable, Sendable {
        case starting
        case active(windows: Int)
        case noDebugger
        case notCapy
    }

    private static let baseURL = URL(string: "http://127.0.0.1:9333")!
    private static let pollInterval: UInt64 = 2_500_000_000
    private static let keepAliveInterval: UInt64 = 45_000_000_000

    /// Idempotent: a window flag prevents stacked MutationObservers on repeated
    /// injection, and the <style> is keyed by element id. The :has() selector
    /// keeps matching as the SPA mounts new sponsored cards or crossfade
    /// leftovers, so no per-card DOM work is needed. The style is inserted only
    /// once document.head/document.documentElement exists.
    private static let installScript = #"""
    (() => {
      if (window.__capyPromptsAdHide) return;
      window.__capyPromptsAdHide = true;
      const ID = "capy-prompts-ad-hide";
      const install = () => {
        if (document.getElementById(ID)) return;
        const host = document.head || document.documentElement;
        if (!host) return;
        const style = document.createElement("style");
        style.id = ID;
        style.textContent = 'div.grid:has(> a[data-track-owner^="features/thread/gravity-ad.tsx#SponsoredCard:"]) { display: none !important }';
        host.appendChild(style);
      };
      install();
      new MutationObserver(install).observe(document, { childList: true, subtree: true });
    })();
    """#

    private enum ServeError: Error { case runtimeException }

    nonisolated let report: @Sendable (Status) -> Void
    nonisolated let diagnostic: @Sendable (String) -> Void
    private let bag = CancelBag()

    private var pollTask: Task<Void, Never>?
    private var sessions: [String: Task<Void, Never>] = [:]
    /// Per attach attempt: lets a dying session tell whether it still owns the
    /// target's map entry before clearing it.
    private var generations: [String: Int] = [:]
    private var nextGeneration = 0
    private var tokens: [String: Int] = [:]
    /// Targets whose registration + evaluate completed without exception.
    private var ready: Set<String> = []
    private var status: Status = .starting {
        didSet { if oldValue != status { report(status) } }
    }

    init(report: @escaping @Sendable (Status) -> Void,
         diagnostic: @escaping @Sendable (String) -> Void) {
        self.report = report
        self.diagnostic = diagnostic
    }

    func start() {
        guard pollTask == nil else { return }
        let task = Task { await self.pollLoop() }
        bag.add { task.cancel() }
        pollTask = task
    }

    /// Synchronous, thread-safe stop for application termination: cancels the
    /// poll loop and every live session. Cancelling a session task runs its
    /// defer, which closes the WebSocket and its URLSession.
    nonisolated func shutdown() { bag.cancelAll() }

    // MARK: - Poll loop

    private func pollLoop() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        let http = URLSession(configuration: configuration)
        defer { http.invalidateAndCancel() }
        while !Task.isCancelled {
            await sweep(http: http)
            try? await Task.sleep(nanoseconds: Self.pollInterval)
        }
    }

    private func sweep(http: URLSession) async {
        let versionURL = Self.baseURL.appending(path: "json/version")
        guard let (versionData, _) = try? await http.data(from: versionURL) else {
            dropAll()
            status = .noDebugger
            return
        }
        let body = String(data: versionData, encoding: .utf8) ?? ""
        guard body.range(of: "capy", options: .caseInsensitive) != nil else {
            dropAll()
            status = .notCapy
            return
        }
        let listURL = Self.baseURL.appending(path: "json/list")
        guard let (listData, _) = try? await http.data(from: listURL),
              let items = try? JSONSerialization.jsonObject(with: listData) as? [[String: Any]] else {
            dropAll()
            status = .noDebugger
            return
        }
        let wanted = items.filter {
            ($0["type"] as? String) == "page" &&
                ($0["url"] as? String ?? "").hasPrefix("capy://")
        }
        let liveIDs = Set(wanted.compactMap { $0["id"] as? String })
        for (id, session) in sessions where !liveIDs.contains(id) {
            session.cancel()
            sessions[id] = nil
            generations[id] = nil
            ready.remove(id)
            if let token = tokens.removeValue(forKey: id) { bag.remove(token) }
        }
        for target in wanted {
            guard let id = target["id"] as? String,
                  sessions[id] == nil,
                  let raw = target["webSocketDebuggerUrl"] as? String,
                  let wsURL = URL(string: raw),
                  Self.isLoopbackEndpoint(wsURL)
            else { continue }
            nextGeneration += 1
            let generation = nextGeneration
            let session = Task { [weak self] in
                guard let self else { return }
                await self.serve(ws: wsURL, id: id)
                await self.finish(id, generation: generation)
            }
            sessions[id] = session
            generations[id] = generation
            tokens[id] = bag.add { session.cancel() }
        }
        refreshStatus()
    }

    /// Refuse debugger endpoints pointing anywhere but loopback:9333 — a
    /// surprised endpoint must never be able to redirect the session outside.
    private static func isLoopbackEndpoint(_ url: URL) -> Bool {
        guard url.port == 9333 else { return false }
        switch url.host {
        case "127.0.0.1", "localhost", "::1", "[::1]": return true
        default: return false
        }
    }

    private func refreshStatus() {
        status = ready.isEmpty ? .starting : .active(windows: ready.count)
    }

    private func dropAll() {
        for (id, session) in sessions {
            session.cancel()
            if let token = tokens.removeValue(forKey: id) { bag.remove(token) }
        }
        sessions.removeAll()
        generations.removeAll()
        ready.removeAll()
    }

    private func finish(_ id: String, generation: Int) {
        // A cancelled old session must not clear a replacement attach.
        guard generations[id] == generation else { return }
        sessions[id] = nil
        generations[id] = nil
        ready.remove(id)
        if let token = tokens.removeValue(forKey: id) { bag.remove(token) }
        guard !Task.isCancelled else { return }
        refreshStatus()
    }

    // MARK: - Per-target session

    private func serve(ws url: URL, id: String) async {
        let pipe = Pipe(url: url)
        defer { pipe.close() }
        do {
            pipe.open()
            _ = try await pipe.call("Page.enable")
            _ = try await pipe.call("Page.addScriptToEvaluateOnNewDocument",
                                    ["source": Self.installScript])
            let result = try await pipe.call("Runtime.evaluate",
                                             ["expression": Self.installScript,
                                              "returnByValue": true])
            guard result["exceptionDetails"] == nil else { throw ServeError.runtimeException }
            ready.insert(id)
            refreshStatus()
            try await pipe.holdOpen(ping: {
                _ = try await pipe.call("Runtime.evaluate", ["expression": "1"])
            }, interval: Self.keepAliveInterval)
        } catch is CancellationError {
            // Shutdown or the window was replaced; nothing to report.
        } catch ServeError.runtimeException {
            if !Task.isCancelled {
                diagnostic("ad-hide: evaluate raised a Runtime exception; reconnecting")
            }
        } catch {
            if !Task.isCancelled {
                diagnostic("ad-hide: session dropped (\(error.localizedDescription))")
            }
        }
    }
}

// MARK: - WebSocket pipe

/// One CDP WebSocket session: serial request ids, a single receive pump that
/// resolves pending replies or surfaces protocol errors, and a closed signal so
/// the owner can hold the session open.
final class Pipe: @unchecked Sendable {
    private enum Failure: Error, LocalizedError {
        case closed
        case remote(String)

        var errorDescription: String? {
            switch self {
            case .closed: return "socket closed"
            case .remote(let message): return message
            }
        }
    }

    private let session = URLSession(configuration: .ephemeral)
    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var counter = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var onClose: CheckedContinuation<Void, Error>?
    private var terminalError: Error?
    private var pump: Task<Void, Never>?

    init(url: URL) {
        task = session.webSocketTask(with: url)
    }

    func open() {
        task.resume()
        pump = Task { [weak self] in await self?.pumpMessages() }
    }

    func close() {
        pump?.cancel()
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
        fail(Failure.closed)
    }

    func call(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        let id = lock.withLock { counter += 1; return counter }
        var envelope: [String: Any] = ["id": id, "method": method]
        if !params.isEmpty { envelope["params"] = params }
        let data = try JSONSerialization.data(withJSONObject: envelope)
        let body = String(decoding: data, as: UTF8.self)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let terminal = lock.withLock { () -> Error? in
                    if let terminalError { return terminalError }
                    pending[id] = continuation
                    return nil
                }
                if let terminal {
                    continuation.resume(throwing: terminal)
                    return
                }
                if Task.isCancelled {
                    drop(id: id, throwing: CancellationError())
                    return
                }
                Task {
                    do { try await task.send(.string(body)) }
                    catch { self.fail(error) }
                }
            }
        } onCancel: {
            drop(id: id, throwing: CancellationError())
        }
    }

    /// Blocks until the socket dies or the keepalive fails — whichever first —
    /// keeping the addScriptToEvaluateOnNewDocument registration alive.
    func holdOpen(ping: @escaping @Sendable () async throws -> Void,
                  interval: UInt64) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer {
                group.cancelAll()
                close()
            }
            group.addTask { [self] in try await waitUntilClosed() }
            group.addTask {
                while true {
                    try await Task.sleep(nanoseconds: interval)
                    try await ping()
                }
            }
            try await group.next()
        }
    }

    private func waitUntilClosed() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let terminal = lock.withLock { () -> Error? in
                    if let terminalError { return terminalError }
                    onClose = continuation
                    return nil
                }
                if let terminal { continuation.resume(throwing: terminal) }
            }
        } onCancel: {
            close()
        }
    }

    private func pumpMessages() async {
        do {
            while true {
                let message = try await task.receive()
                guard case .string(let text) = message,
                      let data = text.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                guard let id = object["id"] as? Int else { continue }
                let continuation = lock.withLock { pending.removeValue(forKey: id) }
                if let error = object["error"] as? [String: Any] {
                    continuation?.resume(throwing: Failure.remote(error["message"] as? String ?? "CDP error"))
                } else {
                    continuation?.resume(returning: object["result"] as? [String: Any] ?? [:])
                }
            }
        } catch {
            fail(error)
        }
    }

    private func drop(id: Int, throwing error: Error) {
        lock.withLock { pending.removeValue(forKey: id) }?.resume(throwing: error)
    }

    private func fail(_ error: Error) {
        let (calls, closing, terminal) = lock.withLock {
            let terminal = terminalError ?? error
            terminalError = terminal
            let calls = Array(pending.values)
            pending.removeAll()
            let closing = onClose
            onClose = nil
            return (calls, closing, terminal)
        }
        calls.forEach { $0.resume(throwing: terminal) }
        closing?.resume(throwing: terminal)
    }
}

// MARK: - Cancel bag

/// Thread-safe registry of cancel closures so `shutdown()` can run without
/// actor isolation during application termination.
private final class CancelBag: @unchecked Sendable {
    private let lock = NSLock()
    private var nextToken = 0
    private var cancels: [Int: () -> Void] = [:]

    @discardableResult
    func add(_ cancel: @escaping () -> Void) -> Int {
        lock.withLock {
            nextToken += 1
            cancels[nextToken] = cancel
            return nextToken
        }
    }

    func remove(_ token: Int) {
        lock.withLock { cancels[token] = nil }
    }

    func cancelAll() {
        let all = lock.withLock {
            let all = Array(cancels.values)
            cancels.removeAll()
            return all
        }
        all.forEach { $0() }
    }
}
