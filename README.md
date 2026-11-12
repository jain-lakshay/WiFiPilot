# WiFiPilot

An intelligent, self-contained Wi-Fi manager for macOS. WiFiPilot watches the quality of
your current connection, evaluates the networks you have saved, and switches only when a
different network is demonstrably **more reliable** — not merely faster.

Menu-bar first, native SwiftUI, no telemetry, no third-party runtime dependencies.

---

## Philosophy: consistency over peak speed

Signal bars and speed tests reward the wrong thing. A 300 Mbps link that collapses to
5 Mbps every 30 seconds is worse for a video call than a steady 45 Mbps link.

The scoring engine therefore:

- **Log-scales throughput.** 40 → 60 Mbps is a small quality win; 40 → 200 Mbps is a large one.
- **Damps rewards for variability.** Throughput quality is multiplied by its own
  consistency, so bursts cannot buy a high score.
- **Scores stability explicitly** from throughput variation, signal variation, latency
  spikes, probe loss and recent disconnections. Stability weight increases with your
  "stability preference" setting.
- **Separates measured facts.** Latency, jitter, probe loss, path/DNS/TCP/HTTP
  reachability and approximate throughput are distinct measurements with distinct
  labels; none of them is inferred from another.
- **Refuses to invent data.** Only the connected network has live internet measurements.
  Every other network is scored from history or signal only, and the UI labels which.

Example from the shipped simulation (`swift run wifipilot-simulate`):

```
steady 45 Mbps   93.1
fluctuating 40-60 88.8
bursty peaks    75.6      (108 Mbps average from rare 300 Mbps bursts)
```

## Anti-flapping safeguards

A switch requires **all** of these. Each is configurable.

| Safeguard | Default |
|---|---|
| Rolling observation window | 60 s |
| Current network must stay degraded | 10 s |
| Candidate must stay available and better | 15 s |
| Minimum score advantage | 12 pts (0–100 scale) |
| Post-switch cooldown | 120 s |
| Manual-step protection | 120 s |
| Extra advantage while traffic is active | +10 pts (threshold 2 Mbps) |
| Candidate must clear a minimum score | 45 pts |
| Emergency override | current score < 20 or verified internet lost |
| Automatic switch attempts per rolling hour | 4 |

Emergency override is the only path that bypasses the waiting windows and the hourly
cap, and it still respects OFF mode and manual pause. A manual switch always suppresses
automation for the protection window. Repeated switches are also bounded by the cooldown
after a *failed* attempt and by the rolling-hour cap, which counts successful, failed and
recovery attempts alike.

A captive portal is **not** treated as an emergency: switching networks cannot remove the
portal. It is reported, capped in scoring, and can lead to a normal qualified switch.

## Modes

- **OFF** — automation disabled. Monitoring (signal, latency, probe loss, reachability)
  continues and the UI still shows live quality; the engine never evaluates candidates
  and never switches.
- **OBSERVE** (default) — evaluates and records hypothetical decisions, never switches.
  AUTO is never enabled by default.
- **AUTO** — switches when the engine confirms a sustained, meaningful improvement.

## Architecture

```
Sources/
  WiFiPilotCore/            pure Swift, no Apple frameworks, fully testable
    Models/                 NetworkIdentity, observations, metrics, health samples
    Analysis/               EWMA + rolling windows, StabilityAnalyzer, scoring,
                            ProbeDiagnostics (failure/loss/connectivity),
                            LatencyStatistics (temporal jitter), ThroughputSampler
    Engine/                 DecisionEngine, policy, traffic assessment, decisions
    Persistence/            JSON store, settings, profiles, decision records
    Simulation/             synthetic network datasets
  WiFiPilot/                macOS app (SwiftUI)
    AppState.swift          orchestration + published UI state (MainActor, @Observable)
    WiFiScanner.swift       CoreWLAN scanning/reading, location permission
    NetworkMonitor.swift    NWPathMonitor + TCP latency + DNS + HTTP reachability
    ConnectionHealthMonitor actor feeding StabilityAnalyzer
    TrafficMonitor.swift    getifaddrs byte counters → active-traffic protection
    SwitchingManager.swift  association via system credentials + verification/recovery
    DecisionLogger.swift    decision records and verification outcomes
    SupportServices.swift   ServiceManagement launch-at-login, notifications
    MenuBarInterface.swift  menu-bar panel
    DashboardInterface.swift overview / networks / compare / decisions / history
    SettingsInterface.swift settings form
  WiFiPilotSimulate/        hardware-free decision-engine walkthrough
Tests/WiFiPilotCoreTests/   82 tests, no Wi-Fi hardware required
                            (incl. MonitoringTests: throughput windows, jitter,
                            probe loss, connectivity, missing data, active transfers)
```

`DecisionEngine` is a value type driven by explicit inputs and an injected clock. It has
no timers, no I/O and no CoreWLAN dependency, which is why hysteresis, cooldown,
qualification, emergency and recovery behaviour are all unit-tested deterministically.

## Build and run

Requirements: macOS 14 (Sonoma) or later, Xcode 16 / Swift 6 toolchain.

```bash
# tests for the engine, scoring and persistence (no Wi-Fi needed)
swift test

# hardware-free decision trace: OBSERVE and AUTO, hysteresis, cooldown, emergency
swift run wifipilot-simulate

# build and run the menu-bar app
./Scripts/build-app.sh
open build/WiFiPilot.app
```

