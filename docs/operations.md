# Media Backup Client 运维文档

本文只描述 `0.4.10` Client：Rust 移动核心与 FFI、Android 应用和 iOS 应用。Server、管理 Web、
systemd、Caddy 和 Server 数据目录不属于本仓库；服务端部署请使用
[media-backup-server](https://github.com/isarmg/media-backup-server) 的 Release 文档。

## 1. 当前边界与状态

- Android 与 iOS 只连接 HTTPS Server 根地址，移动 API 前缀为 `/v2`。
- 每个移动实例使用管理员分配的长期授权码配对。授权码改变时旧设备 Token 失效，Client 保留同实例队列
  身份并重新配对；服务端返回不同实例身份时失败关闭。
- Rust 本地合同为 `media-backup-mobile-v0.4-r1`，数据库只接受当前 schema revision 2，不执行旧队列迁移。
- 授权码、设备 Token 与账户标识是客户端秘密；Android 存入应用私有配置，iOS 存入 Keychain。日志、
  命令参数和诊断输出不得包含这些值。
- 本地 SQLite、prepared parts 和系统照片库共同构成待传状态。不要手改数据库，也不要递归删除
  `backup-staging-v0.3-r1/prepared/` 来处理单个失败任务。

## 2. 通用 Rust、合同与 FFI 验证

从干净 checkout 执行：

```bash
./scripts/verify-release-version.sh
./scripts/check-mobile-v02-contract.sh
./scripts/check-workflow-supply-chain.sh
cargo fmt --all -- --check
cargo check --workspace --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
./scripts/test-mobile-ffi-c.sh
```

Rust 使用仓库固定的 1.98.0 工具链。`check-mobile-v02-contract.sh` 核对 Rust/Kotlin/Swift、C header、
数据库 identity 与 API DTO，任何一端只改字段都不算完成。

## 3. Android 构建与验收

安装 Android SDK/NDK 与 JDK 后构建 Rust arm64 库及 Debug 应用：

```powershell
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
cargo install cargo-ndk
./scripts/build-android-rust.ps1
gradle -p clients/android testDebugUnitTest assembleDebug
```

Linux CI 还应执行 `./scripts/test-mobile-ffi-jni.sh`；具备模拟器时运行
`./scripts/test-android-emulator.sh`，覆盖 JNI 入队、分块、完成、重开、授权码轮换和私有目录边界。

Android 需要网络、通知、照片/视频读取以及数据同步前台服务权限。Android 13+ 分别请求图片和视频权限，
Android 14+ 支持系统“仅选中的照片和视频”；未获完整权限时只能处理实际授权的媒体。自动备份由
WorkManager 调度，系统省电、后台限制或撤销权限都可能推迟任务，不能仅凭 UI 已启用判断备份完成。

正式 APK 只包含 `arm64-v8a`，签名材料只进入受保护的 GitHub Environment。普通 CI 的 Debug APK
不得作为正式更新发布；签名证书、application ID 和唯一 signer 必须由 Release workflow 校验。

## 4. iOS 构建与验收

iOS 当前最低部署目标为 27.0，使用 Xcode 27 / iOS 27 SDK：

```bash
./scripts/verify-ios-toolchain.sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
./scripts/build-ios-rust.sh
cd clients/ios
xcodegen generate
xcodebuild -project MediaBackup.xcodeproj -scheme MediaBackup \
  -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO test
```

`./scripts/test-ios-system-directory.sh` 验证系统目录与 Rust 状态边界，
`python3 scripts/test-package-ios-ipa.py` 验证 IPA 打包器。发布产物
`media-backup-ios-0.4.10-unsigned.ipa` 未签名；安装前必须用自己的 Apple 身份签名，打包本身不会授予
设备安装权限。

iOS 依赖 PhotoKit 的完整或有限照片权限，并用 BGProcessingTask/后台 URLSession 尝试继续传输。
系统决定后台执行时机；用户关闭后台刷新、低电量或权限变化时，应在前台重新打开应用检查队列。
授权码和 Bearer Token 保存在 Keychain，本地传输状态位于应用私有目录。

## 5. 本地数据分类与清理边界

| 数据 | 所有者与允许操作 | 删除影响 |
| --- | --- | --- |
| 系统照片库原始照片/视频 | 由系统照片库和用户管理；Client 只读选择结果 | Client 清理、卸载和重配均不得删除原件 |
| 宿主导出的临时源文件 | 平台层为一次准备过程导出；仅在确认没有 job 引用后清理 | 仍被引用时删除会使重试无法重新准备 |
| `prepared/` 上传分块 | Rust 队列按 job/part 管理；由成功确认或明确取消流程回收 | 手工删除会破坏待传任务及恢复证据 |
| 队列 SQLite | Rust 核心唯一拥有任务、分片、回执和绑定状态 | 删除会丢失进度、去重与完成记录，不能称为“清缓存” |
| 设备凭据 | Android 私有配置或 iOS Keychain | 删除后必须用当前实例授权码重新配对 |
| 图库预览缓存 | 可由应用重建，与上传回执独立 | 可清理，但不能据此改变队列状态 |

任何清理前先记录 job ID、队列状态和对应路径，仅使用产品提供的单任务取消/回收入口。没有可证明的引用
关系时保留数据；“清缓存重试”不是身份、队列或 prepared parts 的恢复方法。

## 6. 配对、队列与故障定位

1. 确认 Server 根地址是无路径后缀的可信 HTTPS origin，并检查设备时间与证书链。
2. 在 Server 管理台确认实例仍存在且授权码未被轮换；轮换后在 Client 输入新码重新配对。
3. 检查 Android/iOS 的实际照片权限、可用空间、网络与后台执行限制。
4. 查看队列状态，区分 `discovered`、`ready`、`uploading`、`retry_wait`、`failed` 和 `complete`。
5. 暂时性网络错误按有界退避重试；永久协议、身份或本地文件错误需要保留 job ID 与日志后定位，不能
   通过清空全部应用状态规避。
6. Server 返回的不同 account/device identity 会失败关闭；先核对实例与授权码，不要修改本地 SQLite。

当前已知边界：`retry_wait` 到期可能重新准备源文件。若宿主在准备后删除了导出临时源，后续重试会报告
源不存在；先保留 job ID、数据库行和对应 prepared 目录证据，再按单任务处理。

## 7. 发布检查

标签必须精确为 `v0.4.10` 并指向待发布提交。Release workflow 分别构建 Android 正式 APK、iOS 未签名
IPA、校验和与身份清单。发布前要求普通 CI、Android 模拟器/JNI 门禁、iOS 测试和供应链策略全部通过。
Client Release 不包含 Server 二进制、Web 资产、服务端配置或部署脚本。

安全事件中不要公开授权码、设备 Token、相册内容、数据库或私人路径。先停止自动任务、保全只读证据，
再由 Server 管理员轮换该实例授权码并在客户端重新配对。
