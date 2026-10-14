# Remote Pi — phone client

Flutter/Android client for **Remote Pi**: drive a [Pi coding agent](https://github.com/earendil-works/pi)
session running on your own machine from your phone.

- Pair once over a relay (QR code), then reconnect automatically.
- Chat with the agent and watch tool calls stream in as they happen.
- One room per workspace, switch between running agents, send attachments.
- Tool results that contain images show up as inline cards.
- Built-in update check against this repository's releases.

The desktop side is the Pi plugin [`fenlyin0420/pi-remote`](https://github.com/fenlyin0420/pi-remote).

## Install

1. Download the latest signed APK from [Releases](../../releases).
2. Install it (Android will ask you to allow installing from this source the first time).
3. On the desktop, install the plugin and start a session:

   ```bash
   pi install git:github.com/fenlyin0420/pi-remote
   ```

4. Run `/remote-pi pair` inside that Pi session and scan the QR code with the app.

## Configuration

The relay address is entered in the app (settings → relay); point it at the relay you run.
Cleartext HTTP relays are only reachable if the host is listed at build time (see below).

## Build from source

```bash
flutter pub get
flutter test --concurrency=1
flutter analyze
flutter build apk --release --flavor prod
```

The release build reads `REMOTE_PI_HOSTS` (comma/space separated) and compiles a network
security config from it — hosts listed there may be reached over plain HTTP; with the
variable unset the APK gets no cleartext exceptions.

## Releases

Version tags (`v<major>.<minor>.<patch>`, optionally `-beta.<n>`) trigger CI, which builds and
signs an arm64 APK, publishes it with `SHA256SUMS` and a `latest.json` manifest, and the app
picks it up from the release feed. The tag has to match the base version in `pubspec.yaml`.

## Protocol

The wire protocol is documented in [`PROTOCOL.md`](./PROTOCOL.md), which is a mirror of the
plugin repository's copy — that one is authoritative. `lib/protocol/protocol.dart` mirrors
`src/protocol/types.ts` by hand, and `scripts/check-protocol-drift.mjs` compares both sides
(field names, discriminant literals and the wire fixtures under `.orchestration/contracts/fixtures`).

## License

MIT
