// FineTuneTests/StartGuardTests.swift
//
// Which processes the start guard holds (StartGuardPolicy), and its setting. The guard's tap
// and aggregate need the HAL and were measured with StartGuardSpike instead.

import Testing
import Foundation
@testable import FineTune

private let second = StartGuardPolicy.ticks(seconds: 1)
private let failSafe = StartGuardPolicy.ticks(seconds: StartGuard.failSafeSeconds)

private func app(
    _ pid: pid_t, processes: [AudioObjectID], eligible: Bool = true,
    streaming: Bool = false, captured: UInt64 = 0
) -> StartGuardPolicy.App {
    StartGuardPolicy.App(pid: pid, processes: processes, isEligible: eligible,
                         isStreaming: streaming, lastCapturedHostTime: captured)
}

@Suite("Start guard — protect app starts")
struct StartGuardTests {

    @Test("An app with no tap carrying it is held, playing or not")
    func untappedAppsAreHeld() {
        let decision = StartGuardPolicy.decide(
            apps: [app(10, processes: [100, 101]), app(11, processes: [110], streaming: true)],
            state: .init(), now: 10 * second, failSafeTicks: failSafe)
        #expect(decision.held == [100, 101, 110])
        #expect(decision.isPending)
        #expect(decision.newlyReleased.isEmpty)
    }

    @Test("An app whose tap carries its audio is let go")
    func capturedAppsAreLetGo() {
        let decision = StartGuardPolicy.decide(
            apps: [app(10, processes: [100], streaming: true, captured: 5 * second)],
            state: .init(), now: 10 * second, failSafeTicks: failSafe)
        #expect(decision.held.isEmpty)
        #expect(!decision.isPending)
    }

    @Test("Ignored apps and apps on a call are never held")
    func ineligibleAppsAreNeverHeld() {
        let decision = StartGuardPolicy.decide(
            apps: [app(10, processes: [100], eligible: false, streaming: true)],
            state: .init(), now: 10 * second, failSafeTicks: failSafe)
        #expect(decision.held.isEmpty)
    }

    @Test("While taps are rebuilt, an app is held even though its old tap carries it")
    func forcedAppsAreHeld() {
        var state = StartGuardPolicy.State()
        state.forced = [10]
        let decision = StartGuardPolicy.decide(
            apps: [app(10, processes: [100], streaming: true, captured: 9 * second)],
            state: state, now: 10 * second, failSafeTicks: failSafe)
        #expect(decision.held == [100])
        #expect(decision.state.forced == [10])
    }

    @Test("An app held while it plays is let go after the fail-safe delay, until it stops")
    func failSafe() {
        let start = 10 * second
        var decision = StartGuardPolicy.decide(
            apps: [app(10, processes: [100], streaming: true)],
            state: .init(), now: start, failSafeTicks: failSafe)
        #expect(decision.held == [100])

        decision = StartGuardPolicy.decide(
            apps: [app(10, processes: [100], streaming: true)],
            state: decision.state, now: start + failSafe / 2, failSafeTicks: failSafe)
        #expect(decision.held == [100])

        decision = StartGuardPolicy.decide(
            apps: [app(10, processes: [100], streaming: true)],
            state: decision.state, now: start + failSafe, failSafeTicks: failSafe)
        #expect(decision.held.isEmpty)
        #expect(decision.newlyReleased == [10])
        #expect(!decision.isPending)

        // Reported once, and let go while it keeps playing
        decision = StartGuardPolicy.decide(
            apps: [app(10, processes: [100], streaming: true)],
            state: decision.state, now: start + 3 * failSafe, failSafeTicks: failSafe)
        #expect(decision.held.isEmpty)
        #expect(decision.newlyReleased.isEmpty)

        // Once it stops, it is held again before its next start
        decision = StartGuardPolicy.decide(
            apps: [app(10, processes: [100])],
            state: decision.state, now: start + 4 * failSafe, failSafeTicks: failSafe)
        #expect(decision.held == [100])
        #expect(decision.state.released.isEmpty)
    }

    @Test("A silent app is held without counting toward the fail-safe")
    func silentAppsDoNotCount() {
        var decision = StartGuardPolicy.decide(
            apps: [app(10, processes: [100])], state: .init(), now: second, failSafeTicks: failSafe)
        decision = StartGuardPolicy.decide(
            apps: [app(10, processes: [100])], state: decision.state, now: 100 * second, failSafeTicks: failSafe)
        #expect(decision.held == [100])
        #expect(!decision.isPending)
        #expect(decision.state.heldStreamingSince.isEmpty)
    }

    @Test("Excluded: every process but the held ones, and FineTune itself")
    func exclusions() {
        let list = StartGuardPolicy.exclusions(allProcesses: [5, 3, 9, 7], own: 1, held: [3, 7])
        #expect(list == [1, 5, 9])
        // FineTune's own output is never muted, even if it were listed as held
        #expect(StartGuardPolicy.exclusions(allProcesses: [1, 2], own: 1, held: [1]) == [1, 2])
        #expect(StartGuardPolicy.exclusions(allProcesses: [4], own: .unknown, held: []) == [4])
    }

    @Test("On by default, and kept by the settings file")
    func setting() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(decoded.startGuardEnabled)
        var settings = decoded
        settings.startGuardEnabled = false
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(!roundTrip.startGuardEnabled)
    }
}
