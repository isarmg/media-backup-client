# xszc 文档总览

本文档集描述仓库当前 `1.1.0` 代码。代码、结构定义、发行 manifest 与自动化测试是最终事实源；文档与
实现不一致时，应先确认当前代码，再在同一变更中修正文档和测试。

| 分类 | 入口 | 适合读者 | 解决的问题 |
|---|---|---|---|
| 初学者学习指南 | [beginner-guide/README.md](beginner-guide/README.md) | 第一次接触 Rust 或移动备份的开发者 | 如何建立心智模型、运行项目并安全修改代码 |
| 工作流程与流程树 | [project-workflow.md](project-workflow.md) | 开发、评审和排障人员 | 请求、上传、同步、恢复、发行如何流转 |
| 完整功能与取舍 | [feature-inventory-and-tradeoffs.md](feature-inventory-and-tradeoffs.md) | 产品、架构和维护人员 | 已实现什么、明确不做什么、为什么 |
| 接口消费者边界 | [interface-consumers.md](interface-consumers.md) | 产品、客户端和 API 工具维护人员 | 哪些接口进入移动界面，哪些保留给账户自动化 |
| 必要 README | [../README.md](../README.md) | 所有人 | 项目定位、入口、最短验证路径 |
| 客户端分平台部署 | [platform-setup.md](platform-setup.md) | 设备用户和运维人员 | Android/iOS 安装、签名、配对/重配、后台任务查看/启停、诊断与卸载，含命令解释 |
| 客户端配置 | [configuration.md](configuration.md) | 设备用户和测试人员 | Android/iOS 安装、配对、备份偏好和首次验证 |
| 客户端运维 | [operations.md](operations.md) | 移动端测试、值班和发布人员 | Android/iOS 构建、权限、队列、配对、故障与发布边界 |

阅读建议：初学者按表格从上到下阅读；处理线上问题时直接从运维文档的“故障定位顺序”开始；修改
协议、结构定义或发行布局前，必须同时阅读工作流程与功能取舍清单。

- [手动备份与分页云端图库实施记录](manual-backup-implementation.md)
- [1.1.0 本地图库与全屏视频更新](releases/1.1.0.md)

- [依赖与 unsafe 审查](unsafe-audit.md)

公共支撑的职责、单体依赖、平台边界与验证方法见[公共支撑说明](common-support.md)。

## 当前源码与仓库布局

xszc `1.1.0` 使用 Rust `1.99.0` 与 SQLx `0.9`，移动 API、SQLite 当前结构及数据身份保持不变。正式状态以精确 Git 标签、Android/iOS 原生 CI 和实际 Release 资产为准；历史源码与验收记录不能替代当前产物验证。

根 `Cargo.toml` / `Cargo.lock` 约束整个 Rust 工作区的唯一依赖图。`crates/crypto` 负责分块内容处理，`crates/client-core` 负责当前本地数据库、图库和传输业务，`crates/mobile-ffi` 提供 C/JNI 入口；Android Kotlin/Compose 与 iOS SwiftUI 原生界面位于 `clients/android`、`clients/ios`。数据库权威定义在 `schema/`，构建与发行脚本在 `scripts/`。各业务模块的大测试文件放在模块旁，原生验收按平台目录组织。

第一方代码、文档和资源采用 [Apache License 2.0](../LICENSE)。

## 配置与开发检查

由服务端管理员创建备份实例，移动端只填写 HTTPS 根地址、实例授权码及自动备份/网络/电源/媒体范围/缓存策略。根地址不能附加 `/admin` 或 `/v1`；客户端没有写入账号、授权码或备份策略的受支持 CLI，必须使用应用界面与系统安全存储。

开发机可只读检查服务端存活，正常应为 HTTP `204`，但仍须在手机完成真实上传验收：

```sh
curl -fsS -o /dev/null -w '%{http_code}\n' https://backup.example.com/healthz
```

准备 Android 原生依赖并按[配置指南](configuration.md)构建 Rust 库后，在仓库根目录执行：

```sh
./scripts/check-mobile-contract.sh
./scripts/check-workflow-supply-chain.sh
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
gradle -p clients/android testDebugUnitTest assembleDebug
adb install -r clients/android/app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n org.sarmg.xszc/.MainActivity
```

Android 正式包仅 arm64-v8a；iOS 最低 26.0，发行 IPA 未签名，安装前须使用自己的 Apple 身份签名。平台配置、权限、安装与验收细节见[配置指南](configuration.md)。
