import Foundation
import Testing
@testable import RaterKit

/// Builds a signals snapshot, overriding only what a given test cares about.
private func signals(
    daysSinceInstall: Int = 0,
    launchCount: Int = 0,
    launchCountThisVersion: Int = 0,
    events: [String: Int] = [:],
    daysSinceLastPrompt: Int? = nil,
    promptCount: Int = 0,
    promptCountThisVersion: Int = 0,
    hasRated: Bool = false,
    hasOptedOut: Bool = false,
    remoteEnabled: Bool = true,
    remoteRules: RemoteRules? = nil
) -> TriggerSignals {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    // Step back by calendar days rather than subtracting seconds. The rules count
    // calendar days too, and a day across a DST change isn't 86400 seconds — subtracting
    // seconds turns an exactly-30-days boundary case into 29 for no obvious reason.
    func daysAgo(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
    }

    return TriggerSignals(
        now: now,
        installDate: daysAgo(daysSinceInstall),
        launchCount: launchCount,
        launchCountThisVersion: launchCountThisVersion,
        eventCounts: events,
        appVersion: "1.0.0",
        lastPromptDate: daysSinceLastPrompt.map(daysAgo),
        promptCount: promptCount,
        promptCountThisVersion: promptCountThisVersion,
        hasRated: hasRated,
        hasOptedOut: hasOptedOut,
        remoteEnabled: remoteEnabled,
        remoteRules: remoteRules
    )
}

@Suite("Trigger rules")
struct TriggerRuleTests {

    @Test("passes once installed long enough", arguments: [(2, false), (3, true), (10, true)])
    func daysSinceInstall(days: Int, expected: Bool) {
        let rule = RaterRule.daysSinceInstall(atLeast: 3)
        #expect(rule.evaluate(signals(daysSinceInstall: days)) == expected)
    }

    @Test("passes once launched enough times")
    func launchCount() {
        let rule = RaterRule.launchCount(atLeast: 5)
        #expect(rule.evaluate(signals(launchCount: 4)) == false)
        #expect(rule.evaluate(signals(launchCount: 5)) == true)
    }

    @Test("named events are counted separately")
    func namedEvents() {
        let rule = RaterRule.event("export", atLeast: 3)
        #expect(rule.evaluate(signals(events: ["export": 2])) == false)
        #expect(rule.evaluate(signals(events: ["export": 3])) == true)
        // A different event, however plentiful, does not count
        #expect(rule.evaluate(signals(events: ["share": 99])) == false)
    }

    @Test("total events sums across every kind")
    func totalEvents() {
        let rule = RaterRule.totalEvents(atLeast: 5)
        #expect(rule.evaluate(signals(events: ["a": 2, "b": 2])) == false)
        #expect(rule.evaluate(signals(events: ["a": 2, "b": 2, "c": 1])) == true)
    }

    @Test("cooldown passes when nothing has been shown yet")
    func cooldownWithoutHistory() {
        #expect(RaterRule.cooldown(days: 30).evaluate(signals()) == true)
    }

    @Test("cooldown blocks inside the window")
    func cooldownBlocks() {
        let rule = RaterRule.cooldown(days: 30)
        #expect(rule.evaluate(signals(daysSinceLastPrompt: 29)) == false)
        #expect(rule.evaluate(signals(daysSinceLastPrompt: 30)) == true)
    }

    @Test("per-version prompt cap")
    func maxPromptsPerVersion() {
        let rule = RaterRule.maxPromptsPerVersion(1)
        #expect(rule.evaluate(signals(promptCountThisVersion: 0)) == true)
        #expect(rule.evaluate(signals(promptCountThisVersion: 1)) == false)
    }

    @Test("rating or opting out blocks permanently")
    func terminalStates() {
        #expect(RaterRule.notAfterRated.evaluate(signals(hasRated: true)) == false)
        #expect(RaterRule.notAfterRated.evaluate(signals(hasRated: false)) == true)
        #expect(RaterRule.notAfterOptOut.evaluate(signals(hasOptedOut: true)) == false)
        #expect(RaterRule.notAfterOptOut.evaluate(signals(hasOptedOut: false)) == true)
    }

