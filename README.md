# Media Backup Client

Media Backup Client `0.4.11` 是 Media Backup 的 Android 与 iOS 应用。它读取用户授权的照片和视频，在本地维护上传队列，通过 HTTPS 备份到独立的 [Media Backup Server](https://github.com/isarmg/media-backup-server)，并提供本地图库与云端图库。

仓库包含共享 Rust 核心、Android Kotlin/Compose 应用和 iOS SwiftUI 应用。Android 正式包为 arm64-v8a；iOS 最低部署目标为 27.0，仓库发布的 IPA 未签名，安装前需要使用自己的 Apple 身份签名。

## 配置概览

先由 Server 管理员创建备份实例并复制实例授权码。移动端只填写：

- Server 的 HTTPS 根地址，例如 `https://backup.example.com`，不要附加 `/admin` 或 `/v2`；
- 实例授权码；
- 自动备份、网络、电源、媒体类型/相册和本地缓存策略。

安装 Android Debug APK 并打开应用：

```sh
adb install -r clients/android/app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n org.sarmg.mediabackup/.MainActivity
```

Server 存活检查应返回 HTTP `204`：

```sh
curl -fsS -o /dev/null -w '%{http_code}\n' https://backup.example.com/healthz
```

移动端没有用于写入账号、授权码或备份策略的受支持 CLI；这些设置必须在应用界面完成并由系统安全存储保护。Android/iOS 的逐步配置、权限、构建与验收命令见[完整配置指南](docs/configuration.md)。

## 开发验证

```sh
./scripts/check-mobile-v02-contract.sh
./scripts/check-workflow-supply-chain.sh
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
gradle -p clients/android testDebugUnitTest assembleDebug
```

## 文档

- [文档总览](docs/README.md)
- [完整配置指南](docs/configuration.md)
- [Client 运维与发布](docs/operations.md)
- [初学者指南](docs/beginner-guide/README.md)
- [项目工作流程](docs/project-workflow.md)

第一方代码、文档和资源采用 [Apache License 2.0](LICENSE)。
