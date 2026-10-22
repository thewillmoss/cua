// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import Testing
import Foundation
@testable import CuaBotsCore

/// Host placement and bots as `cua daemon` persistent agents.
struct PlacementTests {
    @Test func testOldPlacementsDecode() throws {
        let d = JSONDecoder()
        #expect(try d.decode([Placement].self, from: Data(#"["local","cloud"]"#.utf8)) == [.local, .cloud])
        let e = try JSONEncoder().encode([Placement.local, .host("worker-01")])
        #expect(String(decoding: e, as: UTF8.self) == #"["local","host:worker-01"]"#)
    }

    @Test func testHostPlacement() throws {
        let p = Placement.host("control-01")
        #expect(p.rawValue == "host:control-01")
        #expect(p.hostID == "control-01")
        #expect(p.name == "control-01")
        #expect(Placement.local.name == "This Mac" && Placement.local.hostID == nil)
        #expect(Placement.cloud.name == "Cua Cloud")
    }

    @Test func testBotWithAHostRoundTrips() throws {
        let bot = Bot(name: "Ada", harness: .codex, placement: .host("worker-03"))
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let back = try d.decode(Bot.self, from: e.encode(bot))
        #expect(back.placement == .host("worker-03"))
        #expect(back.harness == .codex)
    }
}

struct RoutineScheduleTests {
    @Test func testDaemonArguments() {
        #expect(TaskSchedule.every(minutes: 30).routineArguments == (30, nil, nil))
        #expect(TaskSchedule.daily(hour: 9, minute: 5).routineArguments == (nil, "09:05", nil))
        #expect(TaskSchedule.weekly(weekday: 2, hour: 8, minute: 30).routineArguments == (nil, nil, "mon 08:30"))
        #expect(TaskSchedule.weekly(weekday: 1, hour: 18, minute: 0).routineArguments == (nil, nil, "sun 18:00"))
    }

    @Test func testTasksSavedBeforeRoutineIDsDecode() throws {
        let task = BotTask(botID: "ada", title: "Morning", prompt: "Plan", schedule: .daily(hour: 8, minute: 0))
        let e = JSONEncoder()
        var json = try JSONSerialization.jsonObject(with: e.encode(task)) as! [String: Any]
        json["routineID"] = nil
        json["lastOutcome"] = nil
        let old = try JSONDecoder().decode(BotTask.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.routineID == nil && old.title == "Morning")
    }

    @Test func testInstructionsWhereEachHarnessReadsThem() {
        #expect(VolumeLayout.persistentInstructions("ada", harness: .codex) == "agents/ada/codex/AGENTS.md")
        #expect(VolumeLayout.persistentInstructions("ada", harness: .hermes) == "agents/ada/hermes/SOUL.md")
        #expect(VolumeLayout.persistentInstructions("ada", harness: .openclaw) == "agents/ada/workspace/AGENTS.md")
        #expect(VolumeLayout.persistentInstructions("ada", harness: .claudeCode) == nil)
        let bot = Bot(name: "Ada")
        #expect(BotInstructions.render(bot: bot, rules: []).contains("next to this file"))
        #expect(BotInstructions.render(bot: bot, rules: [], persistent: true).contains("the parent of the folder you start in"))
    }
}

