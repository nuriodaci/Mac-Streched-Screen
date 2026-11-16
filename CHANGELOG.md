# Changelog

## 0.1.0 — Experimental preview

### Interface and final review

- Add a native settings-style interface with display details, light/dark appearance, empty state,
  persistent operation feedback and a matching reproducible app icon.
- Show Custom when edited inputs differ from a preset; distinguish width/height for accessibility.
- Refresh display state after Keep/Revert and prevent refresh commands during pending tests.
- Run the countdown timer only during a pending change, including common run-loop modes.
- Reject named-pipe state files without blocking and bound reads even if a file grows after inspection.
- Add synthetic screenshots and regression coverage for custom input and bounded state reads.

### Safety hardening

- Replace caller/self-spawned watchdog with a separate restore-only executable and readiness handshake.
- Remove the recursive live hardware test harness; tests inject fake platforms and guards.
- Preserve recovery after partial apply errors; forbid late/default-key confirmation and concurrent tests.
- Serialize Keep/reset; revalidate the live monitor and generated EDID before mutation.
- Make startup and refresh read-only; reuse real persisted record paths on recovery.
- Reject unknown limits, malformed EDIDs, unaligned/non-4:3 modes and override-as-factory backups.
- Restrict apply targets to unique active external non-mirrored displays.
- Move blocking work off the UI thread and remove repeated idle EDID polling.
- Harden persistence and add synthetic regression, fuzz, race and sanitizer coverage.

### Project quality

- Add CI, release packaging with separately signed helper, licensing/attribution, security and architecture documentation.
- Remove personal monitor fixtures and paths; previews use synthetic data.
- Clearly mark private-API and hardware-qualification limitations. No production compatibility claim.
