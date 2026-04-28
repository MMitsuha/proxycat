# ProxyCat

Native iOS client for [mihomo](https://github.com/MetaCubeX/mihomo). Architecture mirrors [sing-box-for-apple](https://github.com/SagerNet/sing-box-for-apple): a SwiftUI host app talks to a `NEPacketTunnelProvider` extension, which embeds the mihomo Go core via a `gomobile`-generated XCFramework.

## Layout

```
proxycat/
├── libmihomo/              Go gomobile wrapper — exports a tiny C-friendly
│                           surface (Start, Stop, SetTunFd, log delegate,
│                           traffic snapshot) over the mihomo module.
├── scripts/
│   └── build-libmihomo.sh  gomobile bind → Frameworks/Libmihomo.xcframework
├── Library/                Swift framework: VPN profile, command client,
│                           shared models, app-group filesystem helpers,
│                           memory-pressure monitor.
├── ApplicationLibrary/     SwiftUI views: Dashboard, Profiles, Logs, Settings.
├── Pcat/                   iOS app target (entry point, Info.plist, entitlements).
├── PcatExtension/          Network Extension target (PacketTunnelProvider).
├── project.yml             XcodeGen spec — regenerates ProxyCat.xcodeproj.
└── Makefile                build orchestration.
```

## Prereqs

```bash
brew install xcodegen
go install golang.org/x/mobile/cmd/gomobile@latest
go install golang.org/x/mobile/cmd/gobind@latest
gomobile init
```

`libmihomo/tools.go` pins `golang.org/x/mobile/bind` as a direct
go.mod dependency. Without it, `gomobile bind` fails with
`unable to import bind: no Go package in golang.org/x/mobile/bind`
because `go mod tidy` would otherwise prune it (no source file
imports `bind` directly — gobind imports it from a tmpdir).

The mihomo source must sit at `../mihomo` relative to `proxycat/`, which is the layout in this repo (`/Users/mitsuha/mihomo/mihomo`). The Go module replace directive in `libmihomo/go.mod` points there.

## First build

```bash
cd proxycat
make all          # build the xcframework, generate the xcodeproj
open ProxyCat.xcodeproj
```

In Xcode: set `DEVELOPMENT_TEAM` for both `Pcat` and `PcatExtension` targets, then run.

## Memory budget (NE jetsam)

iOS kills `NEPacketTunnelProvider` extensions that exceed an **undocumented** memory limit — historically ~15MB, sometimes raised to 50MB on newer iOS, but Apple explicitly tells developers not to hardcode the number ([forum thread][quinn]). ProxyCat reacts to *signals*, not absolute totals:

- `os_proc_available_memory()` polled at 2s
- `DispatchSource.makeMemoryPressureSource(...)` (warning + critical)
- On warning: log mirror file is truncated
- On critical: every active connection closed via `LibmihomoCloseAllConnections`

Mihomo's runtime log buffer is left small; real log retention happens in the host app.

[quinn]: https://developer.apple.com/forums/thread/106377

## Logs view (the user-requested ones)

`ApplicationLibrary/LogView.swift` provides:

1. **Level filter** — Picker menu with `Default` (= mihomo's running level) plus `Debug / Info / Warning / Error / Silent`. Filter is `entry.level >= cutoff` (mihomo's log levels go DEBUG=0 → SILENT=4, so picking `Warning` shows Warning + Error).
2. **Search box** — `.searchable` with a 250ms debounce; matches are highlighted inline in `LogRow`.
3. **Copy All** — copies `viewModel.visible.map(...)` (i.e. exactly the lines passing the active level + search filter) to `UIPasteboard.general`. A confirmation alert reports the line count.

Pause/Resume freezes the snapshot so you can scroll without auto-scroll fighting you. Clear nukes the in-memory ring and the shared mirror file.

## App ↔ Extension IPC

Rather than reimplement sing-box-for-apple's libbox command-server-over-Unix-socket, we use a simpler mihomo-native pattern:

- The extension owns the gomobile bridge.
- It mirrors logs to `<App Group>/Cache/ne.log` (one line per entry: `<level>\t<message>\n`) and a 1-second traffic snapshot to `<App Group>/Cache/traffic.json`.
- The host app's `CommandClient` tails both via `FileHandle`. No custom protocol, no XPC, fits comfortably in the NE's memory budget.

For richer interactions (proxy switching, connection list, rule queries) we'll add the same files-in-app-group pattern or layer mihomo's existing REST controller behind a localhost-bound listener exposed only to the host process.

## Generating a profile

ProxyCat consumes mihomo's stock YAML. The Profiles tab supports:

- Importing a `.yaml` / `.yml` file via the document picker
- Pasting YAML into an inline editor
- Deleting via swipe

Make sure your YAML has `tun.enable: true` and `tun.stack: gvisor`. The TUN file descriptor is supplied by the Network Extension at runtime — don't set `tun.file-descriptor` manually.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `No such module 'Libmihomo'` | Forgot `make libmihomo` |
| App connects, drops in 5s | Jetsam — check Console.app for `EXC_RESOURCE` from `PcatExtension` |
| `could not obtain TUN file descriptor` | KVC path changed across iOS — see `packetFlowFileDescriptor()` |
| Black screen after `Connect` | The YAML's `external-controller` is unreachable; not actually fatal but check logs |
