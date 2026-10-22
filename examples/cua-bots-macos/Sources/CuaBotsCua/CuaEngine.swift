// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import Cua
import CuaBotsCore
import CuaSpaces
import Foundation

/// A custom model endpoint for every bot (`agent_start`'s `base_url`,
/// `model` and `env_from_host`). Unset: each harness's own default and the
/// provider key from this process's environment.
public struct ModelEndpoint: Sendable {
    public var baseURL: String
    public var model: String?
    public var keyVariables: [String]

    public init(baseURL: String, model: String? = nil, keyVariables: [String]) {
        self.baseURL = baseURL
        self.model = model
        self.keyVariables = keyVariables
    }

    /// `CUA_BOTS_MODEL_URL`, `CUA_BOTS_MODEL` and `CUA_BOTS_MODEL_KEY_VARS`
    /// (comma-separated; default `ANTHROPIC_API_KEY,OPENAI_API_KEY`).
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> ModelEndpoint? {
        guard let url = env["CUA_BOTS_MODEL_URL"], !url.isEmpty else { return nil }
        let vars = (env["CUA_BOTS_MODEL_KEY_VARS"] ?? "ANTHROPIC_API_KEY,OPENAI_API_KEY")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return ModelEndpoint(baseURL: url, model: env["CUA_BOTS_MODEL"], keyVariables: vars)
    }
}

/// The engine on the cua SDK: each bot gets its own Space (`bot-<name>`), its
/// Volume home is copied into the Space before the agent starts and back after
/// every turn, and pause suspends the Space.
///
/// With `persistentAgents` each bot is a `cua daemon` persistent agent named
/// after it (`Spaces.persistentAgentCreate`): turns go through
/// `persistentAgentSend`, its home lives in the Cua Volume, the daemon fires
/// its routines and posts its notifications, and pause and resume are
/// `agentPause` and `agentResume`.
@MainActor
public final class CuaEngine: BotEngine {
    public let cua: Cua
    public let connection: SpacesConnection
    public let persistentAgents: Bool
    public var endpoint: ModelEndpoint?
    /// The image a new bot's computer runs (`Image.linux()` by default).
    public var image: String?
    /// Also suspend a paused bot's Space (local Spaces only). Off by default:
    /// a paused bot keeps its computer up so the phone can still resume it.
    public var suspendOnPause = false

    private var homes: [String: String] = [:]
    private var clients: [String: SpacesdClient] = [:]
    private var turnText: [String: (turn: UInt32, text: String)] = [:]

    public init(cua: Cua, endpoint: ModelEndpoint? = ModelEndpoint.fromEnvironment(), persistentAgents: Bool = false) {
        self.cua = cua
        self.connection = SpacesConnection(cua: cua)
        self.endpoint = endpoint
        self.persistentAgents = persistentAgents
    }

    // MARK: - Spaces

    public func provision(_ bot: Bot, progress: @escaping @MainActor (EnginePhase) -> Void) async throws -> String {
        progress(.creatingSpace(bot.placement == .local ? "Creating a Space on this Mac"
            : bot.placement == .cloud ? "Creating a Cua Cloud Space" : "Creating a Space on \(bot.placement.name)"))
        let options = SpaceCreateOptions(
            image: try image ?? Image.linux(), on: bot.placement.rawValue, kind: "container", runtime: nil,
            name: bot.spaceName, cpus: nil, memoryMb: nil, diskGb: nil, timeoutMs: nil, wait: true,
            reuse: true, command: nil, env: [:], services: [:], spacesd: nil)
        let result = try await cua.spaces().create(options: options)
        guard let info = result.space else {
            throw EngineError.notReady("the Space is still being created (\(result.pendingId ?? "pending"))")
        }
        progress(.startingAgent)
        return info.id
    }

    /// The generated Space handle for a bot.
    public func space(_ bot: Bot) async throws -> CuaSDK.Space {
        guard let id = bot.spaceID else { throw EngineError.noSpace(bot.name) }
        return try await cua.spaces().space(space: id)
    }

    /// The overlay handle, for the live stream and PiP.
    public func streamSpace(_ bot: Bot) async throws -> CuaSpaces.Space {
        guard let id = bot.spaceID else { throw EngineError.noSpace(bot.name) }
        return try await connection.attach(to: SpaceID(id))
    }

    /// Your computers that provide Spaces, for "where it runs".
    public func hosts() async throws -> [SpacesHost] {
        try await cua.spaces().hosts()
    }

    /// Where the bot's home lives inside its Space (a persistent agent's is
    /// where the daemon restores it).
    public func home(_ bot: Bot, _ space: CuaSDK.Space) async throws -> String {
        if let h = homes[bot.id] { return h }
        let guest = (try? await space.home()) ?? "/home/cua"
        let h = persistentAgents ? "\(guest)/cua-volume/agents/\(bot.id)" : "\(guest)/bots/\(bot.id)"
        homes[bot.id] = h
        return h
    }

