# RegionMonitor

An iOS app for watching circular regions and recording everything CoreLocation tells you about them — entries, exits, state determinations, raw fixes, visits, authorisation changes and app launches — into Core Data, with export to CSV, JSON and GeoJSON for offline analysis.

It's built to answer the question "did that exit event actually happen, or did the fix just wobble?", so every event carries the accuracy of the fix behind it and its distance to the region boundary.

## Getting it running

There's an `.xcodeproj` in the repo, so:

```bash
open RegionMonitor.xcodeproj
```

Then two things before you build:

1. Select the **RegionMonitor** target -> **Signing & Capabilities** -> pick your team. `DEVELOPMENT_TEAM` ships empty and `PRODUCT_BUNDLE_IDENTIFIER` is `com.woosmap.app.citytime`, so change the bundle ID if you need one your team owns.
2. Pick a real device. The Simulator can fake a location, but region crossings and background relaunches are unreliable there - you want hardware for anything you plan to trust.

Everything else is already wired: deployment target is iOS 17.0, the Info.plist carries both location usage strings, the `location` background mode and the file-sharing keys, and and the asset catalog has an accent colour and an app icon.

Background Modes needs no capability toggle and no entitlements file - for location it's purely the `UIBackgroundModes` array in Info.plist, which is already there. Xcode shows it ticked under Signing & Capabilities on its own.

If you'd rather drop to iOS 16, the only blockers are `ContentUnavailableView` and the `.topBarLeading` toolbar placement in the views; swap those for a plain `VStack` and `.navigationBarLeading` and nothing else needs to change.

### Regenerating the project file

`Tools/generate_xcodeproj.py` rebuilds the whole `.xcodeproj` from whatever is on disk under `RegionMonitor/`:

```bash
python3 Tools/generate_xcodeproj.py
```

Object IDs are hashed from each file's path and role rather than randomised, so re-running on an unchanged tree gives you a byte-identical `project.pbxproj`. Add a Swift file anywhere under `RegionMonitor/` and re-run - it lands in the right group with no merge conflict. Top-level folders map to Xcode groups; `App`, `Persistence`, `Location`, `Export` and `Views` are ordered explicitly, anything new gets appended alphabetically.

Adding files through Xcode's UI works fine too. The generator is just an escape hatch for when a pbxproj gets tangled.

### Layout

```
RegionMonitor.xcodeproj/
RegionMonitor/
  App/           AppDelegate, SwiftUI entry point, app-state cache
  Persistence/   Core Data stack, model, log writer
  Location/      CLLocationManager wrapper, CLMonitor engine, region store
  Export/        CSV / JSON / GeoJSON serialisers
  Views/         SwiftUI screens
  Resources/     Assets.xcassets
  Info.plist
Tools/
  generate_xcodeproj.py
```

There's no `.xcdatamodeld` file. The model is built in code in `CoreDataStack.makeModel()`, which keeps the schema readable in a diff and avoids the usual merge pain on a binary model file.

## How it behaves when the app isn't running

Region monitoring survives the app being suspended, backgrounded, and terminated — including a force-quit from the app switcher. When you cross a boundary, iOS relaunches the app in the background and calls `application(_:didFinishLaunchingWithOptions:)` with the `.location` key set, then delivers the event on the monitor's `events` stream.

Three details make or break this, and all three are handled in `AppDelegate`:

- The `CLLocationManager` is created and its delegate assigned **synchronously** inside `didFinishLaunching`, and the `CLMonitor` is opened from the same method. Defer either to a later runloop tick and the queued event is dropped on the floor. CoreLocation is stricter about the monitor than it was about the delegate: it *stops monitoring* a condition when an event is pending for it and nothing has opened the monitor to receive it.
- The Core Data store is opened in that same method, before the first callback can arrive.
- The persistent store is set to `completeUntilFirstUserAuthentication` file protection. Without this, a background relaunch while the device is locked can find the store unreadable, and you lose exactly the events you most wanted.

Writes go through `LogWriter`, which wraps each save in a `beginBackgroundTask` assertion. A background relaunch gives you roughly ten seconds; that assertion stops a save being cut off partway.

Two caveats worth knowing:

- After a device **reboot**, nothing is delivered until the user unlocks the phone once.
- Significant-change monitoring and visit monitoring are also enabled, which gives you extra wake-ups between region events and makes the trail more useful when you're reconstructing what happened.

## Reading the log

Each entry records the event type, timestamp, the region involved, the coordinate and its horizontal accuracy, the app state at the time (foreground / background), and battery level.

The `detail` column on enter and exit events is the interesting one:

