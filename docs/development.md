# 构建与测试

在仓库根目录执行下列命令。Rust 固定 `1.99.0`；Android/iOS 工具按对应章节准备。三个 Rust crate 分别负责内容校验、移动业务核心与 FFI。

## Rust 和公共检查

```sh
./scripts/check-mobile-contract.sh
./scripts/check-workflow-supply-chain.sh
cargo fmt --all -- --check
cargo check --workspace --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
./scripts/test-mobile-ffi-c.sh
```

合同检查覆盖 Rust/Kotlin/Swift、生成的 C 头、状态身份与 DTO。C 测试实际加载宿主动态库；原生设备测试按后续章节执行。

## Android

准备 JDK 17、Gradle `9.5.0`、Android SDK 36、Build Tools `36.0.0`、NDK `28.2.13676358` 和 platform-tools。设置 `ANDROID_HOME` 后，在 Linux/macOS shell 构建 arm64 Debug 应用：

```sh
rustup target add aarch64-linux-android
cargo install cargo-ndk --version 4.1.2 --locked
export ANDROID_NDK_ROOT="$ANDROID_HOME/ndk/28.2.13676358"
export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"
cargo ndk -t arm64-v8a -o clients/android/app/src/main/jniLibs   build -p xszc-mobile --release --locked
gradle -p clients/android testDebugUnitTest assembleDebug
adb install -r clients/android/app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n org.sarmg.xszc/.MainActivity
```

Rust 输出 `libxszc_mobile.so`，Gradle 输出 `app-debug.apk`。连接设备并授权 USB 调试后安装；已存在不同签名的正式应用时，使用独立测试设备或模拟器，保留正式应用中的待传数据。

Windows PowerShell 可安装脚本所需的三个 Rust 目标后使用仓库助手：

```powershell
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
cargo install cargo-ndk --version 4.1.2 --locked
./scripts/build-android-rust.ps1
gradle -p clients/android testDebugUnitTest assembleDebug
```

真实 JVM/JNI 检查运行 `./scripts/test-mobile-ffi-jni.sh`。准备 Android 模拟器后执行 `./scripts/test-android-emulator.sh`，覆盖权限、图库、上传和重开等原生路径。正式 APK 仅打包 arm64，签名配置见[Android 正式签名](android-signing.md)。

## iOS

在 Mac 上准备 Xcode 26、iOS 26 SDK、iOS 26 模拟器运行时和 XcodeGen `2.46.0`：

```sh
./scripts/verify-ios-toolchain.sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
./scripts/build-ios-rust.sh
(cd clients/ios && xcodegen generate)
xcrun simctl list devices available
```

脚本生成实机和模拟器 Rust 库及 `XszcRust.xcframework`。从列表选择已安装 iOS 26 的模拟器 UUID，将占位值替换后运行：

```sh
simulator_udid="REPLACE_WITH_AVAILABLE_IOS26_SIMULATOR_UUID"
xcodebuild -project clients/ios/Xszc.xcodeproj -scheme Xszc   -sdk iphonesimulator -destination "platform=iOS Simulator,id=$simulator_udid" test
```

模拟器使用工程配置的本地临时签名，无需 Apple Developer 证书。保留签名以验证配对与 Keychain；禁用签名可能造成凭据保存失败。

专项检查：

```sh
./scripts/test-ios-system-directory.sh
python3 scripts/test-package-ios-ipa.py
```

真机安装时在 Xcode 选择自己的 Team 和设备，见[安装指南](platform-setup.md#从源码安装到设备)。工程配置来自 `clients/ios/project.yml`。

## 发布验证

在干净且已取得对应标签的发行 checkout 执行 `./scripts/verify-release-version.sh v1.1.0`。正式工作流生成签名 Android APK、未签名 iOS IPA 和 `SHA256SUMS`。核对同一提交的主 CI、发布工作流及下载资产，再记录设备验收结果。

图库、视频、取消和权限变化的详细设备场景见[实现与验收](manual-backup-implementation.md#设备验收)。模拟器结果与真机后台调度、触控和解码兼容性分别记录。
