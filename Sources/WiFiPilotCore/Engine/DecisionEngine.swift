import Foundation

/// Deterministic, hardware-free switching brain.
///
/// The engine is a value type driven entirely by explicit inputs and an injected
/// `now`, so every rule below can be tested with simulated networks and a fake clock.
/// It never talks to CoreWLAN and never performs I/O.
///
/// Evaluation order is intentional — the cheapest and safest "don't switch" answers
/// come first, and a switch requires *all* of these to hold:
///  1. Automation is on AUTO (OBSERVE returns a hypothetical decision instead).
///  2. No manual pause is active.
///  3. The current network is degraded for at least `degradationDuration`.
///  4. The candidate has been the best challenge for `candidateQualificationDuration`.
///  5. A candidate is eligible: available, saved, not avoided, not never-auto-join.
///  6. The candidate's advantage exceeds `minimumScoreAdvantage` (raised during traffic).
///  7. No cooldown or manual-switch protection window is active.
///  8. Fewer than `maximumSwitchesPerHour` automatic attempts happened in the last hour.
///
/// Emergency override: if the current network loses internet or falls below
/// `emergencyScoreThreshold`, waiting requirements are skipped so the user is not
/// stuck on a dead link. Manual pause and OFF still win over the override.
public struct DecisionEngine: Sendable {
    public private(set) var policy: SwitchingPolicy
    public private(set) var degradationStartedAt: Date?
    public private(set) var bestCandidateKey: String?
    public private(set) var bestCandidateSince: Date?
    public private(set) var lastAutomatedSwitchAt: Date?
    public private(set) var lastManualSwitchAt: Date?
    /// Timestamps of automatic switch attempts (successful, failed and recovery),
    /// pruned to the last hour. Used for the rolling-hour rate limit.
    public private(set) var switchHistory: [Date] = []
    public private(set) var lastDecision: AutomatedDecision?
    public private(set) var currentNetwork: NetworkIdentity?

    public init(policy: SwitchingPolicy = .standard) {
        self.policy = policy.sanitized()
    }

    // MARK: - Configuration and bookkeeping

    public mutating func update(policy: SwitchingPolicy) {
        self.policy = policy.sanitized()
    }

    /// Notifies the engine which network is connected. Timers reset when it changes,
    /// so a new association never inherits another network's degradation history.
    public mutating func noteConnection(_ network: NetworkIdentity?, at date: Date) {
        if currentNetwork?.networkKey != network?.networkKey {
            degradationStartedAt = nil
            bestCandidateKey = nil
            bestCandidateSince = nil
        }
        currentNetwork = network
    }

    public mutating func recordAutomatedSwitch(to target: NetworkIdentity, at date: Date) {
        lastAutomatedSwitchAt = date
        noteSwitchAttempt(at: date)
        degradationStartedAt = nil
        bestCandidateKey = nil
        bestCandidateSince = nil
        currentNetwork = target
    }

    /// A user-initiated switch suppresses automation for `manualSwitchProtection`.
    public mutating func recordManualSwitch(to target: NetworkIdentity, at date: Date) {
        lastManualSwitchAt = date
        degradationStartedAt = nil
        bestCandidateKey = nil
        bestCandidateSince = nil
        currentNetwork = target
    }

    /// Starts the cooldown after a failed switch attempt so the engine cannot retry
    /// in a tight loop against a network that will not accept the association.
    public mutating func recordFailedSwitch(at date: Date) {
        lastAutomatedSwitchAt = date
        noteSwitchAttempt(at: date)
        degradationStartedAt = nil
        bestCandidateKey = nil
        bestCandidateSince = nil
    }

    /// A candidate's qualification clock restarts whenever it stops being the best.
    public mutating func resetCandidateQualification() {
        bestCandidateKey = nil
        bestCandidateSince = nil
    }

    private mutating func noteSwitchAttempt(at date: Date) {
        switchHistory.append(date)
        switchHistory.removeAll { date.timeIntervalSince($0) >= 3600 }
    }

    /// Automatic switch attempts inside the rolling window ending at `now`.
    public func switchAttempts(inLast interval: TimeInterval = 3600, at now: Date) -> Int {
        switchHistory.filter { $0 <= now && now.timeIntervalSince($0) < interval }.count
    }

