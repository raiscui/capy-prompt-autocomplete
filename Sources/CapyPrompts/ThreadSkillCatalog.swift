import Foundation

/// Read-only view of a Capy thread's skill catalog over the existing CDP
/// loopback transport (`Pipe`, 127.0.0.1:9333).
///
/// `skills(for:refresh:)` resolves the live page target whose URL is exactly
/// `capy://app/thread/<thread>`, opens a WebSocket to that target's own
/// debugger URL (accepted only on ws://127.0.0.1:9333), and asks the focused,
/// on-screen Message editor for the `memoizedProps.sources` entries whose
/// `category` is `"skills"` through the picker's own empty `search("")`. The
/// draft may hold text; nothing is typed, injected, persisted, or logged, and
/// no menu is opened. The route and the focused editor are rechecked around
/// every await; redirects are refused, so a foreign endpoint, an ambiguous
/// focus, an exception, or a timeout fails closed instead of returning data
/// from the wrong place.
actor ThreadSkillCatalog {
    /// Why a catalog read failed. Never carries page content.
    enum Failure: Error, Equatable, LocalizedError {
        /// The loopback endpoint is unreachable, timed out, or is not Capy.
        case noDebugger
        /// No page target is exactly `capy://app/thread/<id>`.
        case noSuchThread
        /// The page answered a diagnostic instead of a catalog (editor not
        /// focused, source still settling, missing internals after an upgrade).
        case notReady(String)
        /// More than one page claims the focused editor for this thread.
        case ambiguous
        /// A single CDP round trip exceeded its budget.
        case timeout
        /// CDP transport or evaluation error text.
        case remote(String)

        var errorDescription: String? {
            switch self {
            case .noDebugger:
                return "The Capy debug endpoint on 127.0.0.1:9333 is not reachable."
            case .noSuchThread:
                return "No Capy window is showing this thread."
            case .notReady(let detail):
                return "The thread's skill catalog is not readable right now (\(detail))."
            case .ambiguous:
                return "More than one Capy window claims the focused editor for this thread."
            case .timeout:
                return "Reading the skill catalog timed out."
            case .remote(let detail):
                return "The skill catalog could not be read: \(detail)."
            }
        }
    }

    private static let baseURL = URL(string: "http://127.0.0.1:9333")!
    private static let httpTimeout: TimeInterval = 4
    private static let evaluateTimeout: TimeInterval = 8
    private static let cacheLifetime: TimeInterval = 45
    private static let cacheCapacity = 12

    private var cache: SkillCache

    init(lifetime: TimeInterval = ThreadSkillCatalog.cacheLifetime,
         capacity: Int = ThreadSkillCatalog.cacheCapacity) {
        cache = SkillCache(lifetime: lifetime, capacity: capacity)
    }

    /// The thread's picker catalog, served from a bounded cache while an entry
    /// is younger than `lifetime` — pass `refresh: true` to bypass and replace
    /// it. Only reads that actually completed are cached, including an empty
    /// catalog; timeouts and cancellation never return a stale entry.
    func skills(for thread: String, refresh: Bool = false) async throws -> [ThreadSkill] {
        guard !thread.isEmpty else { throw Failure.noSuchThread }
        if !refresh, let cached = cache.skills(for: thread, at: Date()) {
            return cached
        }
        let result = try await fetch(thread: thread)
        try Task.checkCancellation()
        cache.store(result, for: thread, at: Date())
        return result
    }

    // MARK: - Page resolution

    private func fetch(thread: String) async throws -> [ThreadSkill] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.httpTimeout
        configuration.timeoutIntervalForResource = Self.httpTimeout
        let http = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { http.invalidateAndCancel() }

        let versionData: Data
        do {
            versionData = try await http.data(from: Self.baseURL.appending(path: "json/version")).0
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw Failure.noDebugger
        }
        guard String(decoding: versionData, as: UTF8.self)
            .range(of: "capy", options: .caseInsensitive) != nil else { throw Failure.noDebugger }

        let listData: Data
        do {
            listData = try await http.data(from: Self.baseURL.appending(path: "json/list")).0
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw Failure.noDebugger
        }
        guard let items = try? JSONSerialization.jsonObject(with: listData) as? [[String: Any]] else {
            throw Failure.noDebugger
        }
        var sockets: [URL] = []
        for item in items where Self.matches(item, thread: thread) {
            if let url = Self.socketURL(item) { sockets.append(url) }
        }
        guard !sockets.isEmpty else { throw Failure.noSuchThread }

        // Two windows can be on the same thread URL; only the one whose
        // document actually holds focus may answer. A probe that fails for any
        // reason (dead socket, menu open, hidden editor) is skipped so a
        // leftover target cannot veto the live one.
        if sockets.count > 1 {
            var winners: [URL] = []
            for url in sockets where (try? await probe(url, thread: thread)) == true {
                winners.append(url)
            }
            guard winners.count == 1, let only = winners.first else {
                throw winners.isEmpty ? Failure.notReady("no focused editor") : Failure.ambiguous
            }
            sockets = [only]
        }
        return try await catalog(sockets[0], thread: thread)
    }

    /// Whether this page's document is focused on a visible Message editor for
    /// `thread`. Used only to disambiguate duplicate thread targets.
    private func probe(_ url: URL, thread: String) async throws -> Bool {
        let pipe = Pipe(url: url)
        defer { pipe.close() }
        pipe.open()
        let answer = try await evaluate(pipe, expression: Self.probeScript(thread: thread), awaitPromise: false)
        return answer as? Bool ?? false
    }

    /// The catalog read itself: one evaluate whose script walks the focused
    /// editor's committed React fiber ancestors, waits out `settling()` with a
    /// bound, rechecks `failure()`, the route and the focused editor around
    /// each `search("")` await, then returns rows or a diagnostic string.
    private func catalog(_ url: URL, thread: String) async throws -> [ThreadSkill] {
        let pipe = Pipe(url: url)
        defer { pipe.close() }
        pipe.open()
        let answer = try await evaluate(pipe, expression: Self.catalogScript(thread: thread), awaitPromise: true)
        if let detail = answer as? String { throw Failure.notReady(detail) }
        guard let rows = answer as? [[String: Any]] else {
            throw Failure.remote("unexpected catalog reply")
        }
        return rows.compactMap { row in
            guard let name = row["name"] as? String, !name.isEmpty else { return nil }
            return ThreadSkill(name: name, description: row["description"] as? String ?? "")
        }
    }

    private func evaluate(_ pipe: Pipe, expression: String, awaitPromise: Bool) async throws -> Any? {
        let result = try await Self.timed(Self.evaluateTimeout) {
            try await pipe.call("Runtime.evaluate", [
                "expression": expression,
                "returnByValue": true,
                "awaitPromise": awaitPromise,
            ])
        }
        if let exception = result["exceptionDetails"] as? [String: Any] {
            throw Failure.remote(exception["text"] as? String ?? "evaluation raised an exception")
        }
        return (result["result"] as? [String: Any])?["value"]
    }

    /// Abandons `work` after `seconds` so a stalled socket cannot hold a read
    /// open forever; the losing side of the race is cancelled.
    private static func timed<T>(_ seconds: TimeInterval,
                                 _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw Failure.timeout
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw Failure.timeout }
            return value
        }
    }

    // MARK: - Target validation

    /// A `/json/list` entry is a candidate only when it is a page whose URL is
    /// exactly `capy://app/thread/<thread>` — the capy scheme, the app host, no
    /// credentials or port, and a two-segment path ending in the thread id.
    static func matches(_ target: [String: Any], thread: String) -> Bool {
        guard (target["type"] as? String) == "page",
              let raw = target["url"] as? String,
              let url = URL(string: raw),
              url.scheme == "capy",
              url.host == "app",
              url.port == nil,
              url.user == nil,
              url.password == nil else { return false }
        let path = url.path
        guard path.hasPrefix("/thread/") else { return false }
        let segment = path.dropFirst("/thread/".count)
        return !segment.isEmpty && !segment.contains("/") && segment == thread
    }

    /// The page's debugger socket, accepted only on ws://127.0.0.1:9333 — a
    /// surprised endpoint must never hand the session a foreign host.
    static func socketURL(_ target: [String: Any]) -> URL? {
        guard let raw = target["webSocketDebuggerUrl"] as? String,
              let url = URL(string: raw),
              url.scheme == "ws",
              url.host == "127.0.0.1",
              url.port == 9333,
              url.user == nil,
              url.password == nil else { return nil }
        return url
    }

    private static func jsonLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return text
    }

    // MARK: - Read-only page scripts

    /// Synchronous probe: the page is on this thread's route, the focused
    /// element is a visible Message editor (not inside an aria-hidden subtree,
    /// geometrically hittable at the center of its visible region), and the
    /// document holds window focus.
    private static func probeScript(thread: String) -> String {
        """
        (() => {
          const tid = \(jsonLiteral(thread));
          if (location.protocol !== "capy:" || location.hostname !== "app") return false;
          const parts = location.pathname.split("/").filter(Boolean);
          if (parts.length !== 2 || parts[0] !== "thread") return false;
          try { if (decodeURIComponent(parts[1]) !== tid) return false; }
          catch (e) { if (parts[1] !== tid) return false; }
          const editor = [...document.querySelectorAll('[contenteditable="true"][aria-label="Message"]')]
            .filter(e => !e.closest('[aria-hidden="true"]'))
            .find(e => document.activeElement === e);
          if (!editor) return false;
          const r = editor.getBoundingClientRect();
          const x0 = Math.max(r.left, 0), y0 = Math.max(r.top, 0);
          const w = Math.min(r.right, innerWidth) - x0, h = Math.min(r.bottom, innerHeight) - y0;
          if (!(w > 0 && h > 0)) return false;
          const hit = document.elementFromPoint(x0 + w / 2, y0 + h / 2);
          if (!hit || !(hit === editor || editor.contains(hit))) return false;
          return document.hasFocus();
        })()
        """
    }

    /// Async read: returns [{name, description}] in picker order, or a short
    /// diagnostic string when the read cannot complete safely. Reads only
    /// `memoizedProps.sources` on the committed fiber chain — never the wider
    /// React state, credentials, drafts, or other threads.
    private static func catalogScript(thread: String) -> String {
        """
        (async () => {
          const tid = \(jsonLiteral(thread));
          const sleep = ms => new Promise(r => setTimeout(r, ms));
          const routeOk = () => {
            if (location.protocol !== "capy:" || location.hostname !== "app") return false;
            const parts = location.pathname.split("/").filter(Boolean);
            if (parts.length !== 2 || parts[0] !== "thread") return false;
            try { return decodeURIComponent(parts[1]) === tid; }
            catch (e) { return parts[1] === tid; }
          };
          if (!routeOk()) return "route";
          const candidates = () => [...document.querySelectorAll('[contenteditable="true"][aria-label="Message"]')]
            .filter(e => !e.closest('[aria-hidden="true"]'));
          const visible = e => {
            const r = e.getBoundingClientRect();
            const x0 = Math.max(r.left, 0), y0 = Math.max(r.top, 0);
            const w = Math.min(r.right, innerWidth) - x0, h = Math.min(r.bottom, innerHeight) - y0;
            if (!(w > 0 && h > 0)) return false;
            const hit = document.elementFromPoint(x0 + w / 2, y0 + h / 2);
            return !!hit && (hit === e || e.contains(hit));
          };
          const activeEditor = () => candidates().find(e => document.activeElement === e && visible(e));
          const box = activeEditor();
          if (!box) return "no-editor";
          const fiberKey = Object.keys(box).find(k => k.startsWith("__reactFiber$"));
          if (!fiberKey) return "no-fiber";
          const resolveProvider = () => {
            const chain = [];
            for (let node = box[fiberKey]; node; node = node.return) chain.push(node);
            const root = chain.pop();
            if (!root || !root.stateNode || !root.stateNode.current) return null;
            let current = root.stateNode.current;
            if (current !== root && current !== root.alternate) return null;
            const providers = new Set();
            const collect = node => {
              const sources = node.memoizedProps && node.memoizedProps.sources;
              if (Array.isArray(sources)) {
                for (const source of sources) {
                  if (source && source.category === "skills") providers.add(source);
                }
              }
            };
            collect(current);
            while (chain.length) {
              const original = chain.pop();
              let child = current.child;
              while (child && child !== original && child !== original.alternate) child = child.sibling;
              if (!child) return null;
              current = child;
              collect(current);
            }
            if (providers.size !== 1) return null;
            const source = providers.values().next().value;
            return typeof source.search === "function" && typeof source.settling === "function" &&
              typeof source.failure === "function" ? source : null;
          };
          const stillHere = () => routeOk() && document.hasFocus() && activeEditor() === box;
          let source;
          for (let attempt = 0; ; attempt++) {
            if (!stillHere()) return "editor-moved";
            source = resolveProvider();
            if (!source) return "no-unique-skills-source";
            if (source.failure()) return "source-failure";
            if (!source.settling()) break;
            if (attempt >= 25) return "settling";
            await sleep(200);
          }
          if (!stillHere() || resolveProvider() !== source) return "provider-changed";
          let found;
          try { found = await source.search(""); }
          catch (e) { return "search-failed"; }
          if (!stillHere() || resolveProvider() !== source) return "provider-changed";
          if (source.failure() || source.settling()) return "source-not-ready";
          if (!Array.isArray(found)) return "invalid-catalog";
          const items = [];
          for (const item of found) {
            if (!item || item.kind !== "skill") continue;
            const name = typeof item.label === "string" && item.label ? item.label
              : (typeof item.id === "string" ? item.id : "");
            if (!name) continue;
            items.push({ name, description: typeof item.subtitle === "string" ? item.subtitle : "" });
          }
          return items;
        })()
        """
    }
}

/// Bounded per-thread memo of completed catalog reads. Only results actually
/// returned to a caller are stored — including an empty catalog — and entries
/// expire `lifetime` seconds after they were read. At most `capacity` threads
/// are kept, evicting the oldest first.
struct SkillCache {
    private var entries: [String: (skills: [ThreadSkill], storedAt: Date)] = [:]
    private var order: [String] = []
    private let lifetime: TimeInterval
    private let capacity: Int

    init(lifetime: TimeInterval, capacity: Int) {
        self.lifetime = lifetime
        self.capacity = capacity
    }

    func skills(for thread: String, at now: Date) -> [ThreadSkill]? {
        guard let entry = entries[thread],
              now.timeIntervalSince(entry.storedAt) < lifetime else { return nil }
        return entry.skills
    }

    mutating func store(_ skills: [ThreadSkill], for thread: String, at now: Date) {
        if entries[thread] == nil {
            order.append(thread)
            while order.count > capacity {
                let evicted = order.removeFirst()
                entries.removeValue(forKey: evicted)
            }
        }
        entries[thread] = (skills, now)
    }
}

/// Refuses every redirect: the only endpoint this session may touch is the one
/// constructed in code, and following a Location header would hand control to
/// whatever answered the port.
private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