```
distToCentre=138m radius=150m margin=-12m hAcc=65m
```

That says the fix was 12 m inside a 150 m circle, but the fix itself was only accurate to 65 m. A transition where `|margin|` is smaller than `hAcc` is inside the noise floor — it tells you the OS *thinks* you crossed, not that you did. A run of those alternating enter/exit in quick succession is flapping, not movement.

`prev=` on each entry is the state CoreLocation last reported for that condition, so `prev=unknown` marks a first determination and `prev=unsatisfied state=satisfied` marks an actual crossing. `eventAge=` is how long the event sat before it reached the log.

**Check region states** in the Log tab's overflow menu reads back the record CoreLocation has persisted for every condition. Note that this is weaker than it looks: `CLMonitor` has no equivalent of the old `requestState(for:)`, so it cannot force a fresh determination — it replays the last event, which may be hours old. Each such line is tagged `(persisted record, not a fresh fix)` and carries the event's own `date=`.

A few things that reduce flapping in practice, if that's what you're chasing:

- Keep radii at 100 m or more. Apple's guidance is roughly 100–200 m minimum; smaller circles fire on GPS noise alone.
- Discard transitions where the fix's `horizontalAccuracy` exceeds some fraction of the radius, rather than treating all callbacks as equal.
- Hold an exit for a debounce window and cancel it if a re-entry arrives inside that window.

The log gives you the raw material to pick thresholds from your own data rather than guessing.

## Exporting

The Export tab writes to `Documents/Exports/` and offers a share sheet. Three formats:

- **CSV** — one row per event, opens in Numbers or Excel. Timestamps are ISO 8601 UTC with milliseconds.
- **JSON** — same data with a small envelope carrying OS version and app version.
- **GeoJSON** — points only, ready to drop into geojson.io, QGIS or Kepler. Usually the fastest way to *see* whether a fix really left the circle.

Because `UIFileSharingEnabled` is set, those files also appear under **On My iPhone → CityTime** in the Files app and over USB in Finder. That matters when the device has been out in the field and you want the data off it without a network round trip.

## Housekeeping

`LogWriter.prune(olderThan:)` batch-deletes old entries and merges the deletions back into the view context, so the UI doesn't keep showing rows that no longer exist. Both the 7-day prune and delete-all are in the Log tab's overflow menu. Worth running before a long trial, since streaming fixes continuously will fill the store quickly.

## Monitoring API

Regions are monitored with `CLMonitor` and `CLCircularGeographicCondition` (iOS 17+), in `Location/RegionMonitorEngine.swift`. `CLLocationManager` still handles authorisation, significant-change and visit monitoring, and one-shot/continuous fixes — none of which is deprecated.

The old `CLCircularRegion` path is *soft* deprecated: the header marks it `API_DEPRECATED_WITH_REPLACEMENT(..., ios(7.0, API_TO_BE_DEPRECATED))`, and `API_TO_BE_DEPRECATED` is `100000`, a version no deployment target ever reaches. So it compiles without a warning at any deployment target — the absence of a warning is not evidence it's current.

Four behavioural differences fall out of the swap, and they matter for a tool like this:

- **No `requestState(for:)`.** There is no way to ask CoreLocation to resolve a condition on demand; you can only read back the last event it persisted. The independent second opinion the old code logged after every crossing is gone.
- **Conditions are persisted by CoreLocation**, in `Library/CoreLocation/RegionMonitor/RegionMonitorConditions.monitor` inside the data container (CoreLocation names that folder after the bundle id or the process name). That file is protected, so the monitor cannot be opened before the first unlock after boot — the engine waits on `protectedDataDidBecomeAvailableNotification`.
- **No per-direction filtering.** `CLCircularRegion` had `notifyOnEntry` / `notifyOnExit`; conditions report both directions. The flags are still honoured, but the filtering happens in the app, and a suppressed crossing is logged as `region.state` with `suppressed=entry|exit` rather than dropped.
- **The monitor's name must be alphanumeric.** A dot or underscore makes `CLMonitor(_:)` throw `NSInternalInconsistencyException("Monitor name is not valid")` at launch. The header doesn't say so.
- **No `monitoringDidFailFor` callback.** Authorisation and limit problems surface as per-event flags (`authDenied`, `conditionLimitExceeded`, `accuracyLimited`, …), which are iOS 18+ only. On iOS 17 a condition that cannot be monitored is simply quiet.

The 20-condition cap in `LocationService.maxMonitoredRegions` is now self-imposed: it was CLLocationManager's documented limit, and CLMonitor doesn't publish one. `conditionLimitExceeded` on an event is how you find out you've passed whatever the real limit is.
