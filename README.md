# Media Backup Client

本仓库为 Media Backup Client `0.4.0`，包含 Android/iOS、Rust 移动核心和 FFI。
Server 与管理 Web 位于 [media-backup-server](https://github.com/isarmg/media-backup-server)。
移动端通过经过证书验证的 HTTPS 上传媒体；Client 不包含 Server 可执行程序或管理 Web。

本项目只实现当前版本，移动端只接受
`media-backup-mobile-v0.4-r1` 合约；不属于当前身份的数据库、凭据和队列一律拒绝，产品仓库也不提供
迁移、备份和恢复命令。这些离线任务统一由独立的 `sarmg-upgrade` 项目负责。

发行号由根目录 `VERSION` 指定。`0.4.0` 实现持久化手动选择批次、幂等资源队列、完成回执、本地网格与分页云端图库，
并接入事务化增量缓存、服务端全库筛选、中等预览和视频流式播放。
Rust 与本地状态版本为 `0.4.0`，SQLite schema revision 为 `2`，Foundation ABI 保持 v2。
旧队列不自动迁移；长期设置保留，新设备令牌单独注册。详见[实施与验收记录](docs/manual-backup-implementation.md)。
服务器填写 HTTPS 根地址（例如 `https://backup.sarmg.org`），不添加 `/admin/`。
Android 连接检查访问 `/healthz` 并要求 `204`；它只检查服务存活，不代表账号已认证或备份已完成。

## 组成

```text
crates/crypto       分块准备、BLAKE3 计算和明文恢复校验能力
crates/client-core   移动端本地队列与当前 SQLite 契约
crates/mobile-ffi   Android JNI 与 iOS C ABI 边界
clients/android/            Kotlin、Jetpack Compose、WorkManager 客户端
clients/ios/                SwiftUI、PhotoKit、后台 URLSession 客户端
scripts/                    移动端构建、发行和契约门禁
```

## 快速验证

```bash
./scripts/check-mobile-v02-contract.sh
./scripts/check-workflow-supply-chain.sh
cargo fmt --all -- --check
cargo check --workspace --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
```

使用 Rust `1.98.0`。Foundation Client 与 Server 所属协议均固定完整 Git 提交和精确版本，
无需相邻仓库，也无需先构建管理 Web。移动 API 为 `/v2`，设备凭据与 Server 管理员凭据是独立授权域。
Android 普通 CI 构建 Debug APK，正式包必须使用受保护的签名环境；iOS 普通 CI 和正式 Release 均提供未签名 IPA：
`media-backup-ios-0.4.0-unsigned.ipa`，包含标准 `Payload/MediaBackup.app`。安装前需使用自己的
Apple 签名凭据或侧载工具重新签名；IPA 打包不会自动赋予设备安装授权。
Android CI 另使用 API 36 x86_64 模拟器执行真实 JNI 入队、分块、完成和重开测试，
并检查系统根目录别名、私有目录权限和恶意子链接。正式 APK 仍只包含 arm64-v8a。

## 文档

- [拆分边界及新状态 epoch](docs/repository-boundary.md)
- [文档总览](docs/README.md)
- [初学者学习指南](docs/beginner-guide/README.md)
- [项目工作流程与流程树](docs/project-workflow.md)
- [完整功能与取舍清单](docs/feature-inventory-and-tradeoffs.md)
- [部署、诊断、安全与发布运维](docs/operations.md)

## 许可证

第一方代码、文档和资源采用 [Apache License 2.0](LICENSE)。项目只参考其他照片管理产品的公开行为
和架构思想，不复制其代码、资源、数据库结构或生成物。
