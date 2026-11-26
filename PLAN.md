# API Playground — plan

Status: draft, 25 November 2026. "API Playground" is a working name.

## What it is

A native Mac app for managing, running, testing and demoing APIs. It covers the same ground as Insomnia and Postman, but as a native app that stores everything in plain files on the user's Mac, with no account and no backend.

It is a standalone app. It has no server component and no running costs.

## Goals

The app is for four things, in this order of priority:

1. **Manage** — organise requests into collections and folders, with environments and variables.
2. **Run** — send requests and inspect responses in detail.
3. **Test** — assert on responses and run a set of requests as a suite.
4. **Demo** — present an API to an audience, safely and reliably.

Importing Postman collections and environments is the most important single capability. See [Postman import](#postman-import).

## Out of scope

- **Command-line runner and CI use.** The app is interactive only.
- **Cloud sync and accounts.** Git Sync covers sharing and collaboration.
- **Other platforms.** Mac only, and Apple silicon only: there is no Intel build.

## Positioning

Bruno and Yaak already offer file-based, Git-friendly, no-account API clients, but neither is a native Mac app. The pitch is a native Mac app with real debugging depth. Local-first files are the baseline, not the headline.

The app has its own name and visual design. It matches Insomnia's feature set, not its look.

## Design decisions

| Area | Decision | Reason |
|---|---|---|
| UI | SwiftUI for the shell, AppKit for code editors and large response bodies | SwiftUI text views are too slow for large bodies |
| HTTP engine | libcurl | Exposes per-phase timings, the raw wire log, HTTP version control, proxies and client certificates |
| Storage | One human-readable file per request, folder and environment | The three storage modes become one engine pointed at different folders, and files diff cleanly in Git |
| Secrets | macOS Keychain, referenced by name from files | Secrets never land in a file or a commit |
| Variables | Postman's `{{name}}` syntax and built-in dynamic variables, used natively | Imported requests run unchanged |
| Scripting | JavaScriptCore, with a Postman-compatible `pm` object | No bundled runtime, and imported scripts mostly run as they are |
| Linting | A linter built into the app for now, using Spectral's rule names and ruleset format; `vacuum` as a helper binary if full Spectral compatibility is needed | The built-in linter needs no download and gives line numbers directly. vacuum reads every Spectral ruleset without needing Node |
| gRPC | libcurl's HTTP/2, with protobuf messages converted using the server's own description | The spike showed no helper binary is needed for reflection or dynamic messages |
| Git | libgit2, built into the app (it replaced the `git` command in November 2026) | No dependency on a system Git install. HTTPS sign-ins come from the Keychain items Git itself uses; SSH goes through the Mac's own `ssh` |
| Mock servers | In-process HTTP server on localhost | No separate process to manage |
| Minimum system | macOS 14 on Apple silicon | The interface uses SwiftUI features that arrived in macOS 14 |
| Distribution | Notarised direct download, updates through Sparkle | The Mac App Store sandbox makes Git access, local servers and helper binaries awkward |

### Code structure

The project has two parts:

- **Engine** — the request model, file storage, variable resolution, importers, HTTP engine and script runtime. It has no UI dependencies, so it can be unit tested on its own.
- **App** — the SwiftUI and AppKit interface, which depends on the engine.

Both compile into a single `.app`. The split is invisible to users.

### Storage modes

All three modes use the same file format:

| Mode | Where files live |
|---|---|
| Scratch Pad | A temporary folder; works immediately, nothing to set up |
| Local Vault | A folder the user chooses |
| Git Sync | A Git repository, with branching, commits and a 3-way merge view |

The file format is versioned from the first release, with migrations. Once users commit these files to their own repositories, the format is a contract.

## Postman import

This is the acceptance test for phase 1: import a real Postman collection and environment, pick the environment, and every request sends correctly with no editing.

### What is imported

- **Collections** — Postman Collection v2.1 and v2.0 files, with folders, requests, descriptions and ordering.
- **Environments and globals** — Postman environment export files.
- **Auth** — per-request auth, and auth inherited from a folder or collection.
- **Bodies** — raw, form, URL-encoded, file and GraphQL.
- **Saved examples** — these become pinned responses, and later seed mock servers.
- **Full data export** — the zip Postman produces when exporting everything (after phase 1).

### Details that have to be right

- **Variable scopes.** Postman resolves `{{name}}` across globals, collection variables and environment, with the narrower scope winning. The app uses the same scopes in the same order.
- **Initial and current values.** The initial value is imported as the shared default. Current values stay local to the machine.
- **Secret variables.** Variables marked secret in Postman go into the Keychain on import.
- **Disabled items.** Variables, headers and query parameters switched off in Postman stay present but switched off.
- **Auth inheritance.** "Inherit auth from parent" keeps working, so folders and collections carry auth settings in the app's own model.
- **Re-import.** Importing a newer export of the same collection updates it rather than duplicating it.
- **Import report.** Every import ends with a list of what came across cleanly and what needs attention.

### Scripts

Postman pre-request and test scripts are preserved on import in phase 1 but do not run. They start running in phase 2, when the script runtime and the `pm` compatibility layer arrive. Scripts using less common `pm` features or Postman's bundled libraries may need manual changes, and the import report flags them.

## Phases

| Phase | Delivers | Done when |
|---|---|---|
| 1. Manage and run | Collections, request editor, response viewer, environments, Basic/Bearer/API-key auth, history, Postman collection and environment import, cURL import, timing waterfall, response diff, Scratch Pad and Local Vault | A real Postman collection and environment import and run with no editing |
| 2. Test | Assertions on status, headers and body; request chaining; pre-request and after-response scripts with the `pm` layer; an in-app runner that executes a folder and shows pass/fail | Imported Postman test scripts run and report results |
| 3. Demo | Presentation mode, secret redaction, demo sequences, pinned responses, mock servers | A demo runs end to end with no network |
| 4. More protocols | GraphQL with schema introspection, WebSockets, server-sent events, cookies, OAuth 2 | Each protocol can be sent, inspected and saved in a collection |
| 5. Git Sync | Clone, branch, commit, push/pull, 3-way merge view | Two people can edit the same collection and merge |
| 6. Spec and gRPC | OpenAPI editor with live route preview, linting, generating collections and mocks from a spec, gRPC with server reflection | A spec produces a working collection and mock |

The first public release (1.0) is phases 1 to 5, plus importers for Insomnia, Bruno and OpenAPI. Phase 6 follows. All of these are now built; the Insomnia and Bruno importers were written from those apps' documentation and source, and still need trying against real exports.

Because storage is plain files from phase 1, a collection folder can be put in Git by hand long before phase 5.

Every item under [Features](#features) is now built as well, the last of them in November 2026: response filtering, the rate-limit gauge and JWT decoding, the TLS inspector and client certificates, copying a request as code, the repeat runner, the command palette, the menu-bar item and the Shortcuts actions. The README lists what has and has not been checked. The one thing in this plan that is not built is mock generation from a plain-language description, which stays optional (see [Risks](#risks)).

## Features

### Requests and responses

- Request editor with params, headers, body, auth and description tabs.
- Response viewer with preview, headers, cookies and the raw wire log.
- **Timing waterfall** — DNS, connect, TLS, time to first byte and download for each request.
- **Response diff** — compare two runs of one request, or one request across two environments.
- **Response history** — every past response for a request is kept and can be pinned.
- **Response filtering** — JSONPath or jq expressions over the body, saved per request.
- **Streaming viewer** — server-sent events and chunked responses shown as they arrive.
- **Header awareness** — rate-limit headers shown as a remaining-quota gauge; JWTs decoded inline.
- **TLS inspector and mTLS** — view the certificate chain; attach client certificates per host.
- **Export** — copy any request as cURL or a code snippet.

### Authentication and environments

- Basic, Bearer, API key and OAuth 2, with auth inherited from folders and collections.
- Cookie jar per workspace.
- Environments with global, collection and environment scopes, and a quick switcher.

### Testing

- Assertions without code for common checks (status, header present, body value).
- Scripts for anything more involved, using the `pm` layer.
- **Request chaining** — pull a value from one response into the next request without scripting.
- **Folder runner** — run a folder in order and show pass/fail per request.
- **Repeat runner** — send one request N times and report latency percentiles and error rate.

### Demoing

- **Presentation mode** — larger type and a simplified layout, toggled with one shortcut.
- **Secret redaction** — tokens and keys masked on screen in headers, bodies and URLs.
- **Demo sequences** — an ordered list of requests stepped through with a key press, each with a short note.
- **Pinned responses** — a saved response shown instantly if the live API is slow or down.
- **Mock servers** — built from collections, saved examples, recorded responses or an OpenAPI spec, so a demo needs no backend.

### Spec-first design (phase 6)

- OpenAPI editor with a live preview of routes that can be sent immediately.
- Linting with Spectral-compatible rulesets, including custom ones.
- Generate collections, tests and mock servers from a finished spec.

### Mac integration

- Command palette.
- Menu-bar item to start and stop mock servers.
- Shortcuts actions.

## Risks

| Risk | Phase | Mitigation |
|---|---|---|
| Code editor performance on large bodies | 1 | Use an AppKit text view from the start; test with multi-megabyte responses early |
| Postman's format has many edge cases | 1 | Test against real exports; produce an import report rather than failing silently |
| `pm` compatibility is open-ended | 2 | Cover the commonly used parts first; flag unsupported calls in the import report |
| The 3-way merge view is the largest piece of UI work | 5 | File-per-request storage keeps most merges conflict-free |
| Swift has weak support for dynamic protobuf messages | 6 | Settled: the app reads descriptors and converts messages itself. Two-way streams that react to replies would need a different HTTP/2 client |
| Mock generation from plain-language descriptions needs a language model | 6 or later | Optional feature, using a user-supplied API key |

## Open questions

- **Open or closed source.** Affects pricing and how the app competes with Bruno. libcurl, vacuum and libgit2 all allow either.
- **Pricing.** Suggested: a one-time purchase with a year of updates and a free trial. Git Sync should not sit behind a subscription.
- **Final name.**
- **The app's own file format.** YAML or JSON, and the folder layout.
