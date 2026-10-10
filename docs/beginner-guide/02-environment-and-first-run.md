# 第 2 章：开发环境与第一次运行

## 基础工具

本仓库固定 Rust `1.99.0`（minimal + rustfmt/clippy）。Android 另需 JDK 17、Android SDK API 36、构建工具 36、NDK
`28.2.13676358` 与 `cargo-ndk`；iOS 需要 macOS、Xcode、XcodeGen 和 Apple 平台 Rust 目标。

先确认工作区：

```bash
rustc --version
cargo metadata --locked --no-deps --format-version 1
cargo check --workspace --locked
```

本仓库没有 Node 或管理 Web 构建。不要用 `cargo update` 或宽版本范围解决本机问题，它们会改变锁图或
绕过固定的服务端 protocol 与 xcsc revision。

## 服务端开发配置（独立仓库）

以下配置和命令须在 [xszs](https://github.com/isarmg/xszs) checkout 中执行；
本仓库没有 `config/`、服务端 binary 或管理 Web。服务端的 `config/xszs.env.example` 是字段说明，不应直接变成生产秘密文件。开发环境准备独立临时数据库和数据目录，
设置规范化管理员 `BOOTSTRAP_ADMIN_USERNAME` 和强随机 `BOOTSTRAP_ADMIN_PASSWORD`。默认样例为 `admin`；服务不会读取
`ADMIN_EMAIL`。username 候选经 ASCII trim/lowercase 后必须是 3–64 bytes、首尾字母数字且仅含
`[a-z0-9._-]`。只有
`DEVELOPMENT=true` 且 `BIND` 是回环时才可关闭 HTTPS 强制。

```bash
cargo run -p xszs -- init
cargo run -p xszs -- run
curl --fail http://127.0.0.1:8080/healthz
```

`init` 创建并验证当前私有状态；`run` 启动开发服务。若绑定源码身份的可执行文件报告拒绝未指定发行根的
`run`，说明你运行的是正式身份，应使用完整发行树及 `run --release-root RELEASE_ROOT`，不能绕过发行校验。

## 初始化后的第一条业务链

1. 浏览器打开 `/admin`。
2. 使用全新数据库初始化的管理员登录。
3. 创建备份账户及设备实例，并复制实例授权码。
4. 移动端配置 HTTPS 服务地址，使用实例授权码配对。
5. 授予系统照片权限、选择相册、启动一次扫描。
6. 在服务端确认资产、对象和审计，再在另一设备恢复测试媒体。

第 2 步的管理 username 只供 `/api/v1/auth/*`；第 3–5 步通过移动端 `/v1/auth/bootstrap` 换取设备 Token。
Android/iOS 仅填写设备实例授权码，管理员用户名和密码不能用于设备配对。

## Android 构建

```powershell
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
cargo install cargo-ndk --version 4.1.2 --locked
.\scripts\build-android-rust.ps1
gradle -p clients/android testDebugUnitTest assembleDebug
```

构建脚本必须生成 `libxszc_mobile.so`；Kotlin 命名空间与应用 ID 都是
`org.sarmg.xszc`。`jniLibs` 只允许放置从当前 Rust 工作区生成的正式 ABI 文件。
这个本地命令只验证 Debug 构建。正式 `assembleRelease` 必须显式提供当前 PKCS#12 路径和密码；开发者
机器没有正式秘密时应当失败，不能自动落回 Debug 密钥。证书别名、SHA-256 和 APK 应用 ID 由
发布工作流再次独立验证。

## iOS 构建

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
./scripts/build-ios-rust.sh
cd clients/ios
xcodegen generate
xcodebuild -project Xszc.xcodeproj -scheme Xszc \
  -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
```

`clients/ios/project.yml` 是 Xcode project 的事实源；生成的 `.xcodeproj` 和 Info.plist 不提交。权限文案、bundle
ID `org.sarmg.xszc`、entitlements 和测试 target 都由 project.yml 统一生成。

## 常见首次运行错误

| 现象 | 原因 | 处理 |
|---|---|---|
| 明文地址被移动端拒绝 | 当前客户端只接受 HTTPS | 使用本地受信证书或反向代理 |
| 服务端拒绝启动 | 空数据库文件、非当前身份或结构定义漂移 | 保留原库并检查当前状态身份；首次实例使用当前 init |
| Android 找不到 JNI | ABI 目录或 library 名不符 | 重跑 Rust Android 构建并核对当前文件名 |
| iOS 链接不到符号 | header/FFI epoch 与 Swift 名不一致 | 运行移动契约门禁，只保留当前符号 |
| 登录 429 | 来源/账户预算或 Argon2 并发耗尽 | 等待 Retry-After，检查压力而非关闭限流 |
