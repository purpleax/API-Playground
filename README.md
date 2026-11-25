# API Playground

A native Mac app for managing, running, testing and demoing APIs. See [PLAN.md](PLAN.md) for the full plan.

## Status

Phase 1 is built. See "Not yet checked" for what has not been tried on screen.

Covered by engine tests:

- Postman import: Collection v2.0/v2.1, environments, globals, backup files holding several of each, and the zip from Postman's "Export Data"
- Importing a collection again updates it in place, and requests keep their history
- Collections stored as one file per request, folder and environment
- `{{variable}}` resolution with Postman's scope order
- Secret values kept in the Keychain, and "This Mac only" values kept outside the workspace
- Basic, Bearer and API-key auth, inherited from folders and collections
- Sending requests with libcurl, with per-phase timings and a wire log
- cURL command import
- Per-request response history and a line-by-line response diff

Checked by hand in the running app:

- Importing files and a zip, the import report, browsing, editing and sending
- Response body, headers, timing, log, history and diff
- The environment editor, including a "This Mac only" value

Not yet checked:

- The zip import against a real Postman "Export Data" file (tested with a hand-made zip)
- cURL import from the clipboard, the file-picker import, and switching to a Local Vault
- Form, multipart, GraphQL and file body editors
- Secret variables with the real Keychain (tests use an in-memory store)

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
