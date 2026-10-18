# pi-remote-app — development notes

Flutter/Android client for Remote Pi. The repository root **is** the Flutter project root.

## Build & test

```bash
flutter pub get
flutter test --concurrency=1     # parallel runs hit a settle race in some widget tests
flutter analyze
```

## CI (`.github/workflows/`)

- `ci.yml` — on push/PR: `flutter test --concurrency=1`, `flutter analyze`, plus the protocol
  drift check against the plugin repository.
- `app-release.yml` — on version tags: signed arm64 APK, `SHA256SUMS` and `latest.json` on a
  GitHub release. `x.y.z-beta.N` → beta flavor + prerelease, plain `x.y.z` → prod flavor +
  release. The tag must match the base version in `pubspec.yaml`; the version code comes from
  its `+N` suffix, so bump and commit that before tagging. The job also compares the APK's
  certificate fingerprint with the keystore's and fails on a silent debug-key fallback.

### Release notes

`RELEASE_NOTES.md` **is** the release body — `app-release.yml` hands it to
`gh release create --notes-file` verbatim. Rewrite it for every version and commit it together
with the version bump, before tagging: one `# Remote Pi <version>` heading, a `What's new`
section written for users (what changed and why it matters, no internal lineage), and the
`Assets` list. Nothing checks this — with the file missing or still describing the previous
version the job silently publishes a generic "Remote Pi <version>" body, so the release ships
with no notes.

### Repository configuration

Secrets (Actions → secrets): `ANDROID_KEYSTORE` (base64-encoded `.jks`),
`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_PASSWORD`, `ANDROID_KEY_ALIAS`.
Losing the keystore means no further in-place updates are possible, so keep a backup.

Variable (Actions → variables): `REMOTE_PI_HOSTS` — comma/space separated hosts that may be
reached over cleartext HTTP; `build.gradle.kts` compiles them into the network security config.
Keep deployment addresses out of the workflow and the source; with the variable unset the build
simply produces no cleartext exceptions.

## Updates

The app polls the `releases.atom` feed of this repository
(`lib/data/update/update_checker_impl.dart`) and reads the `latest.json` manifest published with
each release.

## Protocol

`PROTOCOL.md` is a mirror; the authoritative copy lives in the plugin repository
(`fenlyin0420/pi-remote`) next to `src/protocol/types.ts`. `lib/protocol/protocol.dart` is a
hand-written mirror of that file, and `test/protocol*` pins the same wire samples. When the
protocol changes, update both repositories and run:

```bash
node scripts/check-protocol-drift.mjs \
  --ts <plugin repo>/src/protocol/types.ts \
  --dart lib/protocol/protocol.dart \
  --fixtures .orchestration/contracts/fixtures
```

It compares TS field names, TS discriminant literals and the fixtures manifest
(`scripts/protocol-fixtures.sha256`) against the plugin repository; intentional divergences go
into `scripts/protocol-drift-allow.txt`.
