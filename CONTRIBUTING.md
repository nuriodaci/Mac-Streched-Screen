# Contributing

Open `Package.swift` in Xcode, or use SwiftPM. Keep changes focused and explain why a safety invariant remains true. Run `Scripts/check.sh` before a PR. Add regression tests for every safety bug; tests must use synthetic EDIDs and injected fake platforms/guards, never live display mutations.

Do not add vendor/product-specific timing shortcuts, silent permission/security changes, forced mode application on launch, or claims that EDID compliance guarantees hardware safety. Do not introduce a self-spawning live test harness. Live hardware testing requires explicit informed permission and a documented recovery plan; see docs/SAFETY.md.

Issues should include the app version, macOS version, chip family, monitor model, connection/dock type and a description of what was visible. Do not publish raw EDIDs, account paths, serials or machine UUIDs. Report potential safety/security vulnerabilities privately as described in SECURITY.md.
