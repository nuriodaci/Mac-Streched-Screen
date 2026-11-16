# Release checklist

This project is currently an **experimental preview**. Do not label an unqualified build production-ready.

## Before publishing source

- Run `Scripts/check.sh` on a clean checkout.
- Review tests, concurrency changes, licensing and `git diff --check`.
- Confirm no personal paths, monitor dumps, serials, credentials, crash logs or generated build products are tracked.
- Review SECURITY.md and the compatibility limitations in README.md.
- CI tests must use only fakes/synthetic EDIDs. Do not add a live-display smoke test.

## Compatibility qualification (manual, explicit consent only)

Record macOS version, chip family, monitor model and connection type. Do not collect the Mac's hardware serial/UUID. Qualify normal display discovery, test timeout, visible Keep, explicit Restore, GUI force-quit, sleep/wake, hot unplug/reconnect and ambiguous dual-monitor refusal. Verify real video output, not only the return code or changed EDID. Stop after loss of output/system hang. A single successful machine is not a generic support matrix.

No such cross-hardware qualification is claimed for 0.1.0.

## Local bundle

```sh
./Scripts/build-app.sh release
codesign --verify --deep --strict --verbose=2 dist/Mac-Streched-Screen.app
```

The helper is signed first, then the containing app. Do not use `codesign --deep` as a substitute for signing nested code correctly.

## Public binary

Requires the maintainer's Apple Developer ID and notarization credentials; none are stored in the repo.

```sh
SIGN_IDENTITY='Developer ID Application: Your Organization (TEAMID)' ./Scripts/build-app.sh release
ditto -c -k --keepParent dist/Mac-Streched-Screen.app dist/Mac-Streched-Screen.zip
xcrun notarytool submit dist/Mac-Streched-Screen.zip --keychain-profile YOUR_PROFILE --wait
xcrun stapler staple dist/Mac-Streched-Screen.app
xcrun stapler validate dist/Mac-Streched-Screen.app
spctl --assess --type execute --verbose=2 dist/Mac-Streched-Screen.app
# Recreate the zip after stapling, then publish its SHA-256.
ditto -c -k --keepParent dist/Mac-Streched-Screen.app dist/Mac-Streched-Screen.zip
shasum -a 256 dist/Mac-Streched-Screen.zip
```

Do not disable Gatekeeper/SIP or instruct users to do so. Apple may reject/not notarize private-API software; an ad-hoc local build is not equivalent to an approved download. Mac App Store distribution is not a target.
