# Share-to-Import YAML Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make ProxyCat appear as a destination in the iOS Share / "Open With…" sheet for `.yaml` / `.yml` files, and import the shared file as a new profile.

**Architecture:** Three Swift edits and one plist edit. `Pcat/Info.plist` advertises the app as a YAML handler via `CFBundleDocumentTypes` and promotes the existing `io.proxycat.profile.yaml` UTI from imported to exported. `ProfileStore` gains a single `importYAML(from url: URL)` helper that wraps security-scoped file access around the existing `importYAML(_:name:remoteURL:)`. `MainView` wires `.onOpenURL` to that helper, switches to the Profiles tab on success, and shows an alert on failure. The in-app `.fileImporter` callback in `ProfileListView` is refactored to call the same helper, removing duplicated file-reading code.

**Tech Stack:** Swift 5.10, SwiftUI, iOS 17+. Info.plist UTI / document-type declarations. No new build targets, no entitlement changes, no `project.yml` edits.

**Spec:** `docs/superpowers/specs/2026-04-30-share-import-yaml-design.md`

**Testing note (adaptation):** This codebase has zero XCTest infrastructure (only the Go upstream `mihomo/test/` exists). Strict TDD does not fit the editor — Xcode discovers Info.plist registrations only when the bundle is rebuilt and installed, and the share-sheet integration is by definition a system-level interaction. Verification therefore relies on:
1. **Compilation** after each code task (`make sim` succeeds = the Swift edits hold), and
2. **Manual simulator smoke test** in Task 5, exercising every code path defined in the spec.

The new `importYAML(from:)` helper is structured to make a unit test easy if added later — it is a pure transformation of `URL → Profile` over `FileManager` + the existing in-memory store.

---

## File Structure

| File | Status | Purpose |
|---|---|---|
| `Pcat/Info.plist` | MODIFY | Promote the YAML UTI from imported to exported, add `CFBundleDocumentTypes` so iOS advertises ProxyCat as a YAML handler. |
| `Library/Profile.swift` | MODIFY | Add `ProfileStore.importYAML(from url: URL)` helper. |
| `ApplicationLibrary/ProfileListView.swift` | MODIFY | Replace the inline file-read in the `.fileImporter` callback with a call to the new helper. |
| `ApplicationLibrary/MainView.swift` | MODIFY | Add `importError` state, `.onOpenURL`, and the "Import failed" alert. |
| `Localizable.xcstrings` | MODIFY | Add zh-Hans translation for the new "Import failed" alert title. |

No `project.yml` edits — every file above is already a project source. The static `Pcat/Info.plist` is referenced via `INFOPLIST_FILE` (`project.yml:119`) and will be rebuilt automatically.

---

## Task 1: Promote UTI to exported and add `CFBundleDocumentTypes`

**Files:**
- Modify: `Pcat/Info.plist`

- [ ] **Step 1: Replace the entire body of `Pcat/Info.plist` with the new content**

Current file (for reference) keeps the `UIApplicationSceneManifest` block and the `UTImportedTypeDeclarations` block. The change does two things: rename `UTImportedTypeDeclarations` to `UTExportedTypeDeclarations` (the dict body inside is unchanged), and add a new `CFBundleDocumentTypes` array.

New full file content:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!--
  Supplemental Info.plist. Display name, app category, version, and the
  standard iOS keys live in INFOPLIST_KEY_* build settings (see project.yml)
  and Xcode merges them in at build time. Only put entries here that have
  no INFOPLIST_KEY_ equivalent.
-->
<plist version="1.0">
<dict>
    <key>UIApplicationSceneManifest</key>
    <dict>
        <key>UIApplicationSupportsMultipleScenes</key>
        <false/>
    </dict>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Mihomo Profile</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>io.proxycat.profile.yaml</string>
                <string>public.yaml</string>
            </array>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>io.proxycat.profile.yaml</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.yaml</string>
            </array>
            <key>UTTypeDescription</key>
            <string>Mihomo Profile</string>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>yaml</string>
                    <string>yml</string>
                </array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
```

- [ ] **Step 2: Build for the simulator**

Run: `make sim`
Expected: `** BUILD SUCCEEDED **` near the end. No "Couldn't read Info.plist" errors. (Plist syntax errors will fail the `process *.plist` build phase loudly.)

- [ ] **Step 3: Commit**

```bash
git add Pcat/Info.plist
git commit -m "Advertise ProxyCat as a handler for shared YAML profiles

Add CFBundleDocumentTypes so iOS surfaces the app in the Share /
Open-With sheet for .yaml / .yml files, and promote the
io.proxycat.profile.yaml UTI from imported to exported since this
app is the canonical owner of the type."
```

---

## Task 2: Add `ProfileStore.importYAML(from url:)` helper

**Files:**
- Modify: `Library/Profile.swift`

- [ ] **Step 1: Insert the helper directly after the existing `importYAML(_:name:remoteURL:)` method**

Find this closing brace at the end of `importYAML(_:name:remoteURL:)` (currently at `Library/Profile.swift:142`):

```swift
        if activeProfileID == nil {
            try setActive(profile)
        }
        return profile
    }