    public func cooldownRemaining(at now: Date) -> TimeInterval {
        guard let lastAutomatedSwitchAt else { return 0 }
        return max(0, policy.effectiveCooldown - now.timeIntervalSince(lastAutomatedSwitchAt))
    }

    public func manualProtectionRemaining(at now: Date) -> TimeInterval {
        guard let lastManualSwitchAt else { return 0 }
        return max(0, policy.manualSwitchProtection - now.timeIntervalSince(lastManualSwitchAt))
    }

    public func degradationElapsed(at now: Date) -> TimeInterval {
        guard let degradationStartedAt else { return 0 }
        return max(0, now.timeIntervalSince(degradationStartedAt))
    }

    public func candidateQualificationElapsed(at now: Date) -> TimeInterval {
        guard let bestCandidateSince else { return 0 }
        return max(0, now.timeIntervalSince(bestCandidateSince))
    }

    // MARK: - Evaluation

    public mutating func evaluate(_ input: DecisionInput, at now: Date) -> AutomatedDecision {
        let policy = input.policy.sanitized()
        self.policy = policy

        if input.mode == .off {
            return record(
                make(
                    input: input,
                    now: now,
                    action: .stay,
                    reason: DecisionReason(
                        code: .automationOff,
                        title: "Automation is off",
                        detail: "No networks were evaluated because WiFiPilot is in OFF mode."
                    )
                )
            )
        }

        if let pauseUntil = input.pauseUntil, pauseUntil > now {
            let remaining = Int(pauseUntil.timeIntervalSince(now).rounded(.up))
            return record(
                make(
                    input: input,
                    now: now,
                    action: .stay,
                    reason: DecisionReason(
                        code: .manuallyPaused,
                        title: "Automation paused",
                        detail: "Automatic switching is paused for another \(remaining) s."
                    )
                )
            )
        }

        guard let current = input.current else {
            return record(
                make(
                    input: input,
                    now: now,
                    action: .stay,
                    reason: DecisionReason(
                        code: .noCurrentConnection,
                        title: "Not connected",
                        detail: "There is no active Wi-Fi association to evaluate."
                    )
                )
            )
        }

        // MARK: Eligibility filtering

        var excludedNotes: [String] = []
        var eligible: [CandidateSnapshot] = []

        for candidate in input.candidates
        where candidate.network.networkKey != current.network.networkKey {
            if !candidate.isAvailable {
                excludedNotes.append("\(candidate.network.displayName): not currently visible")
                continue
            }
            if candidate.isAvoided {
                excludedNotes.append("\(candidate.network.displayName): marked as avoided")
                continue
            }
            if candidate.isNeverAutoJoin {
                excludedNotes.append("\(candidate.network.displayName): never auto-join")
                continue
            }
            if policy.requireCandidateSavedNetwork && !candidate.isKnownSaved {
                excludedNotes.append("\(candidate.network.displayName): not a saved network")
                continue
            }
            eligible.append(candidate)
        }

        guard let best = eligible.sorted(by: Self.preferredOrder).last else {
            return record(
                make(
                    input: input,
                    now: now,
                    action: .stay,
                    reason: DecisionReason(
                        code: .noEligibleCandidates,
                        title: "No eligible candidate",
                        detail: excludedNotes.isEmpty
                            ? "No other saved networks are visible."
                            : "No eligible candidate. " + excludedNotes.prefix(4).joined(separator: "; ") + "."
                    ),
                    notes: excludedNotes
                )
            )
        }

        // MARK: Candidate qualification clock

        if bestCandidateKey != best.network.networkKey {
            bestCandidateKey = best.network.networkKey
            bestCandidateSince = now
        }

        // MARK: Score comparison

        let currentScore = current.score
        let preferredRelief = best.isPreferred ? policy.minimumScoreAdvantage * 0.25 : 0
        var requiredAdvantage = max(0, policy.minimumScoreAdvantage - preferredRelief)
        if input.activeTraffic.isActive {
            requiredAdvantage += policy.activeTrafficAdvantageBonus
        }
        let advantage = best.score.total - currentScore.total

        let comparison = ScoreComparison(
            currentScore: currentScore.total,
            candidateScore: best.score.total,
            advantage: advantage,
            minimumRequired: requiredAdvantage,
            currentBasis: currentScore.basis,
            candidateBasis: best.score.basis,
            currentConfidence: currentScore.confidence,
            candidateConfidence: best.score.confidence,
            currentSummary: currentScore.summary,
            candidateSummary: best.score.summary
        )

        var notes: [String] = [
            String(format: "Current %.1f (%@, confidence %.0f %%) vs candidate %.1f (%@, confidence %.0f %%)",
                   currentScore.total, currentScore.basis.shortLabel, currentScore.confidence * 100,
                   best.score.total, best.score.basis.shortLabel, best.score.confidence * 100),
            String(format: "Advantage %.1f points, %.1f required", advantage, requiredAdvantage)
        ]
        if input.activeTraffic.isActive {
            notes.append("Active traffic: \(input.activeTraffic.reason)")
        }

        // MARK: Emergency override

        let noInternet = current.isInternetReachable == false
        let emergency = noInternet || currentScore.total < policy.emergencyScoreThreshold
        if emergency {
            let emergencyBar = max(policy.unusableScoreThreshold, currentScore.total + 1)
            guard best.score.total >= emergencyBar else {
                return record(
                    make(
                        input: input,
                        now: now,
                        action: .stay,
                        reason: DecisionReason(
                            code: .insufficientAdvantage,
                            title: "Current network unusable, no replacement",
                            detail: noInternet
                                ? "The current connection has no internet, but no visible saved network scores meaningfully better."
                                : "The current connection is very poor, but no visible saved network scores meaningfully better."
                        ),
                        comparison: comparison,
                        notes: notes
                    )
                )
            }
            let detail = noInternet
                ? "The current connection lost internet access and \(best.network.displayName) is available."
                : "Current connection health is critically low and \(best.network.displayName) is available."
            return record(
                make(
                    input: input,
                    now: now,
                    action: actionFor(mode: input.mode),
                    reason: DecisionReason(code: .emergencySwitch, title: "Emergency switch", detail: detail),
                    target: best.network,
                    comparison: comparison,
                    notes: notes + ["Emergency override skipped cooldown and qualification timers."]
                )
            )
        }

        // MARK: Cooldown and manual protection

        if let lastAutomatedSwitchAt,
           now.timeIntervalSince(lastAutomatedSwitchAt) < policy.effectiveCooldown {
            let remaining = Int((policy.effectiveCooldown - now.timeIntervalSince(lastAutomatedSwitchAt)).rounded(.up))
            return record(
                make(
                    input: input,
                    now: now,
                    action: .stay,
                    reason: DecisionReason(
                        code: .cooldownActive,
                        title: "Cooldown active",
                        detail: "A switch happened recently; waiting \(remaining) s before considering another."
                    ),
                    comparison: comparison,
                    notes: notes
                )
            )
        }

        if let lastManualSwitchAt,
           now.timeIntervalSince(lastManualSwitchAt) < policy.manualSwitchProtection {
            let remaining = Int((policy.manualSwitchProtection - now.timeIntervalSince(lastManualSwitchAt)).rounded(.up))
            return record(
                make(
                    input: input,
                    now: now,
                    action: .stay,
                    reason: DecisionReason(
                        code: .manualSwitchProtection,
                        title: "Manual selection respected",
                        detail: "You chose this network manually; WiFiPilot will not override it for another \(remaining) s."
                    ),
                    comparison: comparison,
                    notes: notes
                )
            )
        }

        // MARK: Switch rate limit

        // Anti-thrash backstop: even when every other gate passes, AUTO will not attempt
        // more than `maximumSwitchesPerHour` switches in a rolling hour. Emergencies are
        // handled above and stay exempt, and OBSERVE never switches so it is not capped.
        if input.mode == .auto, policy.maximumSwitchesPerHour > 0 {
            let attempts = switchAttempts(inLast: 3600, at: now)
            if Double(attempts) >= policy.maximumSwitchesPerHour {
                let oldest = switchHistory
                    .filter { now.timeIntervalSince($0) < 3600 }
                    .min()
                let retry = oldest.map { max(0, 3600 - now.timeIntervalSince($0)) } ?? 0
                return record(
                    make(
                        input: input,
                        now: now,
                        action: .stay,
                        reason: DecisionReason(
                            code: .switchRateLimited,
                            title: "Switch rate limit reached",
                            detail: String(
                                format: "WiFiPilot already attempted %d automatic switches in the last hour (limit %.0f). The next one is allowed in about %.0f s.",
                                attempts,
                                policy.maximumSwitchesPerHour,
                                retry
                            )
                        ),
                        comparison: comparison,
                        notes: notes + ["Rate limit protects against flapping; emergency switches remain exempt."]
                    )
                )
            }
        }

        // MARK: Degradation duration

        let degraded = currentScore.total < policy.degradationScoreThreshold
        if degraded {
            if degradationStartedAt == nil { degradationStartedAt = now }
            let elapsed = now.timeIntervalSince(degradationStartedAt ?? now)
            if elapsed < policy.degradationDuration {
                let remaining = Int((policy.degradationDuration - elapsed).rounded(.up))
                return record(
                    make(
                        input: input,
                        now: now,
                        action: .stay,
                        reason: DecisionReason(
                            code: .degradationNotSustained,
                            title: "Degradation not yet sustained",
                            detail: String(
                                format: "Current score %.1f is below %.1f, but only for %.0f s of the required %.0f s.",
                                currentScore.total,
                                policy.degradationScoreThreshold,
                                elapsed,
                                policy.degradationDuration
                            )
                        ),
                        comparison: comparison,
                        notes: notes + ["Degradation timer has \(remaining) s left."]
                    )
                )
            }
        } else {
            degradationStartedAt = nil
            if advantage < requiredAdvantage {
                return record(
                    make(
                        input: input,
                        now: now,
                        action: .stay,
                        reason: DecisionReason(
                            code: .currentNetworkHealthy,
                            title: "Current network is healthy",
                            detail: String(
                                format: "Current score %.1f is healthy and %@ only leads by %.1f of the required %.1f points.",
                                currentScore.total,
                                best.network.displayName,
                                advantage,
                                requiredAdvantage
                            )
                        ),
                        comparison: comparison,
                        notes: notes
                    )
                )
            }
        }

        // MARK: Candidate qualification duration

        let qualifiedFor = now.timeIntervalSince(bestCandidateSince ?? now)
        if qualifiedFor < policy.candidateQualificationDuration {
            let remaining = Int((policy.candidateQualificationDuration - qualifiedFor).rounded(.up))
            return record(
                make(
                    input: input,
                    now: now,
                    action: .stay,
                    reason: DecisionReason(
                        code: .candidateNotQualified,
                        title: "Candidate not qualified yet",
                        detail: "\(best.network.displayName) must remain available and better for \(remaining) more s."
                    ),
                    comparison: comparison,
                    notes: notes
                )
            )
        }

        // MARK: Candidate quality and signal stability

        if best.score.total < policy.minimumCandidateScore {
            return record(
                make(
                    input: input,
                    now: now,
                    action: .stay,
                    reason: DecisionReason(
                        code: .candidateLowQuality,
                        title: "Candidate quality too low",
                        detail: String(
                            format: "%@ scores %.1f, below the minimum of %.1f.",
                            best.network.displayName,
                            best.score.total,
                            policy.minimumCandidateScore
                        )
                    ),
                    comparison: comparison,
                    notes: notes
                )
            )
        }

        if best.score.basis == .signalOnly,
           let variation = best.rssiStandardDeviation,
           variation > policy.maximumCandidateSignalVariation {
            return record(
                make(
                    input: input,
                    now: now,
                    action: .stay,
                    reason: DecisionReason(
                        code: .candidateSignalUnstable,
                        title: "Candidate signal is unstable",
                        detail: String(
                            format: "%@ has no history and its signal varies by %.1f dB, above the limit of %.1f dB.",
                            best.network.displayName,
                            variation,
                            policy.maximumCandidateSignalVariation
                        )
                    ),
                    comparison: comparison,
                    notes: notes
                )
            )
        }

        // MARK: Advantage

        if advantage < requiredAdvantage {
            if input.activeTraffic.isActive && advantage >= policy.minimumScoreAdvantage {
                return record(
                    make(
                        input: input,
                        now: now,
                        action: .stay,
                        reason: DecisionReason(
                            code: .activeTrafficProtection,
                            title: "Active traffic protection",
                            detail: String(
                                format: "A transfer is in progress, so %@ needs %.1f points of advantage; it has %.1f.",
                                best.network.displayName,
                                requiredAdvantage,
                                advantage
                            )
                        ),
                        comparison: comparison,
                        notes: notes
                    )
                )
            }
            return record(
                make(
                    input: input,
                    now: now,
                    action: .stay,
                    reason: DecisionReason(
                        code: .insufficientAdvantage,
                        title: "Not enough improvement",
                        detail: String(
                            format: "%@ is only %.1f points better; %.1f points are required to justify switching.",
                            best.network.displayName,
                            advantage,
                            requiredAdvantage
                        )
                    ),
                    comparison: comparison,
                    notes: notes
                )
            )
        }

        // MARK: Switch

        let detail = String(
            format: "%@ is %.1f points better (%.1f vs %.1f) and has been qualified for %.0f s.",
            best.network.displayName,
            advantage,
            best.score.total,
            currentScore.total,
            qualifiedFor
        )
        return record(
            make(
                input: input,
                now: now,
                action: actionFor(mode: input.mode),
                reason: DecisionReason(
                    code: .qualifiedImprovement,
                    title: input.mode == .auto ? "Switching to a better network" : "Would switch to a better network",
                    detail: detail
                ),
                target: best.network,
                comparison: comparison,
                notes: notes
            )
        )
    }

