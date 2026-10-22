// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import Foundation

/// What happened in a bot's run since the last poll.
public enum EngineUpdate: Equatable, Sendable {
    /// The assistant's text for `turn` so far (the whole turn, not a delta).
    case assistant(turn: UInt32, text: String)
    /// A tool the harness is running ("Run tests", "Open browser").
    case tool(turn: UInt32, title: String)
    case turnEnded(turn: UInt32)
    case failed(String)
    /// The bot's persistent agent is on another run now (a routine `cua
    /// daemon` fired, or a fresh run): follow that run from its start.
    case run(String)
}

/// A bot's routine as `cua daemon` keeps it (`Spaces.routines`).
public struct RoutineState: Equatable, Sendable {
    public var id: String
    public var enabled: Bool
    public var nextFire: Date?
    public var lastFiredAt: Date?
    /// `started run <id>`, `refused: <why>` or `failed: <why>`.
    public var lastOutcome: String?
    public var lastRunID: String?

    public init(id: String, enabled: Bool = true, nextFire: Date? = nil, lastFiredAt: Date? = nil,
                lastOutcome: String? = nil, lastRunID: String? = nil) {
        self.id = id
        self.enabled = enabled
        self.nextFire = nextFire
        self.lastFiredAt = lastFiredAt
        self.lastOutcome = lastOutcome
        self.lastRunID = lastRunID
    }
}

/// One entry of `cua daemon`'s notifications feed (`Spaces.notifications`).
public struct DaemonNotice: Equatable, Sendable {
    public var id: String
    public var date: Date
    /// The persistent agent (a bot's id).
    public var agent: String?
    /// `turn_ended`, `message`, `approval` or `error`.
    public var kind: String
    public var title: String
    public var body: String

    public init(id: String, date: Date, agent: String?, kind: String, title: String, body: String) {
        self.id = id
        self.date = date
        self.agent = agent
        self.kind = kind
        self.title = title
        self.body = body
    }
}

/// Where a bot is in its life, as the engine reports it.
public enum EnginePhase: Equatable, Sendable {
    case creatingSpace(String)
    case startingAgent
    case ready
}

/// The seam between the app and Cua: a Space per bot, an agent run in it, a
/// Volume home copied in and out. `CuaBotsCua.CuaEngine` is the real one; tests
/// use a scripted engine.
@MainActor
public protocol BotEngine: AnyObject {
    /// Bots are `cua daemon` persistent agents: their homes live in the Cua
    /// Volume and the daemon runs their routines (off: runs the app starts).
    var persistentAgents: Bool { get }

    /// Create (or reuse) the bot's own Space. Returns its id.
    func provision(_ bot: Bot, progress: @escaping @MainActor (EnginePhase) -> Void) async throws -> String

    /// Copy the bot's home from the Volume into its Space and start its agent
    /// with `prompt` as the first turn. Returns the run id.
    func start(_ bot: Bot, volume: VolumeStore, prompt: String) async throws -> String

    /// Copy what changed on the app's side (instructions, rules, the inbox)
    /// from the Volume into the Space, before a turn.
    func push(_ bot: Bot, volume: VolumeStore) async throws

    /// Send a message to the running agent (starting a new turn).
    func send(_ bot: Bot, text: String) async throws

    /// Updates since `cursor`, and the new cursor.
    func poll(_ bot: Bot, cursor: UInt64) async throws -> (updates: [EngineUpdate], cursor: UInt64)

    /// Copy the bot's home (memory, outputs) from its Space back into the Volume.
    func checkpoint(_ bot: Bot, volume: VolumeStore) async throws

    /// Stop the run's work (the run and Space stay; the next message resumes
    /// the session).
    func interrupt(_ bot: Bot) async throws

    /// Pause: stop work and suspend the Space where the runtime supports it.
    func pause(_ bot: Bot) async throws
    func resume(_ bot: Bot) async throws

    /// Delete the run and the Space.
    func reset(_ bot: Bot) async throws
}

public extension BotEngine {
    var persistentAgents: Bool { false }
}
