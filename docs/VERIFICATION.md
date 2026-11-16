# Verification report — 0.1.0 preview

## Current review: 2026-11-15

Verified locally on macOS 26.5, Apple Silicon, Swift 6.3.2 in Swift 5.10 package language mode.
This review covers software behaviour and synthetic UI rendering. No physical display mode was
applied or reset. No cross-device compatibility or production certification is claimed.

| Check | Result |
| --- | --- |
| Debug build with warnings as errors | Passed |
| Release build with warnings as errors | Passed |
| Debug tests | 51 tests, 0 failures |
| Release tests | 51 tests, 0 failures |
| Shell syntax validation | Passed |
| Release `.app` with nested restore helper | Built |
| `codesign --verify --deep --strict` | Passed; local ad-hoc signatures |
| Bundled CLI version/help | Passed |
| Unknown CLI command and helper with missing arguments | Rejected with exit code 1 |
| Synthetic UI previews | 12 states rendered |
| Visual inspection | Light/dark, expanded, empty, confirmation, countdown and long-name/custom states reviewed |
| Native window layout regression | Fixed width, expansion/collapse and long-error wrapping passed |
| Source hygiene | Source/script paths checked; no local user path embedded |

All test display platforms and recovery guards are injected fakes. The helper handshake test uses
a shell-only stub. Automated checks never launch the real hardware recovery helper with a state file.

## Changes made during this review

- Native SwiftUI cards, semantic system colors, readable status feedback, distinct accessibility
  labels and an explicit empty state; reproducible code-drawn icon and public screenshots.
- Edited custom values are identified as Custom instead of displaying an unrelated preset.
- Keep/Revert reload display snapshots so the UI reflects the resulting override state.
- Refresh is refused while a transaction is pending, including the keyboard/menu command.
- Countdown timers exist only during a pending transaction. They tolerate run-loop scheduling,
  run in common modes and publish remaining time only when the displayed second changes.
  There is no idle timer or repeated idle hardware polling. No CPU/battery benchmark is claimed.
- State reads use nonblocking open before validating file type, avoiding a named-pipe hang.
  Reads themselves are bounded in addition to the file-size check. Regression tests cover named
  pipes, exact limits and oversized files.
- Confirmation copy describes an attempted override removal rather than promising restoration
  of every aspect of the previous desktop state.

## Existing regression coverage also exercised

- Create-only backups, digest and identity checks, missing sidecars and override-as-factory refusal.
- Malformed/checksummed EDID fuzzing (2,000 cases), range validation and timing generation.
- Backup → acknowledged helper → apply ordering; helper failure prevents mutation.
- Partial/late apply failures, expired Keep, stale preparation, unplug and duplicate identity.
- Keep/helper locking (30 races); failed restores preserve recovery records.
- Read-only discovery and startup; exact persisted paths for interrupted transaction recovery.
- Symlink/oversized state rejection and corrupt-record recovery behaviour.
- Experimental-risk acknowledgement and hardware-free UI preview startup.

## Remaining release qualification

- Live apply/Keep/timeout/force-quit cycles, sleep/wake and hot unplug/reconnect on a documented
  matrix of Macs, macOS versions, monitors and cables. Earlier development notes report loss of
  output; those tests are not passing qualification evidence.
- Physical picture quality and actual stretch behaviour. EDID acceptance cannot establish these.
- Recovery when the private IOKit API, display driver or kernel hangs.
- Interactive VoiceOver/keyboard traversal and increased-contrast testing on supported macOS versions.
- Developer ID signing, Apple notarization and downloaded-app Gatekeeper validation.
- GitHub-hosted CI execution. The workflow exists; no remote run was created here.
- Thread/address sanitizers were not rerun during this review; previous report claims are not
  presented as evidence for the current revision.

The repository and local bundle are prepared for source review and an explicitly labelled
experimental preview. Hardware qualification and distribution credentials are still required
before making a production-readiness claim. See [RELEASING.md](RELEASING.md).