    // MARK: - Recovery

    /// Builds the recovery decision after a failed association or failed verification.
    /// Returns nil when there is nothing sensible to revert to.
    public mutating func recoveryDecision(
        failedNetwork: NetworkIdentity,
        previous: NetworkIdentity?,
        at date: Date
    ) -> AutomatedDecision? {
        guard let previous, previous.networkKey != failedNetwork.networkKey else { return nil }
        let decision = AutomatedDecision(
            timestamp: date,
            action: .revertToPrevious,
            target: previous,
            reason: DecisionReason(
                code: .recoveryToPrevious,
                title: "Recovering previous network",
                detail: "\(failedNetwork.displayName) could not be verified after switching. Reverting to \(previous.displayName)."
            ),
            currentNetwork: failedNetwork,
            mode: .auto,
            notes: ["Recovery attempts use system-saved credentials only."]
        )
        lastAutomatedSwitchAt = date
        noteSwitchAttempt(at: date)
        lastDecision = decision
        return decision
    }

    /// Outcome of a switch attempt, for the decision log.
    public func verificationDecision(
        target: NetworkIdentity,
        succeeded: Bool,
        detail: String,
        at date: Date
    ) -> AutomatedDecision {
        AutomatedDecision(
            timestamp: date,
            action: .stay,
            target: target,
            reason: DecisionReason(
                code: succeeded ? .switchVerificationSucceeded : .switchVerificationFailed,
                title: succeeded ? "Switch verified" : "Switch could not be verified",
                detail: detail
            ),
            currentNetwork: target,
            mode: .auto
        )
    }