    @Test("the server master switch can shut prompting off")
    func remoteKillSwitch() {
        #expect(RaterRule.remoteEnabled.evaluate(signals(remoteEnabled: false)) == false)
        #expect(RaterRule.remoteEnabled.evaluate(signals(remoteEnabled: true)) == true)
    }

    @Test("anyOf passes when any sub-rule passes")
    func anyOf() {
        let rule = RaterRule.anyOf([
            .event("export", atLeast: 3),
            .daysSinceInstall(atLeast: 30),
        ])
        #expect(rule.evaluate(signals(daysSinceInstall: 1, events: ["export": 3])) == true)
        #expect(rule.evaluate(signals(daysSinceInstall: 30)) == true)
        #expect(rule.evaluate(signals(daysSinceInstall: 1, events: ["export": 1])) == false)
    }

    @Test("not negates")
    func negation() {
        #expect(RaterRule.not(.always).evaluate(signals()) == false)
    }

    @Test("a custom rule sees the whole snapshot")
    func customRule() {
        let rule = RaterRule.custom("bigSpender") { $0.launchCount > 100 }
        #expect(rule.evaluate(signals(launchCount: 101)) == true)
        #expect(rule.evaluate(signals(launchCount: 100)) == false)
    }
}

@Suite("Server-side threshold overrides")
struct RemoteRuleOverrideTests {

    @Test("the server threshold beats the one baked into the client")
    func remoteOverridesLocal() {
        // The client says 5, the server says 2 — loosened without shipping a build.
        let rule = RaterRule.launchCount(atLeast: 5)
        let remote = RemoteRules(minLaunchCount: 2)
        #expect(rule.evaluate(signals(launchCount: 3, remoteRules: remote)) == true)
        #expect(rule.evaluate(signals(launchCount: 3)) == false)
    }

    @Test("the server can also tighten a condition")
    func remoteTightens() {
        let rule = RaterRule.daysSinceInstall(atLeast: 3)
        let remote = RemoteRules(minDaysSinceInstall: 14)
        #expect(rule.evaluate(signals(daysSinceInstall: 7, remoteRules: remote)) == false)
    }

    @Test("unset server fields fall back to the client value")
    func partialOverride() {
        let rule = RaterRule.cooldown(days: 30)
        // Only minLaunchCount is overridden, so cooldown should still be 30
        let remote = RemoteRules(minLaunchCount: 1)
        #expect(rule.evaluate(signals(daysSinceLastPrompt: 10, remoteRules: remote)) == false)
        #expect(rule.evaluate(signals(daysSinceLastPrompt: 31, remoteRules: remote)) == true)
    }
}

@Suite("Rule engine")
struct TriggerEngineTests {

    @Test("every rule must pass")
    func allMustPass() {
        let engine = TriggerEngine(rules: [
            .launchCount(atLeast: 5),
            .daysSinceInstall(atLeast: 3),
        ])
        #expect(engine.evaluate(signals(daysSinceInstall: 3, launchCount: 5)).isEligible)
        #expect(!engine.evaluate(signals(daysSinceInstall: 3, launchCount: 4)).isEligible)
    }

    @Test("reports every failing rule instead of short-circuiting on the first")
    func reportsAllBlockers() {
        let engine = TriggerEngine(rules: [
            .notAfterRated,
            .launchCount(atLeast: 5),
            .daysSinceInstall(atLeast: 3),
        ])
        let decision = engine.evaluate(signals(daysSinceInstall: 0, launchCount: 0, hasRated: true))
        #expect(decision.blockedBy.count == 3)
        #expect(decision.blockedBy.first == "notAfterRated")
    }

    @Test("an empty rule set passes")
    func emptyRuleSet() {
        #expect(TriggerEngine(rules: []).evaluate(signals()).isEligible)
    }

    @Test("the default rules block a fresh install")
    func defaultRulesBlockFreshInstall() {
        let engine = TriggerEngine(rules: RaterConfiguration.defaultRules)
        #expect(!engine.evaluate(signals(daysSinceInstall: 0, launchCount: 1)).isEligible)
    }

    @Test("the default rules allow an engaged user")
    func defaultRulesAllowEngagedUser() {
        let engine = TriggerEngine(rules: RaterConfiguration.defaultRules)
        let decision = engine.evaluate(signals(daysSinceInstall: 10, launchCount: 20))
        #expect(decision.isEligible, "blocked by: \(decision.blockedBy)")
    }
}
