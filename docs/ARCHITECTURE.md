# Architecture

```
SwiftUI / AppKit lifecycle
        |
MainActor AppModel (view state, countdown, busy guard)
        |
SessionWorker actor (serial blocking work; no IOKit on main thread)
        |
StretchSession ── BackupStore / SecureFiles
        |                   |
DisplayPlatform        RestoreGuard protocol
        |                   |
MacDisplayPlatform     ProcessRestoreGuard ── readiness handshake
        |                                     |
DCP / private IOAV                     StretchRestoreHelper
                                              |
                                locked record -> targeted reset
```

## Boundaries

- `Edid.swift`: bounded EDID validation, identity, range constraints, CVT arithmetic, DTD encoding and candidate generation. No IOKit.
- `SecureFiles.swift`: create-only synced persistence and stable cross-process locks. No shell invocation.
- `BackupStore.swift`: factory-byte immutability, digest and identity verification.
- `Watchdog.swift`: versioned recovery records, helper readiness and Keep/reset serialization. A separate helper executable prevents accidental recursive self-spawning.
- `StretchSession.swift`: preflight/live revalidation, one-transaction state machine and recovery ownership. Guard injection is mandatory for custom platforms.
- `MacDisplayPlatform.swift`: only private FFI boundary. Dynamically resolves symbols, correlates apply targets with external non-mirrored CoreGraphics displays, and performs targeted reset.
- `AppUI/`: native views and asynchronous worker bridge. No private API calls in views.
  The main window is a grouped SwiftUI `Form` (the System Settings layout) with system pop-up
  buttons, a native `DisclosureGroup`, and a fixed 400 pt width so no state can resize it.
- `PreviewRenderer/`: synthetic offscreen fixtures only.

## State transitions

`Idle -> Prepared -> backup verified -> helper acknowledged -> Pending -> Kept or Restored`

A partially failed apply remains Pending. A failed reset remains Pending. Timeout does not permit Keep. Startup reads exact existing record paths and exposes recovery instead of fabricating filenames. New tests are refused when an older record exists. The helper never applies an EDID or starts another process.

## Performance

Idle UI runs only a low-cost countdown check, not an EDID poll. Discovery is explicit. Pure preset generation is cached by factory EDID bytes. IOKit and disk operations run on a serial actor outside the main thread. No web view, networking, capture/streaming, driver installation or external package dependency.

## Concurrency limitations

The private API can still block its worker indefinitely; an actor is not a timeout for a kernel call. The separate restore process isolates recovery from a blocked UI worker, but it cannot repair a hung OS/driver. Termination never waits synchronously for IOKit; the helper stays armed.