For a signed build with stable Location permission and Launch at Login:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./Scripts/build-app.sh
```

Debug build: `./Scripts/build-app.sh debug`.

> The engine library, tests and simulation build on any platform with Swift 6
> (including Linux). The app target is only declared on macOS, because SwiftUI,
> CoreWLAN and friends do not exist elsewhere.

## Permissions

WiFiPilot requests **Location Services** on first launch. Since macOS 10.15 (enforced
strictly from macOS 14) the SSID, BSSID and scan results are hidden from apps without it.
Without permission the app still monitors reachability and latency, but shows no network
names and cannot scan; the UI says so explicitly. Enable it in
**System Settings → Privacy & Security → Location Services → WiFiPilot**.

The app is a menu-bar accessory (`LSUIElement`), so it has no Dock icon. Launch at Login
uses `SMAppService.mainApp` and may need approval in **System Settings → General → Login
Items**. A stable signing identity makes both permissions behave consistently; ad-hoc
signed builds may be re-prompted.

## What is measured, and what is not

| Metric | Source | Notes |
|---|---|---|
| RSSI, noise, SNR | CoreWLAN | SNR needs a noise floor, which macOS often omits |
| Channel, band, security | CoreWLAN | |
| Latency | median of successive TCP handshakes to 1.1.1.1:443 | 3 attempts per round, 1.5 s timeout each |
| Jitter | mean absolute difference between **successive probes to that same endpoint**, smoothed RFC 3550 style | kept separate from average latency; never compares different hosts |
| Probe loss | classified probe attempts over the rolling window | timeouts, refusals, DNS failures and path failures counted separately; **not ICMP packet loss** |
| DNS health | `getaddrinfo` timing | |
| Path / TCP / HTTP | `NWPathMonitor`, TCP attempts, verified HTTP fetch | classified as verified open, captive portal, restricted, DNS failure, offline or unverified |
| Throughput | optional 250 KB download, 90 s minimum interval, 5 min rolling window | **off by default**, skipped during active transfers, labelled approximate |
| Active traffic | `getifaddrs` byte deltas on the Wi-Fi interface | 32-bit counters; wrap is treated as reset |
| Candidate quality | RSSI stability + recorded history | never presented as a live measurement |

Unconnected networks cannot be measured for latency, loss or speed without joining them,
so WiFiPilot does not pretend otherwise. Historical metrics recorded during earlier
associations are stored per SSID and used — clearly marked `History` — and signal-only
scores are capped at 60 so an unknown network cannot masquerade as a confident winner.

## Switching

1. Re-scan and confirm the candidate is still visible and still saved.
2. Associate using credentials macOS already stores: `networksetup -setairportnetwork`
   (login Keychain). Its stderr is captured so a failure is explained, not guessed.
   CoreWLAN's credential-less association is used only as a fallback for **open**
   networks; a secured network is never left to a silent failure or a password prompt.
3. Wait for the association to appear (up to 25 s).
4. Verify internet access with an HTTP check (three attempts, 2 s apart).
5. Record the outcome against the original decision.
6. On failure, revert to the previous network and start a cooldown.

WiFiPilot never asks for, stores or passes Wi-Fi passwords; it never turns Wi-Fi off and
never resets the interface.

## Privacy

All monitoring data — samples, profiles, decisions — is a single JSON file in
`~/Library/Application Support/WiFiPilot/wifipilot-history.json`, pruned by your retention
setting (default 30 days). No accounts, no analytics, no remote logging, no browsing data.
The only outbound traffic is the probe set described above.

## Known limitations

- **No background daemon.** Switching runs while the app is running; there is no privileged
  helper, so the app must be launched (optionally at login).
- **Saved-network detection** uses `networksetup -listpreferredwirelessnetworks` because
  CoreWLAN exposes no public API for it. Enterprise/managed profiles may list differently.
- **Association** relies on system-saved credentials. Networks needing extra
  authentication (802.1X prompts, captive portals) will fail verification and trigger
  recovery rather than a credential prompt.
- **No BSSID-level steering.** Switching is per SSID; macOS roams between BSSIDs itself.
- **Throughput is optional and approximate.** One 250 KB HTTP download every 90 s at
  most (≈10 MB/hour) feeds a five-minute rolling window, so variation is meaningful but
  the absolute figure includes TLS and server time. It is skipped while your own traffic
  exceeds 1 Mbps, and a failed measurement is reported as unavailable — never as zero.
- **Probe loss is not ICMP loss.** macOS offers no unprivileged ICMP, so the estimate is
  unanswered TCP connection attempts to one known endpoint, with failure kinds broken out.
- Hidden networks are skipped (empty SSID) and secure networks are never joined without
  saved credentials.
- **Build status.** The shared core compiles under Swift 6 language mode and all 82 tests
  pass on Linux. The SwiftUI/CoreWLAN app layer was written for macOS 14 and
  syntax-checked only: this repository was prepared in a Linux environment, so the app
  target has **not** been compiled, launched or exercised against real hardware here.
  `VALIDATION.md` separates verified behaviour from implemented-but-untested behaviour.
  Build it on macOS with `./Scripts/build-app.sh`, then verify OBSERVE mode on real
  hardware before enabling AUTO.