    // MARK: - Runs

    public func start(_ bot: Bot, volume: VolumeStore, prompt: String) async throws -> String {
        if persistentAgents { return try await startPersistent(bot, volume: volume, prompt: prompt) }
        let space = try await space(bot)
        let home = try await home(bot, space)
        try await hydrate(bot, volume: volume, space: space, home: home)
        // #region docs:sw-agent-start
        let options = SpaceAgentOptions(
            envFromHost: endpoint?.keyVariables ?? Self.defaultKeyVariables(bot.harness),
            repo: nil, branch: nil, cwd: home, model: endpoint?.model, baseUrl: endpoint?.baseURL,
            exitWhenIdle: false)
        let report = try await space.agentStart(agent: bot.harness.rawValue, prompt: prompt, show: false,
                                                options: options)
        // #endregion docs:sw-agent-start
        return report.runId
    }

    static func defaultKeyVariables(_ harness: Harness) -> [String] {
        switch harness {
        case .claudeCode: ["ANTHROPIC_API_KEY"]
        case .codex: ["OPENAI_API_KEY"]
        case .hermes, .openclaw: ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY"]
        }
    }

    public func send(_ bot: Bot, text: String) async throws {
        if persistentAgents {
            _ = try await cua.spaces().persistentAgentSend(name: bot.id, text: text)
            return
        }
        guard let run = bot.runID else { throw EngineError.noRun(bot.name) }
        // #region docs:sw-agent-message
        let report = try await space(bot).agentMessage(runId: run, text: text, force: false)
        if !report.ok { throw EngineError.refused(report.reason) }
        // #endregion docs:sw-agent-message
    }

    public func poll(_ bot: Bot, cursor: UInt64) async throws -> (updates: [EngineUpdate], cursor: UInt64) {
        if persistentAgents,
           let current = try await cua.spaces().persistentAgents().first(where: { $0.name == bot.id })?.runId,
           current != bot.runID {
            // The daemon started this run (a routine) or a fresh one.
            turnText[bot.id] = nil
            return ([.run(current)], 0)
        }
        guard let run = bot.runID else { return ([], cursor) }
        let json = try await space(bot).agentEvents(runId: run, cursor: cursor, max: 500)
        let page = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
        let events = page["events"] as? [[String: Any]] ?? []
        var updates: [EngineUpdate] = []
        for e in events {
            let kind = e["kind"] as? String ?? ""
            let turn = UInt32((e["turn"] as? NSNumber)?.intValue ?? 0)
            switch kind {
            case "message":
                let chunk = e["text"] as? String ?? ""
                var current = turnText[bot.id] ?? (turn, "")
                if current.turn != turn { current = (turn, "") }
                current.text += chunk
                turnText[bot.id] = current
                updates.append(.assistant(turn: turn, text: current.text))
            case "tool_call":
                updates.append(.tool(turn: turn, title: e["tool_title"] as? String ?? "Working"))
            case "turn_ended":
                updates.append(.turnEnded(turn: turn))
                turnText[bot.id] = nil
            case "error":
                updates.append(.failed(e["text"] as? String ?? "The agent reported an error"))
            case "exited":
                updates.append(.failed("The agent stopped: \(e["text"] as? String ?? "exited")"))
            default:
                break
            }
        }
        let next = (page["cursor"] as? NSNumber)?.uint64Value ?? cursor
        return (updates, next)
    }

    public func interrupt(_ bot: Bot) async throws {
        guard let run = bot.runID else { return }
        _ = try await space(bot).agentInterrupt(runId: run)
    }

    // MARK: - The Volume home

    /// Copy `agents/<name>/` from the Volume into the Space.
    func hydrate(_ bot: Bot, volume: VolumeStore, space: CuaSDK.Space, home: String) async throws {
        let prefix = VolumeLayout.home(bot.id)
        for entry in try volume.walk(prefix) {
            guard let data = try volume.read(entry.path) else { continue }
            let rel = String(entry.path.dropFirst(prefix.count))
            if rel.hasPrefix("identity/") { continue }  // the app's records, not the bot's
            _ = try await space.write(path: "\(home)/\(rel)", content: data)
        }
        _ = try await space.bash(command: "mkdir -p '\(home)/outputs' '\(home)/inbox' '\(home)/memory'", timeoutMs: 10_000)
    }

