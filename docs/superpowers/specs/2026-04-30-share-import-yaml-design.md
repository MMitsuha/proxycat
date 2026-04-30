# Share-to-Import YAML Profiles

Allow users to import a `.yaml` / `.yml` profile into ProxyCat by sharing
it from another app (Files, Safari downloads, Mail attachments, AirDrop)
via the iOS Share sheet or "Open With…" menu.

## Background

ProxyCat already has the data path for ingesting YAML profiles:

- `Pcat/Info.plist` declares a private UTI `io.proxycat.profile.yaml` as
  an *imported* type, conforming to `public.yaml`, with extensions
  `.yaml` / `.yml` and description "Mihomo Profile".
- `Library/Profile.swift` exposes
  `ProfileStore.importYAML(_:name:remoteURL:)`, which writes the YAML to
  the App Group, appends a `Profile` to the index, persists, and
  auto-activates if there is no active profile.
- `ApplicationLibrary/ProfileListView.swift` uses SwiftUI's
  `.fileImporter` for the in-app picker; its callback handles
  security-scoped resource access and calls `importYAML`.

What is missing for the share/open-in flow:

- No `CFBundleDocumentTypes` entry, so iOS does not advertise ProxyCat
  as a destination for YAML files in other apps' Share sheets.
- No `onOpenURL` handler, so even if the system did deliver a URL the
  app would ignore it.

This spec adds those two pieces and consolidates the file-reading logic
that the existing in-app importer duplicates.

## Scope

**In scope (v1):** files only — `.yaml` / `.yml` shared from any app
that uses the standard iOS file Share / Open-With flow.

**Out of scope:**

- A separate Share Extension target (would unlock raw-text share but
  doubles the build/sign/entitlement surface; rare workflow).
- URL share (covered today by the in-app `ProfileDownloadView`).
- Pre-import preview / rename UI.
- Name-collision dedupe (current in-app importer does not dedupe
  either; revisit separately).
- YAML structural validation (consistent with current behavior — the
  tunnel surfaces parse errors at activation time).

## Changes

### 1. `Pcat/Info.plist`

Two edits:

- **Promote the UTI from imported to exported.** ProxyCat is the
  canonical owner of `io.proxycat.profile.yaml`, so it should appear
  under `UTExportedTypeDeclarations`, not `UTImportedTypeDeclarations`.
  The body of the dict stays identical.
- **Add `CFBundleDocumentTypes`** with one entry:
  ```
  CFBundleTypeName     = "Mihomo Profile"
  CFBundleTypeRole     = "Editor"
  LSHandlerRank        = "Alternate"
  LSItemContentTypes   = [ io.proxycat.profile.yaml, public.yaml ]
  ```
  Including `public.yaml` alongside our private UTI is what makes
  ProxyCat surface for any `.yaml` file, not only files tagged with the
  ProxyCat UTI. `LSHandlerRank = Alternate` keeps us from competing
  with general YAML editors as the system default while still
  advertising the capability.

### 2. `Library/Profile.swift`

Add a reusable helper on `ProfileStore`:

```swift
@discardableResult
public func importYAML(from url: URL) throws -> Profile {
    let didStart = url.startAccessingSecurityScopedResource()
    defer { if didStart { url.stopAccessingSecurityScopedResource() } }
    let content = try String(contentsOf: url, encoding: .utf8)
    let name = url.deletingPathExtension().lastPathComponent
    return try importYAML(content, name: name)
}
```

Notes:

- The helper does not fail-fast when `startAccessingSecurityScopedResource`
  returns `false`. iOS sometimes returns `false` for URLs that are
  already accessible (e.g. files inside the app's own container).
  Letting `String(contentsOf:)` decide gives a more accurate error.
- The throw surface is exactly `String(contentsOf:)`'s and the existing
  `importYAML(_:name:)`'s, both already user-presentable.

### 3. `ApplicationLibrary/MainView.swift`

Three additions:

- `@State private var importError: String?`
- `.onOpenURL { url in handleIncomingFile(url) }` on the `TabView` (or
  any `View` it contains; placement does not matter as long as the
  scene receives URLs).
- An `.alert("Import failed", isPresented: ...)` bound to
  `importError`.

The handler:

```swift
private func handleIncomingFile(_ url: URL) {
    do {
        _ = try ProfileStore.shared.importYAML(from: url)
        selection = .profiles
    } catch {
        importError = error.localizedDescription
    }
}
```

Tab switch happens only on success, so a failed import does not yank
the user away from where they were.

### 4. `ApplicationLibrary/ProfileListView.swift`

Refactor the existing `.fileImporter` callback to delegate to the new
helper:

```swift
case let .success(urls):
    guard let url = urls.first else { return }
    run { _ = try profileStore.importYAML(from: url) }
```

This removes the inline security-scoped / `String(contentsOf:)` block
in favor of the shared path.

## Data flow

```
User taps Share on a .yaml in Files / Mail / Safari / AirDrop
         │
         ▼
iOS Share sheet shows ProxyCat (CFBundleDocumentTypes advertises us)
         │
         ▼
User taps ProxyCat → iOS launches or foregrounds the app, delivers URL
         │
         ▼
MainView receives URL via .onOpenURL
         │
         ▼
ProfileStore.importYAML(from: url)
   start security-scoped access → read UTF-8 → importYAML(content, name:)
   → stop security-scoped access
         │
         ▼
ProfileStore.profiles updated, Profiles/index.json persisted
   (auto-activates if no active profile yet — existing behavior)
         │
         ▼
selection = .profiles
         │
         ▼
ProfileListView re-renders; new profile is visible at the bottom
```

Cold-launch case: iOS builds the SwiftUI scene first, then delivers the
URL. `ProfileStore.shared.init` calls `reload()` synchronously, so by
the time `.onOpenURL` fires the store is ready.

## Error handling

| Scenario                                                         | Surface |
|------------------------------------------------------------------|---------|
| `startAccessingSecurityScopedResource` returns `false`           | Ignored; only fail if the read itself fails. |
| File is not valid UTF-8                                          | `String(contentsOf:encoding:)` throws → alert. |
| Disk write fails inside `importYAML(_:name:)`                    | Existing throw → alert. |
| YAML is structurally invalid for mihomo                          | Not validated here. Tunnel surfaces parse errors when the profile is activated (existing behavior). |

All errors flow through the new `importError` alert on `MainView`. The
selected tab is unchanged on error so the user is not pulled away from
their current view.

## Test plan

Manual verification in the iOS simulator:

1. Build & install. Drag a sample `.yaml` (use `sample-profile.yaml`)
   into the simulator's Files app.
2. In Files: long-press the file → Share → confirm ProxyCat appears in
   the share sheet → tap it → confirm the app opens, the active tab is
   Profiles, and a new row matching the file name is visible.
3. Repeat from a Mail draft with the same `.yaml` attached.
4. AirDrop test: from a host Mac, AirDrop the same file to a
   simulator-equivalent target if available; otherwise skip and rely
   on the Files / Mail paths, which exercise the same code path.
5. UTF-8 failure: rename a binary (e.g. a small image) to `.yaml` and
   share it. Confirm the import-failed alert appears with a readable
   message and the selected tab is unchanged.
6. Cold-launch: force-quit ProxyCat. From Files, share a `.yaml` to
   ProxyCat and confirm it cold-launches into the Profiles tab with
   the new row visible.
7. Regression: open the in-app Profiles → "+" → "Import YAML" picker
   and confirm it still works after the refactor in
   `ProfileListView`.
