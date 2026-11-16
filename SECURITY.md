# Security and display-safety reports

For vulnerabilities or recovery failures that could affect other users, use GitHub's **Report a vulnerability** / private vulnerability reporting if enabled on the published repository. Maintainers must enable that feature before public distribution. If unavailable, open a minimal issue asking for a private reporting channel; do not post an exploit, personal EDID or sensitive logs.

Include version, OS version, chip family, monitor/connection type, expected/observed behaviour and whether recovery worked. Do not include Mac serial numbers, hardware UUIDs, credentials or raw monitor dumps by default.

Only the current preview branch is maintained. There is no promised security-response SLA. The app is not privileged and must not request SIP/Gatekeeper changes. The unsupported Apple API and display-driver hangs remain residual risks, not issues that a checksum or notarization can eliminate.