```

Insert the new method immediately after that closing brace, before the existing `refreshRemote(_:)` method:

```swift
    /// Imports a YAML profile from a file URL, handling iOS security-scoped
    /// resource access. Used by both the in-app `.fileImporter` and the
    /// share-sheet `.onOpenURL` entry point.
    ///
    /// `startAccessingSecurityScopedResource()` returning `false` is not
    /// treated as fatal — iOS reports `false` for URLs already accessible
    /// to the app (e.g. files inside the app's own container). Letting
    /// `String(contentsOf:)` decide produces a more accurate error.
    @discardableResult
    public func importYAML(from url: URL) throws -> Profile {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        let content = try String(contentsOf: url, encoding: .utf8)
        let name = url.deletingPathExtension().lastPathComponent
        return try importYAML(content, name: name)
    }
```

- [ ] **Step 2: Build for the simulator**

Run: `make sim`
Expected: `** BUILD SUCCEEDED **`. The helper compiles against the existing `importYAML(_:name:remoteURL:)`.

- [ ] **Step 3: Commit**

```bash
git add Library/Profile.swift
git commit -m "Add ProfileStore.importYAML(from:) helper

Wraps security-scoped resource access and UTF-8 decoding around the
existing importYAML(_:name:remoteURL:). Both the in-app file picker
and the upcoming share-sheet entry point need this exact sequence;
factoring it out avoids duplicating the boilerplate at each call site."
```

---

## Task 3: Refactor `ProfileListView` to use the new helper

**Files:**
- Modify: `ApplicationLibrary/ProfileListView.swift`

- [ ] **Step 1: Replace the `.fileImporter` callback body**

Find this block in `ApplicationLibrary/ProfileListView.swift` (currently lines 87–100):

```swift
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                _ = url.startAccessingSecurityScopedResource()
                defer { url.stopAccessingSecurityScopedResource() }
                run {
                    let content = try String(contentsOf: url, encoding: .utf8)
                    try profileStore.importYAML(content, name: url.deletingPathExtension().lastPathComponent)
                }
            case let .failure(error):
                actionError = error.localizedDescription
            }
        }
```

Replace it with:

```swift
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                run { _ = try profileStore.importYAML(from: url) }
            case let .failure(error):
                actionError = error.localizedDescription
            }
        }
```

The `run { … }` helper (defined at `ProfileListView.swift:129`) already routes thrown errors into `actionError`, which surfaces them in the existing "Action failed" alert.

- [ ] **Step 2: Build for the simulator**

Run: `make sim`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add ApplicationLibrary/ProfileListView.swift
git commit -m "Use ProfileStore.importYAML(from:) in the in-app file picker

Removes the inline security-scoped read so the picker and the new
share-sheet path share one code path."
```

---

## Task 4: Wire `.onOpenURL` and add the import-failed alert in `MainView`

**Files:**
- Modify: `ApplicationLibrary/MainView.swift`
- Modify: `Localizable.xcstrings`

- [ ] **Step 1: Replace the entire `MainView.swift` body**

The current file (44 lines) is small enough to show in full. Replace `ApplicationLibrary/MainView.swift` with:

```swift
import Library
import SwiftUI

public struct MainView: View {
    @StateObject private var environment = ExtensionEnvironment()
    @State private var selection: Tab = .dashboard
    @State private var importError: String?

    public init() {}

    public var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                DashboardView()
            }
            .tabItem { Label("Dashboard", systemImage: "speedometer") }
            .tag(Tab.dashboard)

            NavigationStack {
                ProfileListView()
            }
            .tabItem { Label("Profiles", systemImage: "doc.text") }
            .tag(Tab.profiles)

            NavigationStack {
                LogView()
            }
            .tabItem { Label("Logs", systemImage: "text.alignleft") }
            .tag(Tab.logs)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(Tab.settings)
        }
        .environmentObject(environment)
        .environmentObject(environment.profile)
        .environmentObject(environment.commandClient)
        .environmentObject(ProfileStore.shared)
        .task { await environment.bootstrap() }
        .onOpenURL { url in handleIncomingFile(url) }
        .alert("Import failed", isPresented: .constant(importError != nil)) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    /// Imports a YAML file delivered by the system (Share sheet, Open With,
    /// AirDrop, etc.) and switches to the Profiles tab on success. Errors
    /// surface in the alert and leave the current tab untouched so the
    /// user is not yanked away from where they were.
    private func handleIncomingFile(_ url: URL) {
        do {
            _ = try ProfileStore.shared.importYAML(from: url)
            selection = .profiles
        } catch {
            importError = error.localizedDescription
        }
    }

    enum Tab: Hashable { case dashboard, profiles, logs, settings }
}
```

- [ ] **Step 2: Add the zh-Hans translation for "Import failed" in `Localizable.xcstrings`**

Find the existing entry for `"Import YAML"` (currently at line 771–781):

```json
    "Import YAML" : {
      "extractionState" : "stale",
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "导入 YAML"
          }
        }
      }
    },
    "Info" : {
```

Insert the new entry between the closing `},` of the `"Import YAML"` block and `"Info" :`. The result should read:

