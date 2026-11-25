# API Playground

A native Mac app for managing, running, testing and demoing APIs. See [PLAN.md](PLAN.md) for the full plan.

## Status

Phases 1 to 3 are built. See "Not yet checked" for what has not been tried on screen.

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
- Checks on status, headers, JSON values, body text and response time, with no script
- Saving a response value into a variable for later requests
- Pre-request and test scripts, run in JavaScriptCore with a Postman-compatible `pm` object
- Collection, folder and request scripts running in Postman's order
- Masking of secrets in bodies, headers, URLs and the wire log
- Pinned responses, and demo sequences saved with the collection
- A mock server that answers from pinned responses, including a whole collection run against its own mock

Checked by hand in the running app:

- Importing files and a zip, the import report, browsing, editing and sending
- Response body, headers, timing, log, history and diff
- The environment editor, including a "This Mac only" value
- Imported Postman test scripts running unchanged, with results and console output
- Adding a check, and the collection runner with pass and fail per request
- Hide Secrets across the editor, response body, headers and log
- Pinning a response, and showing it in place of a live one
- The mock server answering a collection with no backend running, and its temporary
  environment being removed on quit and after a force-quit
- A demo sequence with notes, and presentation mode with Space, arrow keys and Esc

Not yet checked:

- The zip import against a real Postman "Export Data" file (tested with a hand-made zip)
- cURL import from the clipboard, the file-picker import, and switching to a Local Vault
- Form, multipart, GraphQL and file body editors
- Secret variables with the real Keychain (tests use an in-memory store)
- Editing scripts and "Save from response" rows on screen, and running a single folder
- In phase 3: the P key while presenting (its button was checked), removing a pinned
  response, reordering demo steps, and the mock's list of requests received

### Demo features

- **Hide Secrets** (Demo menu, or the eye in the toolbar) masks tokens, keys and passwords
  wherever they are displayed. Requests still send the real values. It is always on while presenting.
- **Pin** a response to keep it with the request. A pinned response can be shown in place of
  a live one, and is what the mock server serves.
- **Mock Server** answers on `127.0.0.1` only. When a collection's URLs start with a shared
  variable such as `{{baseUrl}}`, starting the mock points that variable at it through a
  temporary environment, which is removed when the mock stops.
- **Demo sequences** list requests in order with a note each. **Present** shows one step at a
  time in large type: Space sends, the arrow keys move, P shows the pinned response, Esc exits.

### Script support

Scripts get `pm.test`, `pm.expect` (the commonly used Chai assertions), `pm.response`,
`pm.request`, `pm.environment`, `pm.globals`, `pm.collectionVariables`, `pm.variables`,
`console`, `btoa`/`atob`, and the older `tests[...]`, `responseBody` and `postman.*` API.

Not supported yet, and reported as a script error when used: `pm.sendRequest`,
`setNextRequest`, `require(...)` and Postman's bundled libraries such as CryptoJS, moment
and lodash. A value a script sets is stored as a "This Mac only" value. Collection and
folder scripts run but cannot be edited in the app yet. A script stuck in an endless loop
is not interrupted.

## Building

You need Xcode installed. The Command Line Tools alone cannot build the SwiftUI app.

Run the engine tests:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Build the app into `build/API Playground.app` (quit the app first if it is running):

```bash
Scripts/make-app.sh
```

Build a separate test copy, `build/API Playground Test.app`, with its own settings and
data, for trying changes without touching the real app's data:

```bash
Scripts/make-app.sh debug test
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
