# Validation report

This report separates what was **actually verified** from what is **implemented but not
yet run**, and from **known limitations**. It was produced in a Linux container
(Ubuntu 24.04, Swift 6.2 `x86_64-unknown-linux-gnu`) with no macOS SDK, no Xcode and no
Wi-Fi hardware.

The headline: the cross-platform measurement, scoring and decision core is built and
tested; the macOS application target has **never been compiled**, so no part of the app
layer is claimed to work.

---

## 1. Verified here

Commands run in this repository, with their results:

| Command | Result |
|---|---|
| `swift build` | Passes (Swift 6 language mode, `WiFiPilotCore` + `WiFiPilotSimulate`). |
| `swift test` | **82 tests, 0 failures** (56 existing tests retained, 26 new). |
| `swiftc -parse Sources/WiFiPilot/*.swift` | Passes: the macOS app sources are syntactically valid. This is a parse, not a type-check or a build. |
| `swift run wifipilot-simulate` | Passes: OBSERVE hypothetical switch, AUTO switches once, cooldown respects the change, re-evaluation keeps the healthy network, emergency switch on lost internet. |

### What the 82 tests cover

Existing suites (56 tests) still pass unchanged: scoring weights and caps, EWMA/rolling
windows, hysteresis and qualification, cooldown, manual protection, emergency override,
recovery, persistence/decoding, traffic protection and the simulated datasets.

New `Tests/WiFiPilotCoreTests/MonitoringTests.swift` (26 tests) covers the requested
areas with real rolling samples and a fake clock:

- **Throughput variability** — stable samples (CV < 0.05) versus fluctuating samples
  (CV > 0.5) in a `ThroughputSampler`; five-minute window retention; the sampler being
  fed by real `ProbeRoundSummary` rounds.
- **Missing throughput data** — `.notAttempted` and `.unavailable(reason:)` produce no
  average and no sample, and are never treated as zero; scoring marks the throughput
  component unmeasured.
- **Jitter** — successive alternating latencies produce jitter ≈ 20 ms while average
  latency is ≈ 30 ms (proving the two are separate); stable latencies produce ≈ 1 ms;
  changing endpoint restarts the window instead of mixing hosts.
- **Intermittent endpoint failures / probe loss** — 12 attempts with 3 timeouts yield a
  25 % rate with full confidence; timeouts, refusals, DNS failures and path failures are
  counted separately; the method string is "TCP connection attempts (not ICMP)"; old
  attempts expire from the window.
- **Reachability / captive portal / DNS** — redirects and unexpected content classify as
  captive portal; TCP without HTTP verification classifies as restricted/unverified and
  is *not* verified internet; DNS failure and no-path classify separately; only
  `.verifiedOpen` counts as verified.
- **Scoring integration** — connectivity classes cap scores (portal ≤ 25, restricted
  ≤ 45, offline ≤ 20), and probe loss is reported as "Probe loss", not packet loss.
- **Active-transfer protection** — the throughput policy defers during user traffic, and
  the engine refuses a switch that would otherwise qualify.
- **OFF mode and defaults** — OFF's explanation states monitoring continues, the engine
  returns `automationOff` while the analyzer still produces metrics, and defaults are
  OBSERVE, no throughput probe, 90 s interval, 4 automatic switches/hour.
- **Switch rate limit** — the third switch inside an hour is refused with
  `switchRateLimited`; the history rolls off after an hour; emergency switches are exempt.

---

## 2. Implemented but not run (macOS app layer)

These were written and syntax-parsed, but not compiled, launched or exercised:

- `NetworkMonitor` rewrite: three successive TCP probes to **one** endpoint per round,
  `ProbeFailure` classification from `NWError` (POSIX refused/timeout/unreachable/cancelled,
  DNS), HTTP result typed as success/redirect/unexpected content/failure,
  `ConnectivityClassifier` output, and `ThroughputOutcome` for the controlled download.
  The POSIX error mapping and `NWConnection.waiting` handling in particular need a
  compile and a real network to confirm.
