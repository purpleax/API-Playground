# API Playground

A native Mac app for managing, running, testing and demoing APIs. See [PLAN.md](PLAN.md) for the full plan.

## Status

Phase 1 is in progress.

Working and covered by tests:

- Postman Collection v2.0/v2.1 and Postman environment import
- Collections stored as one file per request, folder and environment
- `{{variable}}` resolution with Postman's scope order, and secret values kept in the Keychain
- Basic, Bearer and API-key auth, inherited from folders and collections
- Sending requests with libcurl, with per-phase timings and a wire log
- cURL command import
- Per-request response history and a line-by-line response diff

Checked by hand in the running app:

- The app window: collection sidebar, request editor, response viewer, environment editor

Not started in phase 1:

- Local, per-machine "current values" for variables
- Importing Postman's full data export (zip)

## Building

You need Xcode installed. The Command Line Tools alone cannot build the SwiftUI app.

Run the engine tests:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Build the app into `build/API Playground.app`:

```bash
Scripts/make-app.sh
```

Open it:

```bash
open "build/API Playground.app"
```

## Layout

| Path | Contents |
|---|---|
| `Sources/APIEngine` | Model, file storage, variables, importers, HTTP. No UI code. |
| `Sources/CCurlShim` | C wrappers for the libcurl functions Swift cannot call directly. |
| `Sources/APIPlayground` | The SwiftUI and AppKit app. |
| `Tests/APIEngineTests` | Engine tests. HTTP tests use a local server and need no internet. |
| `Scripts/make-app.sh` | Builds the app bundle. |
