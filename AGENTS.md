# pi-remote-app（Remote Pi 的 Flutter 客户端）

2026-10-14 从 monorepo fork `fenlyin0420/remote_pi` 的 `app/` 子目录切出来的**独立仓库**
（`git subtree split`，完整提交历史保留），仓库根目录就是 Flutter 工程根。

## 构建与测试

```bash
flutter pub get
flutter test --concurrency=1
flutter analyze
```

## 发版

`.github/workflows/app-release.yml`：tag 就是版本号，且**必须**与 `pubspec.yaml` 的 base 一致
（versionCode 来自 `+N`，tag 前先 bump 并提交）：

```bash
git tag v1.5.33-beta.1        # 或 v1.5.33（prod）
git push origin main v1.5.33-beta.1
```

- `-beta.N` → flavor **beta** + prerelease；纯 `x.y.z` → flavor **prod** + 正常 release
- 产物：`remote-pi-<版本>-arm64-signed.apk` + `SHA256SUMS` + `latest.json`
- 需要仓库 secrets：`ANDROID_KEYSTORE`(base64) / `ANDROID_KEYSTORE_PASSWORD` /
  `ANDROID_KEY_PASSWORD` / `ANDROID_KEY_ALIAS`（**新仓要重新填一遍**，secrets 不随代码走）
- job 会对比 APK 证书指纹与 keystore 指纹，防「Gradle 静默回落到 debug key」

## 更新链路（注意 feed 换了仓）

app 轮询 `defaultReleaseFeedUrl`（`lib/data/update/update_checker_impl.dart`）：

```
https://github.com/fenlyin0420/pi-remote-app/releases.atom
```

`latest.json` 与 APK 同 release 发布，走 GitHub CDN 下载。**旧 monorepo 仓
（`fenlyin0420/remote_pi`）的 feed 已停用**：装在手机上的旧版本不会再收到更新，
手动 sideload 一次本仓的 APK 即可（relay 地址 `relay-host-redacted:3000` 不变）。

## 协议（跨仓契约）

`PROTOCOL.md` 是**镜像**，权威在插件仓 `fenlyin0420/pi-remote`。本仓
`lib/protocol/protocol.dart` 手工镜像该仓的 `src/protocol/types.ts`（`lib/protocol/*` 与
`test/protocol/*` 的注释里都标了对应关系）。改 wire 时：

1. 插件仓改 `src/protocol/types.ts` + `PROTOCOL.md`（一起提交）
2. 本仓改 `lib/protocol/protocol.dart` + `test/protocol/*`
3. 跑 `node scripts/check-protocol-drift.mjs --ts <插件仓的 types.ts> --dart lib/protocol/protocol.dart`
   （两边各自的 CI 也会跑同一个脚本，参数指向对端仓）

## 插件在哪

不在本仓：`pi install git:github.com/fenlyin0420/pi-remote`（该仓根目录就是包，dist 已入库）。