    // MARK: - Helpers

    public static func preferredOrder(_ lhs: CandidateSnapshot, _ rhs: CandidateSnapshot) -> Bool {
        if lhs.score.total != rhs.score.total { return lhs.score.total < rhs.score.total }
        if lhs.isPreferred != rhs.isPreferred { return !lhs.isPreferred }
        if lhs.score.confidence != rhs.score.confidence { return lhs.score.confidence < rhs.score.confidence }
        return lhs.rssi < rhs.rssi
    }

    private func actionFor(mode: AutomationMode) -> DecisionAction {
        switch mode {
        case .auto: .switchNetwork
        case .observe: .wouldSwitch
        case .off: .stay
        }
    }

    private func make(
        input: DecisionInput,
        now: Date,
        action: DecisionAction,
        reason: DecisionReason,
        target: NetworkIdentity? = nil,
        comparison: ScoreComparison? = nil,
        notes: [String] = []
    ) -> AutomatedDecision {
        var resolvedReason = reason
        if action == .wouldSwitch, reason.code != .observingWouldSwitch {
            resolvedReason = DecisionReason(
                code: .observingWouldSwitch,
                title: "Would switch (observe mode)",
                detail: reason.detail + " OBSERVE mode records this decision without switching."
            )
        }
        return AutomatedDecision(
            timestamp: now,
            action: action,
            target: target,
            reason: resolvedReason,
            comparison: comparison,
            currentNetwork: input.current?.network,
            mode: input.mode,
            activeTraffic: input.activeTraffic,
            notes: notes
        )
    }

    @discardableResult
    private mutating func record(_ decision: AutomatedDecision) -> AutomatedDecision {
        lastDecision = decision
        return decision
    }
}
