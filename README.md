# Remote Pi — 手机客户端

[Remote Pi](https://github.com/fenlyin0420/pi-remote) 的 Flutter/Android 客户端：
把跑在电脑上的 [Pi coding agent](https://github.com/earendil-works/pi) 搬到手机上 ——
配对后看工具调用实时流、按房间分流会话、收发附件、在 App 内更新。

> 2026-10-14 从 monorepo fork `fenlyin0420/remote_pi` 的 `app/` 子目录切出来的**独立仓库**
> （`git subtree split`，历史保留），仓库根目录就是 Flutter 工程根。
> 插件本体在 [`fenlyin0420/pi-remote`](https://github.com/fenlyin0420/pi-remote)，
> 旧的 monorepo 归档在 [`fenlyin0420/remote_pi`](https://github.com/fenlyin0420/remote_pi)。

## 构建与测试

```bash
flutter pub get
flutter test --concurrency=1     # 并行跑会踩到 settle 竞态（见 test/ 里的说明）
flutter analyze
```

连本机 relay 跑真机：relay 默认 `http://relay-host-redacted:3000`（明文 HTTP，Android 侧需要
`REMOTE_PI_HOSTS` 里的 host 例外，发版 workflow 已经带上）。

## 发版

`.github/workflows/app-release.yml`，**tag 就是版本号**，且必须与 `pubspec.yaml` 的 base 一致
（versionCode 来自 `+N`，tag 前先 bump 并提交）：

```bash
git tag v1.5.33-beta.1     # 或 v1.5.33
git push origin main v1.5.33-beta.1
```

- `x.y.z-beta.N` → flavor **beta** + prerelease；纯 `x.y.z` → flavor **prod** + 正常 release
- 产物：`remote-pi-<版本>-arm64-signed.apk` + `SHA256SUMS` + `latest.json`
- job 会把 APK 证书指纹与 keystore 指纹对比，防「Gradle 静默回落到 debug key」

### 必需的仓库 secrets（本仓要单独填，secrets 不随代码迁移）

| secret | 干什么 | 值从哪来 |
|---|---|---|
| `ANDROID_KEYSTORE` | release 签名用的 keystore（**base64**） | `app/android/signing/remotepi-release.jks`（本机副本：`~/.pi/remote/android-signing/`） |
| `ANDROID_KEYSTORE_PASSWORD` | 打开 keystore 的口令 | `app/android/key.properties` 的 `storePassword` |
| `ANDROID_KEY_PASSWORD` | key 本身的口令 | 同上的 `keyPassword` |
| `ANDROID_KEY_ALIAS` | key 别名 | 同上的 `keyAlias` |

改这四样等于换签名身份：**丢了 keystore 就再也不能原地升级安装**（Android 只认同一个签名）。
它们都在 `.gitignore` 里，别提交；备份放 `~/.pi/remote/android-signing/`。

## 更新链路（注意 feed 换了仓）

App 的更新源是 `lib/data/update/update_checker_impl.dart` 里的
`defaultReleaseFeedUrl`：

```
https://github.com/fenlyin0420/pi-remote-app/releases.atom
```

`latest.json` 与 APK 发布在同一个 release 里，下载走 GitHub CDN。
**旧 monorepo 仓（`remote_pi`）的 feed 已停更**：装着的旧版本不会再收到更新，
手动 sideload 一次本仓的 APK 即可（relay 地址和配对状态都不变，不需要重新配对）。

## 协议是跨仓契约

`PROTOCOL.md` 在本仓是**镜像**，权威在插件仓；`lib/protocol/protocol.dart` 手工镜像它的
`src/protocol/types.ts`。改 wire 时两个仓一起改，并跑：

```bash
node scripts/check-protocol-drift.mjs \
  --ts  <插件仓>/src/protocol/types.ts \
  --dart lib/protocol/protocol.dart
```

CI 里也会跑（自动从插件仓拉对端文件）。确属有意差异的写进
`scripts/protocol-drift-allow.txt`。
