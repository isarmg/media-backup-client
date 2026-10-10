# 构建与测试

在仓库根目录执行下列命令。Rust 固定 `1.99.0`；按目标选择 [Android](platforms/android.md#从源码构建)或 [iOS](platforms/ios.md#从源码构建)工具链。三个 Rust crate 分别负责内容校验、移动业务核心与 FFI。

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

Android 的工具链、构建、设备安装和原生测试见 [Android 指南](platforms/android.md#从源码构建)。


## iOS

iOS 的工具链、构建、设备安装和原生测试见 [iOS 指南](platforms/ios.md#从源码构建)。


## 发布验证

在干净且已取得对应标签的发行 checkout 执行 `./scripts/verify-release-version.sh v1.1.0`。正式工作流生成签名 Android APK、未签名 iOS IPA 和 `SHA256SUMS`。核对同一提交的主 CI、发布工作流及下载资产，再记录设备验收结果。

图库、视频、取消和权限变化的详细设备场景见[实现与验收](manual-backup-implementation.md#设备验收)。模拟器结果与真机后台调度、触控和解码兼容性分别记录。
