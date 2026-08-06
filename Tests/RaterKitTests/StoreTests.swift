import Foundation
import Testing
@testable import RaterKit

@Suite("State storage")
struct StoreTests {

    @Test("mutate does read-modify-write in one call")
    func mutateRoundTrips() {
        let store = InMemoryStore()
        store.mutate { $0.launchCount += 1 }
        store.mutate { $0.launchCount += 1 }
        #expect(store.load().launchCount == 2)
    }

    @Test("event counts accumulate per name")
    func eventCounts() {
        let store = InMemoryStore()
        store.mutate { $0.eventCounts["export", default: 0] += 1 }
        store.mutate { $0.eventCounts["export", default: 0] += 2 }
        store.mutate { $0.eventCounts["share", default: 0] += 1 }

        let state = store.load()
        #expect(state.eventCounts["export"] == 3)
        #expect(state.eventCounts["share"] == 1)
    }

    @Test("clear resets to initial state")
    func clearResets() {
        let store = InMemoryStore()
        store.mutate {
            $0.launchCount = 42
            $0.hasRated = true
        }
        store.clear()

        #expect(store.load().launchCount == 0)
        #expect(store.load().hasRated == false)
    }

    @Test("the UserDefaults store is visible across instances")
    func userDefaultsPersists() throws {
        let suite = "com.raterkit.tests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let store = UserDefaultsStore(suiteName: suite)
        store.mutate {
            $0.launchCount = 7
            $0.lastEmail = "a@b.com"
        }

        // Read from a fresh instance, as a relaunch would
        let reopened = UserDefaultsStore(suiteName: suite)
        #expect(reopened.load().launchCount == 7)
        #expect(reopened.load().lastEmail == "a@b.com")
    }

    @Test("the first read seeds the install date, or daysSinceInstall stays 0 forever")
    func firstReadSeedsInstallDate() {
        let suite = "com.raterkit.tests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let store = UserDefaultsStore(suiteName: suite)
        let first = store.load().installDate
        let second = UserDefaultsStore(suiteName: suite).load().installDate

        #expect(abs(first.timeIntervalSince(second)) < 0.001,
                "a second read must not refresh the install date")
    }

    @Test("state survives a JSON round trip intact")
    func codableRoundTrip() throws {
        let original = RaterState(
            installDate: Date(timeIntervalSince1970: 1_700_000_000),
            launchCount: 12,
            launchCountByVersion: ["1.0": 5, "1.1": 7],
            eventCounts: ["export": 3],
            lastPromptDate: Date(timeIntervalSince1970: 1_700_100_000),
            lastPromptOutcome: "dismissed",
            promptCount: 1,
            promptCountByVersion: ["1.1": 1],
            hasRated: false,
            hasOptedOut: true,
            lastEmail: "user@example.com"
        )
        let data = try JSONEncoder.rater.encode(original)
        let decoded = try JSONDecoder.rater.decode(RaterState.self, from: data)
        #expect(decoded == original)
    }
}

@Suite("Feedback draft validation")
struct FeedbackDraftTests {

    @Test("rejects a message that is too short", arguments: ["", "  ", "abc", "  a  "])
    func rejectsShortMessage(message: String) {
        var draft = FeedbackDraft()
        draft.message = message
        #expect(!draft.isMessageValid)
    }

    @Test("four characters is the threshold")
    func acceptsMessage() {
        var draft = FeedbackDraft()
        draft.message = "bad"   // 3 characters, not enough
        #expect(!draft.isMessageValid)
        draft.message = "buggy" // 4 characters
        #expect(draft.isMessageValid)
    }

    @Test("email shape validation", arguments: [
        ("", true),                    // empty means "not provided", which is fine
        ("a@b.com", true),
        ("user.name+tag@sub.example.co.uk", true),
        ("nope", false),
        ("@b.com", false),
        ("a@b", false),                // no dot in the domain
        ("a@.com", false),
        ("a@b.", false),
        ("a b@c.com", false),          // whitespace
        ("a@b@c.com", false),          // two @ signs
    ])
    func emailValidation(email: String, expected: Bool) {
        var draft = FeedbackDraft()
        draft.email = email
        #expect(draft.isEmailValid == expected, "\(email)")
    }

    @Test("a blank email blocks submission when email is required")
    func emailRequired() {
        var draft = FeedbackDraft()
        draft.message = "long enough to submit"

        #expect(draft.canSubmit(emailRequired: false))
        #expect(!draft.canSubmit(emailRequired: true))

        draft.email = "a@b.com"
        #expect(draft.canSubmit(emailRequired: true))
    }

    @Test("each draft gets its own idempotency key")
    func uniqueIdempotencyKeys() {
        #expect(FeedbackDraft().idempotencyKey != FeedbackDraft().idempotencyKey)
    }
}