@MainActor
@Suite(.serialized)
struct PersistentStoreTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cua-bots-persistent-" + UUID().uuidString)

    func makeStore(_ engine: ScriptedEngine) -> BotStore {
        BotStore(volume: LocalVolume(root: root.appendingPathComponent("volume")),
                 dataDirectory: root.appendingPathComponent("data"), engine: engine)
    }

    func persistentEngine() -> ScriptedEngine {
        let e = ScriptedEngine()
        e.persistentAgents = true
        return e
    }

    @Test func testCodexHomeGetsItsInstructions() async throws {
        let store = makeStore(persistentEngine())
        let bot = await store.createBot(name: "Ada", avatar: .default(for: "Ada"), harness: .codex, placement: .host("worker-01"))
        #expect(store.bot(bot.id)?.placement == .host("worker-01"))
        #expect(try store.volume.readText("agents/ada/AGENTS.md") != nil)
        #expect(try store.volume.readText("agents/ada/codex/AGENTS.md")?.contains("[[ask:") == true)
    }

    /// A routine the daemon fired while the app looked away: the store
    /// follows the new run, marks the routine's task, and the turn's markers
    /// become an approval card and an output.
    @Test func testDaemonRoutineTurnSurfacesApprovalAndOutput() async throws {
        let engine = persistentEngine()
        let store = makeStore(engine)
        let bot = await store.createBot(name: "Ada", avatar: .default(for: "Ada"), harness: .codex, placement: .local)
        await store.pollOnce(bot.id)
        let task = store.schedule(bot.id, title: "Morning", prompt: "Plan the day", schedule: .daily(hour: 8, minute: 0))
        store.setRoutineID(task.id, botID: bot.id, "r-1")
        #expect(store.tasks(for: bot.id).first?.routineID == "r-1")

        let fired = Date()
        store.applyRoutines(bot.id, [RoutineState(id: "r-1", nextFire: fired.addingTimeInterval(86_400),
                                                  lastFiredAt: fired, lastOutcome: "started run run-2",
                                                  lastRunID: "run-2")])
        #expect(store.messages(for: bot.id).last?.text == "Scheduled: Morning")
        #expect(store.tasks(for: bot.id).first?.lastOutcome == "started run run-2")
        // Applying the same state again changes nothing.
        let count = store.messages(for: bot.id).count
        store.applyRoutines(bot.id, [RoutineState(id: "r-1", lastFiredAt: fired, lastOutcome: "started run run-2")])
        #expect(store.messages(for: bot.id).count == count)

        engine.queue = [.run("run-2"),
                        .assistant(turn: 1, text: "[[step: Read the calendar]]\nTwo meetings.\n[[ask: Decline the 3pm | It clashes]]\n[[output: outputs/plan.md]]"),
                        .turnEnded(turn: 1)]
        await store.pollOnce(bot.id)
        #expect(store.bot(bot.id)?.runID == "run-2")
        #expect(store.pendingApprovals(for: bot.id).map(\.action) == ["Decline the 3pm"])
        let routine = try #require(store.tasks(for: bot.id).first { $0.id == task.id })
        #expect(routine.outputs == ["agents/ada/outputs/plan.md"])
        #expect(routine.steps.map(\.title) == ["Read the calendar"])
    }

    @Test func testCursorsSurviveARestart() async throws {
        let engine = persistentEngine()
        let store = makeStore(engine)
        let bot = await store.createBot(name: "Ada", avatar: .default(for: "Ada"), harness: .codex, placement: .local)
        await store.pollOnce(bot.id)
        let data = try Data(contentsOf: root.appendingPathComponent("data/state.json"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect((json?["cursors"] as? [String: Any])?["ada"] != nil)
    }

    @Test func testDaemonNoticesShowOnce() async throws {
        let store = makeStore(persistentEngine())
        let bot = await store.createBot(name: "Ada", avatar: .default(for: "Ada"), harness: .codex, placement: .local)
        let at = Date()
        let notices = [
            DaemonNotice(id: "n1", date: at, agent: bot.id, kind: "message", title: "Your research is ready", body: "3 sources"),
            DaemonNotice(id: "n2", date: at, agent: bot.id, kind: "turn_ended", title: "Ada", body: "Done"),
            DaemonNotice(id: "n3", date: at, agent: "someone-else", kind: "error", title: "x", body: "y"),
        ]
        store.ingest(notices)
        store.ingest(notices)
        let mine = store.notifications.filter { $0.id.hasPrefix("daemon-") }
        #expect(mine.map(\.title) == ["Your research is ready"])
        #expect(mine.first?.kind == .result)
        #expect(store.lastDaemonNotice != nil)
    }
}
