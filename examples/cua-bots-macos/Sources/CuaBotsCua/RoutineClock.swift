// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import CuaBotsCore
import CuaSpaces
import Foundation

/// "Works on its own": a bot's scheduled tasks run on the SDK's routine clock
/// (`CuaSpaces.RoutineStore`). Each scheduled task is one routine whose prompt
/// is the task id; firing asks the store to run the task, and a paused or
/// busy bot refuses rather than interrupts.
///
/// With an engine of persistent agents the clock is `cua daemon`'s instead:
/// each scheduled task is a daemon routine (`Spaces.routineAdd`) that fires
/// whether or not the app is open, and the clock reads the daemon's routines
/// and notifications feed back into the store.
@MainActor
public final class RoutineClock: RoutineRunner {
    public let routines: RoutineStore
    private weak var store: BotStore?
    private let daemon: CuaEngine?
    /// Routine ids this app made, per bot: deleting a task removes only these.
    private var owned: [String: Set<String>] = [:]
    private var syncing: Set<String> = []
    private var resync: Set<String> = []
    private var refresher: Task<Void, Never>?

    public init(fileURL: URL, store: BotStore, engine: CuaEngine? = nil) {
        routines = RoutineStore(fileURL: fileURL)
        self.store = store
        daemon = engine?.persistentAgents == true ? engine : nil
        routines.attach(runner: self)
        store.onTasksChanged = { [weak self] bot, tasks in self?.sync(bot: bot, tasks: tasks) }
        for bot in store.bots {
            owned[bot.id] = Set(store.tasks(for: bot.id).compactMap(\.routineID))
            sync(bot: bot, tasks: store.tasks(for: bot.id))
        }
    }

    /// The routines are `cua daemon`'s (persistent agents).
    public var usesDaemon: Bool { daemon != nil }

    public func start(every interval: Duration = .seconds(15)) {
        guard daemon != nil else { return routines.startScheduler(every: interval) }
        refresher = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Mirror one bot's scheduled tasks into the routine list, keeping each
    /// routine's firing history.
    public func sync(bot: Bot, tasks: [BotTask]) {
        if daemon != nil {
            Task { await syncDaemon(bot.id) }
            return
        }
        let scheduled = tasks.filter { $0.schedule != nil }
        let existing = routines.routines(for: bot.id)
        for r in existing where !scheduled.contains(where: { $0.id == r.prompt }) {
            routines.delete(r.id)
        }
        for task in scheduled {
            guard let schedule = task.schedule.map(Self.routineSchedule) else { continue }
            let enabled = task.state == .scheduled && !bot.isPaused
            if var r = existing.first(where: { $0.prompt == task.id }) {
                if r.schedule != schedule || r.isEnabled != enabled || r.title != task.title {
                    r.schedule = schedule
                    r.isEnabled = enabled
                    r.title = task.title
                    routines.update(r)
                }
            } else {
                routines.create(botID: bot.id, title: task.title, prompt: task.id, schedule: schedule,
                                enabled: enabled)
            }
        }
    }

    public func fire(_ routine: Routine) async -> RoutineFiring {
        guard let store else { return .failed(reason: "the app is closing") }
        guard let bot = store.bot(routine.botID) else { return .failed(reason: "no such bot") }
        if bot.isPaused { return .refused(reason: "\(bot.name) is paused") }
        if store.isBusy(bot.id) { return .refused(reason: "\(bot.name) is mid-turn") }
        let ok = await store.fire(taskID: routine.prompt, botID: routine.botID)
        return ok ? .started(runID: store.bot(bot.id)?.runID ?? "") : .refused(reason: "not ready")
    }

    // MARK: - cua daemon

    /// One bot's scheduled tasks as daemon routines: add the missing ones,
    /// follow on and off, remove the ones whose task is gone. One pass per
    /// bot at a time, so a restart or a quick edit never adds a routine twice.
    func syncDaemon(_ botID: String) async {
        guard let daemon, let store else { return }
        if syncing.contains(botID) { resync.insert(botID); return }
        syncing.insert(botID)
        defer { syncing.remove(botID) }
        repeat {
            resync.remove(botID)
            guard let bot = store.bot(botID) else {
                for id in owned[botID] ?? [] { try? await daemon.removeRoutine(id) }
                owned[botID] = nil
                return
            }
            do {
                let existing = try await daemon.routines(bot)
                let tasks = store.tasks(for: botID).filter { $0.schedule != nil }
                for task in tasks {
                    let enabled = task.state == .scheduled && !bot.isPaused
                    if let rid = task.routineID, let r = existing.first(where: { $0.id == rid }) {
                        if r.enabled != enabled { try await daemon.setRoutine(rid, enabled: enabled) }
                    } else if let rid = try await daemon.addRoutine(bot, task) {
                        owned[botID, default: []].insert(rid)
                        if !enabled { try await daemon.setRoutine(rid, enabled: false) }
                        store.setRoutineID(task.id, botID: botID, rid)
                    }
                }
                let kept = Set(store.tasks(for: botID).compactMap(\.routineID))
                for rid in (owned[botID] ?? []).subtracting(kept) where existing.contains(where: { $0.id == rid }) {
                    try await daemon.removeRoutine(rid)
                    owned[botID]?.remove(rid)
                }
            } catch {
                store.lastError = "Couldn't update \(bot.name)'s routines: \(error.localizedDescription)"
            }
        } while resync.contains(botID)
    }

    /// Read the daemon's routines and notifications feed into the store.
    public func refresh() async {
        guard let daemon, let store else { return }
        for bot in store.bots {
            if let states = try? await daemon.routines(bot) { store.applyRoutines(bot.id, states) }
        }
        let since = store.lastDaemonNotice ?? Date().addingTimeInterval(-24 * 3600)
        if let notices = try? await daemon.notices(since: since) { store.ingest(notices) }
    }

    static func routineSchedule(_ s: TaskSchedule) -> RoutineSchedule {
        switch s {
        case .every(let m): .everyMinutes(m)
        case .daily(let h, let m): .dailyAt(hour: h, minute: m)
        case .weekly(let wd, let h, let m): .weeklyOn(weekday: wd, hour: h, minute: m)
        }
    }
}
