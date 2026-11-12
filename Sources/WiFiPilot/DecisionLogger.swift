import Foundation
import WiFiPilotCore

/// Writes decisions and their verification outcomes to the local history store.
///
/// Every record keeps the full comparison that drove it, so the log answers
/// "why did it switch?" and "why didn't it?" months later without any network data.
struct DecisionLogger: Sendable {
    let store: PersistenceStore

    @discardableResult
    func log(
        _ decision: AutomatedDecision,
        currentMetrics: NetworkMetrics?,
        candidateMetrics: NetworkMetrics?
    ) async -> DecisionRecord {
        let record = DecisionRecord(
            decision: decision,
            currentMetrics: currentMetrics,
            candidateMetrics: candidateMetrics
        )
        await store.record(record)
        try? await store.save()
        return record
    }

    func recordVerification(recordID: UUID, succeeded: Bool, detail: String) async {
        await store.updateVerification(recordID: recordID, succeeded: succeeded, detail: detail)
        try? await store.save()
    }

    func logVerification(
        _ decision: AutomatedDecision,
        previous: NetworkIdentity?,
        succeeded: Bool,
        detail: String
    ) async {
        await recordVerification(recordID: decision.id, succeeded: succeeded, detail: detail)
        let verification = AutomatedDecision(
            timestamp: Date(),
            action: .stay,
            target: decision.target,
            reason: DecisionReason(
                code: succeeded ? .switchVerificationSucceeded : .switchVerificationFailed,
                title: succeeded ? "Switch verified" : "Switch not verified",
                detail: detail
            ),
            currentNetwork: previous,
            mode: decision.mode
        )
        await log(verification, currentMetrics: nil, candidateMetrics: nil)
    }

    func updateProfileAfterSwitch(
        profile: NetworkProfile?,
        identity: NetworkIdentity,
        succeeded: Bool,
        at date: Date
    ) async -> NetworkProfile {
        var updated = profile ?? NetworkProfile(identity: identity, isKnownSaved: true, at: date)
        updated.lastSeen = date
        if succeeded {
            updated.successfulVerifications += 1
        } else {
            updated.failedVerifications += 1
        }
        await store.upsert(profile: updated)
        try? await store.save()
        return updated
    }

    func prune() async {
        await store.prune()
        try? await store.save()
    }

    func save() async {
        try? await store.save()
    }
}