    public func push(_ bot: Bot, volume: VolumeStore) async throws {
        let space = try await space(bot)
        let home = try await home(bot, space)
        let prefix = VolumeLayout.home(bot.id)
        var paths = [VolumeLayout.instructions(bot.id, harness: bot.harness), VolumeLayout.rules(bot.id)]
        if persistentAgents, let p = VolumeLayout.persistentInstructions(bot.id, harness: bot.harness) { paths.append(p) }
        paths += try volume.walk(VolumeLayout.inbox(bot.id)).map(\.path)
        for path in paths {
            guard let data = try volume.read(path) else { continue }
            _ = try await space.write(path: "\(home)/\(path.dropFirst(prefix.count))", content: data)
            // A run the daemon starts restores the home from the Cua Volume.
            if persistentAgents { _ = try await cua.spaces().volumeWrite(path: path, content: data, ifEtag: nil,
                                                                          createOnly: false, view: nil) }
        }
    }

    /// Copy the bot's memory and outputs from the Space back into the Volume.
    public func checkpoint(_ bot: Bot, volume: VolumeStore) async throws {
        if persistentAgents { return try await pullHome(bot, volume: volume) }
        let space = try await space(bot)
        let home = try await home(bot, space)
        let list = try await space.bash(
            command: "cd '\(home)' 2>/dev/null && find memory outputs -type f -size -8M 2>/dev/null | head -200",
            timeoutMs: 15_000)
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("cua-bots-\(bot.id)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        for rel in list.stdout.split(separator: "\n").map(String.init) where !rel.isEmpty {
            let dir = staging.appendingPathComponent((rel as NSString).deletingLastPathComponent)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            _ = try await space.download(remotePath: "\(home)/\(rel)", destDir: dir.path)
            let local = dir.appendingPathComponent((rel as NSString).lastPathComponent)
            if let data = try? Data(contentsOf: local) {
                // The Volume refuses secrets under agents/; a refused file stays
                // in the Space only.
                try? volume.write(VolumeLayout.home(bot.id) + rel, data)
            }
        }
    }

    // MARK: - Pairing

    /// A link the iPhone app opens to reach this bot's computer directly:
    /// its spacesd address and token. On the same Mac (the iOS Simulator) the
    /// loopback address works; a phone elsewhere goes through the relay.
    public func pairingLink(_ bot: Bot) async throws -> String {
        guard let id = bot.spaceID else { throw EngineError.noSpace(bot.name) }
        let endpoint = try await cua.sandboxes().connect(name: id).service(name: "env").endpoint()
        let token = endpoint.headers.first { $0.name.lowercased().contains("authorization") }?.value
            .replacingOccurrences(of: "Bearer ", with: "") ?? ""
        var c = URLComponents()
        c.scheme = "cuabots"
        c.host = "direct"
        c.queryItems = [URLQueryItem(name: "url", value: endpoint.url), URLQueryItem(name: "token", value: token)]
        return c.string ?? ""
    }

    // MARK: - The pointer

    /// Where the bot's pointer is on its screen, in screen pixels. The app
    /// draws the bot's face there.
    public func pointer(_ bot: Bot) async -> CGPoint? {
        guard let id = bot.spaceID else { return nil }
        do {
            let client: SpacesdClient
            if let c = clients[id] { client = c } else {
                client = try await cua.sandboxes().connect(name: id).spacesd(probeTimeoutMs: 3000)
                clients[id] = client
            }
            let p = try await client.cursorPosition()
            return CGPoint(x: p.x, y: p.y)
        } catch {
            clients[id] = nil
            return nil
        }
    }

    // MARK: - Pause, resume, reset

    public func pause(_ bot: Bot) async throws {
        if persistentAgents {
            _ = try await cua.spaces().agentPause(name: bot.id)
            return
        }
        if let run = bot.runID { _ = try? await space(bot).agentInterrupt(runId: run) }
        guard suspendOnPause, let id = bot.spaceID, bot.placement == .local else { return }
        try await cua.sandboxes().connect(name: id).suspend()
    }

    public func resume(_ bot: Bot) async throws {
        if persistentAgents {
            _ = try await cua.spaces().agentResume(name: bot.id, prompt: nil)
            return
        }
        guard suspendOnPause, let id = bot.spaceID, bot.placement == .local else { return }
        try await cua.sandboxes().connect(name: id).resume()
    }

    public func reset(_ bot: Bot) async throws {
        if let run = bot.runID { _ = try? await space(bot).agentStop(runId: run) }
        // Forgets the agent and its routines; its home stays in the Cua Volume.
        if persistentAgents { _ = try? await cua.spaces().persistentAgentRemove(name: bot.id) }
        if let id = bot.spaceID { _ = try await cua.spaces().delete(space: id) }
        homes[bot.id] = nil
    }

    // MARK: - Persistent agents