- `ConnectionHealthMonitor`: feeds `ProbeRoundSummary` into `StabilityAnalyzer`, writes
  reachability straight from the connectivity classification (no debounce that could
  over-report), and records a failed throughput probe as a failure.
- `AppState`: samples user traffic *before* deciding on a throughput probe, asks
  `ThroughputProbePolicy` whether to measure, tracks attempt/failure timestamps for
  backoff, maps connectivity to engine reachability (portal is reported but is not an
  emergency), and exposes `throughputStatus` for the UI.
- `SwitchingManager`: captures `networksetup` stderr and refuses the CoreWLAN fallback
  for secured networks (credential-less association is only attempted for open ones).
- UI: "Probe loss" labels, approximate throughput (`≈`), connectivity display names,
  throughput interval control and the measurement-methodology notes.
- Menu-bar item, dashboard, settings form, notifications and Launch at Login are
  untouched except for the label/text changes above.

The following app-level behaviours are therefore **unverified**:

| Area | Status |
|---|---|
| Compile on macOS 14+ with Xcode 16 / Swift 6 | Not run |
| CoreWLAN scan, RSSI, channel/security mapping | Not run |
| Swift 6 strict concurrency in the app target (actors, `@unchecked Sendable` helpers) | Not run |
| Code signing, notarisation, hardened runtime | Not run |
| Location Services prompt and scan results without permission | Not run |
| Menu-bar extra, panel layout, `LSUIElement` behaviour | Not run |
| Launch at Login via `SMAppService` (including approval flow) | Not run |
| `networksetup` association, timeout, verification and recovery on hardware | Not run |
| Captive-portal detection against a real portal | Not run |
| Controlled throughput measurement against the Cloudflare endpoint | Not run |
| Real probe-loss/jitter values on a live link | Not run |

### Checklist for the macOS machine

```bash
# 1. Build (this is the first real compile of the app target)
xcodebuild -version            # expect Xcode 16+, Swift 6
./Scripts/build-app.sh         # debug: ./Scripts/build-app.sh debug
open build/WiFiPilot.app

# 2. Core checks in the running app
#    - menu-bar icon appears, no Dock icon
#    - Location prompt appears; grant/deny both explain themselves
#    - OBSERVE logs decisions without switching
#    - jitter changes between probe rounds while latency stays separate
#    - with throughput disabled, throughput tiles show "—" (not 0)
#    - enable throughput: one small download roughly every 90 s, skipped during a transfer
#    - join a network from the list: association, verification, decision log entry
#    - turn on Launch at Login, approve it in System Settings, verify after logout/login

# 3. Before enabling AUTO
#    - let it run in OBSERVE on a real network for a day
#    - confirm the hourly cap and cooldown appear in the decision log
#    - only then switch to AUTO
```

If the first compile reports SDK or concurrency diagnostics, treat them as expected
first-build issues rather than regressions in tested logic.

---

## 3. Remaining limitations

- **No privileged helper.** Automation runs only while the app is running.
- **Probe loss is TCP-based.** macOS exposes no unprivileged ICMP, so "loss" means
  unanswered TCP connection attempts to one endpoint over a rolling window, with the
  failure kinds broken out. The UI says "Probe loss" for this reason.
- **Throughput is approximate by construction.** A 250 KB download every ≥90 s cannot
  measure a gigabit link precisely; it exists to describe variability over a five-minute
  window at a bounded cost (≈10 MB/hour at the default cadence).
- **Throughput is deferred, not queued.** If a transfer is active when a probe is due, the
  measurement simply does not happen that round.
- **Captive portals are detected, not solved.** WiFiPilot will not open a sign-in page or
  switch in a panic; the portal is reported, capped in scoring, and may lead to a normal
  qualified switch.
- **A single endpoint.** Latency, jitter and probe loss all use `1.1.1.1:443`. A problem
  specific to that endpoint would look like a network problem; the HTTP check uses a
  different host, which limits (but does not remove) that risk.
- **No BSSID-level steering**, and saved-network detection still depends on
  `networksetup -listpreferredwirelessnetworks`.
- **Enterprise/802.1X networks** need interactive authentication that WiFiPilot
  deliberately does not handle; verification fails and recovery runs instead.
