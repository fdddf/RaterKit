import Foundation
import os

/// Reports prompt-funnel telemetry.
///
/// Events buffer in memory and go out in batches, or when `flush()` is called — a tap
/// on the prompt shouldn't cost an immediate network round trip. Dropped events stay
/// dropped: nothing is persisted, because analytics aren't worth the disk.
actor TelemetryReporter {
    /// Send a batch once this many events have accumulated.
    private let batchSize = 5

    private let client: RaterAPIClient
    private let isEnabled: Bool
    private var buffer: [TelemetryBody.Event] = []
    private let logger = Logger(subsystem: "com.raterkit", category: "telemetry")

    init(client: RaterAPIClient, isEnabled: Bool) {
        self.client = client
        self.isEnabled = isEnabled
    }

    func record(_ outcome: RaterOutcome, appVersion: String, variant: String, locale: String) {
        guard isEnabled, let kind = outcome.telemetryKind else { return }

        buffer.append(.init(kind: kind, appVersion: appVersion, variant: variant, locale: locale))
        if buffer.count >= batchSize {
            Task { await flush() }
        }
    }

    /// Flushes buffered events. Foreground and background transitions are good moments.
    func flush() async {
        guard isEnabled, !buffer.isEmpty else { return }

        let batch = buffer
        buffer.removeAll()

        do {
            try await client.sendTelemetry(TelemetryBody(events: batch))
        } catch {
            logger.debug("telemetry upload failed, dropping \(batch.count): \(error.localizedDescription)")
        }
    }
}