    /// Publish the home to the Cua Volume, create the bot's persistent agent
    /// (once) and give it its first turn. Returns the run id.
    func startPersistent(_ bot: Bot, volume: VolumeStore, prompt: String) async throws -> String {
        guard let spaceID = bot.spaceID else { throw EngineError.noSpace(bot.name) }
        let spaces = cua.spaces()
        for entry in try volume.walk(VolumeLayout.home(bot.id)) where !entry.path.contains("/identity/") {
            guard let data = try volume.read(entry.path) else { continue }
            _ = try await spaces.volumeWrite(path: entry.path, content: data, ifEtag: nil, createOnly: false, view: nil)
        }
        if let existing = try await spaces.persistentAgents().first(where: { $0.name == bot.id }) {
            guard existing.harness == bot.harness.rawValue, existing.space == spaceID else {
                throw EngineError.refused("A persistent agent named \(bot.id) already runs \(existing.harness) in \(existing.space).")
            }
        } else {
            // Credentials: the harness's own sign-in in the Space (Codex's
            // ChatGPT login) or the keys saved in Cua Spaces, which the
            // daemon adds for the harness; only a custom endpoint names keys.
            let options = PersistentAgentOptions(model: endpoint?.model, baseUrl: endpoint?.baseURL,
                                                 envFromHost: endpoint?.keyVariables ?? [], env: [:])
            _ = try await spaces.persistentAgentCreate(name: bot.id, harness: bot.harness.rawValue, space: spaceID,
                                                       options: options)
        }
        return try await spaces.persistentAgentSend(name: bot.id, text: prompt).runId
    }

    /// Save the agent's home now, then copy its memory and outputs from the
    /// Cua Volume into the app's folder.
    func pullHome(_ bot: Bot, volume: VolumeStore) async throws {
        let spaces = cua.spaces()
        _ = try? await spaces.persistentAgentSave(name: bot.id)
        let local = Dictionary(((try? volume.walk(VolumeLayout.home(bot.id))) ?? []).map { ($0.path, $0) },
                               uniquingKeysWith: { a, _ in a })
        var folders = [VolumeLayout.home(bot.id) + "memory/", VolumeLayout.outputs(bot.id)]
        var seen = 0
        while let folder = folders.popLast(), seen < 200 {
            guard let listing = try? await spaces.volumeLs(path: folder, view: nil) else { continue }
            for e in listing.entries {
                let path = e.path.hasPrefix("agents/") ? e.path : folder + e.name
                if e.folder { folders.append(path.hasSuffix("/") ? path : path + "/"); continue }
                seen += 1
                if let l = local[path], l.size == e.size,
                   let m = l.modified, m.timeIntervalSince1970 * 1000 >= Double(e.modifiedMs) { continue }
                guard e.size < 8 << 20 else { continue }
                let file = try await spaces.volumeRead(path: path, version: nil, view: nil)
                // The app's Volume refuses secrets under agents/, as the drive does.
                try? volume.write(path, file.content)
            }
        }
    }

    /// The bot's routines as the daemon has them.
    public func routines(_ bot: Bot) async throws -> [RoutineState] {
        try await cua.spaces().routines(agent: bot.id).map { r in
            RoutineState(id: r.id, enabled: r.enabled, nextFire: r.nextFire.flatMap(Self.date),
                         lastFiredAt: r.lastFiredAt.flatMap(Self.date), lastOutcome: r.lastOutcome,
                         lastRunID: r.lastRunId)
        }
    }

    /// A scheduled task as a daemon routine. Returns its id.
    public func addRoutine(_ bot: Bot, _ task: BotTask) async throws -> String? {
        guard let a = task.schedule?.routineArguments else { return nil }
        return try await cua.spaces().routineAdd(agent: bot.id, title: task.title, prompt: task.prompt,
                                                 everyMinutes: a.everyMinutes, dailyAt: a.dailyAt,
                                                 weeklyOn: a.weeklyOn).id
    }

    public func setRoutine(_ id: String, enabled: Bool) async throws {
        _ = try await cua.spaces().routineSetEnabled(id: id, enabled: enabled)
    }

    public func removeRoutine(_ id: String) async throws {
        try await cua.spaces().routineRemove(id: id)
    }

    /// The daemon's notifications feed since `since`.
    public func notices(since: Date?) async throws -> [DaemonNotice] {
        let ms = since.map { UInt64(max(0, $0.timeIntervalSince1970) * 1000) + 1 }
        return try await cua.spaces().notifications(unreadOnly: false, sinceMs: ms).map { n in
            DaemonNotice(id: n.id, date: Date(timeIntervalSince1970: Double(n.atMs) / 1000), agent: n.agent,
                         kind: n.kind, title: n.title, body: n.body)
        }
    }

    static func date(_ rfc3339: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: rfc3339) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: rfc3339)
    }

    public enum EngineError: LocalizedError {
        case noSpace(String), noRun(String), notReady(String), refused(String)
        public var errorDescription: String? {
            switch self {
            case .noSpace(let n): "\(n) has no computer yet."
            case .noRun(let n): "\(n) isn't running."
            case .notReady(let s): s
            case .refused(let r): r
            }
        }
    }
}