```json
    "Import YAML" : {
      "extractionState" : "stale",
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "导入 YAML"
          }
        }
      }
    },
    "Import failed" : {
      "localizations" : {
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "导入失败"
          }
        }
      }
    },
    "Info" : {
```

(`extractionState` is omitted on the new entry — Xcode will populate it on the next build once the literal is discovered in source. This matches how Xcode treats fresh, manually-added entries.)

- [ ] **Step 3: Build for the simulator**

Run: `make sim`
Expected: `** BUILD SUCCEEDED **`. After the build, Xcode will have synced `Localizable.xcstrings`; do not panic if the diff shows additional metadata fields appearing on the new entry — that is normal.

- [ ] **Step 4: Commit**

```bash
git add ApplicationLibrary/MainView.swift Localizable.xcstrings
git commit -m "Handle YAML files shared into the app via .onOpenURL

MainView now imports any YAML URL the system delivers (Share sheet,
Open With, AirDrop) through ProfileStore.importYAML(from:), switches
to the Profiles tab on success, and surfaces failures in a new
\"Import failed\" alert. Adds the zh-Hans translation for the alert
title."
```

---

## Task 5: Manual simulator smoke test

**Files:**
- None (verification only)

This task is a checklist of share scenarios run in the iOS Simulator. Treat each box as PASS/FAIL — if any fails, file the bug, fix, and retest. There is no automated coverage to fall back on.

Setup once before the steps:
- Boot a simulator: `xcrun simctl boot "iPhone 15"` (or whichever device is convenient).
- Build and install: `make sim`, then drag the resulting `.app` from `build/` onto the simulator window. (Or run via Xcode: open `ProxyCat.xcodeproj` → Run.)
- Open the simulator's Files app once so it has a "On My iPhone" location.
- Drag `sample-profile.yaml` from the Mac Finder onto the simulator window. iOS will prompt to save it into Files. Save it under "On My iPhone".

- [ ] **Step 1: Files share-sheet → ProxyCat appears**

  In the simulator's Files app, long-press the saved `sample-profile.yaml` → Share. Confirm "ProxyCat" (or the configured display name) is one of the destinations in the share sheet.
  Expected: ProxyCat icon visible. If absent: rebuild & reinstall (iOS caches `CFBundleDocumentTypes` per install).

- [ ] **Step 2: Files share-sheet → tap ProxyCat → import succeeds**

  Tap ProxyCat in the share sheet. Expected:
  - ProxyCat foregrounds.
  - The selected tab is **Profiles**.
  - A new row named `sample-profile` is visible at the bottom of the list.
  - No alert.

- [ ] **Step 3: In-app picker still works (regression)**

  Inside ProxyCat: Profiles tab → "+" → "Import YAML" → select the same `sample-profile.yaml`. Expected: a *second* row named `sample-profile` appears (the existing importer does not dedupe — this is intentional for v1). No alert.

- [ ] **Step 4: UTF-8 failure surfaces an alert**

  In the Mac Finder, copy any small binary file (e.g. a PNG) and rename it `binary.yaml`. Drag it into the simulator's Files. Long-press → Share → ProxyCat. Expected:
  - Tab does NOT change.
  - An "Import failed" alert appears with a message about UTF-8 / encoding.
  - Tap OK; no profile row was added.

- [ ] **Step 5: Cold-launch via share**

  Force-quit ProxyCat in the simulator (swipe up from the App Switcher). From Files, share `sample-profile.yaml` to ProxyCat again. Expected:
  - The app cold-launches.
  - The selected tab on first appearance is **Profiles**.
  - The new row is visible.

- [ ] **Step 6: Mail-attachment share path**

  In the simulator's Mail app (configure any account, or use a Drafts folder if no account), create a draft, attach `sample-profile.yaml` from Files, save the draft. Open the draft, long-press the attachment → Share → ProxyCat. Expected: same outcome as Step 2.

  If Mail is not configured in your simulator, mark this step N/A — the underlying code path (`onOpenURL` with a security-scoped URL) is identical to the Files path already exercised in Step 2.

- [ ] **Step 7: zh-Hans alert title renders**

  Settings (system) → General → Language & Region → set iPhone language to "简体中文". Re-run Step 4. Expected: the alert title reads "导入失败" (not "Import failed").

  Restore language to English when finished.

- [ ] **Step 8: Final commit (only if any fix-ups were needed)**

  If Steps 1–7 all passed without changes, no commit needed — the work is already on `main`. If a fix was required, commit it now with a descriptive message and rerun the failing step to confirm.

---

## Summary of Commits Expected

When this plan is executed cleanly, the branch should have four new commits, each on a single logical change:

1. `Advertise ProxyCat as a handler for shared YAML profiles` — Info.plist
2. `Add ProfileStore.importYAML(from:) helper` — Library/Profile.swift
3. `Use ProfileStore.importYAML(from:) in the in-app file picker` — ApplicationLibrary/ProfileListView.swift
4. `Handle YAML files shared into the app via .onOpenURL` — ApplicationLibrary/MainView.swift + Localizable.xcstrings

If Task 5 surfaces a bug, an extra fix commit is fine.
