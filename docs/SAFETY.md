# Safety model and residual risks

## Explicit invariants

1. Discovery, CLI `list`, UI previews and automated tests do not mutate live display state.
2. Apply requires one current prepared change, no active/persisted transaction, a unique connected target and unchanged live capabilities.
3. A verified factory backup and a helper-readiness acknowledgement must precede the private apply call.
4. Recovery state is established **before** entering the blocking private API. An apply error does not cancel recovery.
5. Keep and helper reset acquire the same record lock; cancellation cannot race a later reset. Keep checks the deadline again after reading the display.
6. A restore failure preserves its record. Corrupt records block new tests instead of being ignored.
7. A late completion after the recovery deadline requests an additional reset: the apply call may have completed after the helper.
8. No startup recursion, automatic startup mode reset, self-spawning helper, permanent daemon, or vendor-specific timing table.

## What this does NOT guarantee

- A monitor accepting a timing, producing a visible image, or stretching it.
- Recovery if the kernel, display coprocessor, WindowServer or machine is hung.
- That the private API returns promptly, or that the helper can identify an unreadable/disconnected target.
- Exact restoration of the previous refresh rate, HDR/audio state, color profile or window arrangement.
- Support on every Apple Silicon machine, macOS version, cable, dock or monitor. Presence of exported symbols is not certification.
- Protection against another malicious process running as the same user. There are no elevated privileges; per-user files/checksums prevent accidental corruption, not an attacker controlling the account.

The UI therefore requires an experimental-risk acknowledgement and two deliberate actions. Keep has no default Return-key shortcut. The current release must remain a preview until independent hardware qualification is complete.

## Persistence

`~/Library/Application Support/Mac-Streched-Screen/`

- `monitors/<identity>/factory-edid.bin`, SHA-256 sidecar and manifest: immutable create-only backup.
- `pending/<random-UUID>.json`: bounded versioned identity/mode/deadline record.
- `.ready`: helper readiness acknowledgement, removed on cancellation/exit.
- `.lock`: stable inode used to serialize Keep/reset. Empty lock files can remain; they do not launch anything.
- `app.lock` and `operation.lock`: lifetime single-instance and explicit mutation serialization.

Directories are private (0700), new files are 0600. State reads reject final-component symlinks, wrong ownership, non-regular files and oversized data. Factory loading verifies identity and checksum, not only the filename. Checksums are not signatures.

## Troubleshooting

If no factory backup exists while a recognized override is live, Refresh does **not** reset automatically and does **not** archive the override. Use explicit Restore, then Refresh.

If a record is malformed, do not delete it while an override might still be active. First reconnect/reboot to recover factory state, verify the display, then move the corrupt record out of `pending/` for diagnosis. Do not delete factory backups to hide a conflict.

If reset repeatedly fails, do not keep retrying modes. Stop testing, reconnect the display and collect a redacted issue report. Monitor serials, account paths and raw EDID can be identifying; do not post them by default.

## Live hardware testing policy

Never run live apply/reset tests in CI or as part of `swift test`. A maintainer must explicitly authorize each hardware test after saving work, arranging an independent recovery screen/path and documenting OS, chip family, monitor model, connection and result. Do not run a live test on an unattended person's machine.
