# 第 8 章：测试、调试与变更方法

## 测试层级

- Rust 单元测试：纯 DTO、哈希、状态机、路径、限流。
- Rust 集成测试：真实 SQLite、WAL、文件系统、FFI 与并发。
- 契约静态门：Rust FFI 头文件、JNI、Swift 符号、版本/应用 ID。
- Android：Kotlin 单元测试、Compose/Gradle 编译、APK 打包。
- iOS：XcodeGen、状态代次隔离测试、模拟器编译。
- 发行：版本一致性、供应链策略、签名 Android APK、未签名 iOS IPA 与校验和。

## 本地质量门

```bash
./scripts/check-mobile-contract.sh
./scripts/check-workflow-supply-chain.sh
cargo fmt --all -- --check
cargo check --workspace --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
```

只跑目标测试适合迭代，不是最终验收。涉及登录 Argon2 的测试对 CPU 争用敏感；并发跑多个大工作区
可能制造 timeout 假失败，应在资源正常时单独复现。

FFI 需要额外执行真实 C 动态库与 host-JVM JNI 验收：

```bash
./scripts/test-mobile-ffi-c.sh
./scripts/test-mobile-ffi-jni.sh
```

Android 单元/模拟器与 iOS Simulator 验收分别由 Gradle 和 Xcode 工作流执行。本仓库没有管理 Web；
Node、React、Vite 与 `clients/web` 命令属于服务端仓库。

## 调试分层

先记录时间、设备任务 ID、upload ID 和 asset/resource ID，再定位层次：扫描权限 -> 本地队列 -> DNS/TLS
-> auth -> create -> part -> complete -> sync -> restore。当前服务端统一 HTTP 运行时生成或校验
`X-Request-ID`，在响应头、错误响应的 `request_id` 和 HTTP span 中关联该请求。可结合该 ID 查服务端
日志；手机客户端未展示它的路径仍按任务和资源身份排查，不能假定每条本地日志都有请求 ID。

## SQLite 调试

客户端没有 `doctor` 命令。用测试测试夹具或应用诊断读取状态，不在应用私有数据库运行手工 DDL。
分析拒绝路径时复制完整 SQLite 代次到隔离目录并保持原 mode/sidecar，确认错误是 identity、
结构定义、integrity、foreign key、锁还是目录边界；服务端 `doctor` 只在服务端仓库运行。

## 文件系统调试

核对 mount、free bytes、inode、owner/mode、real path、链接和 open file。遇到 unknown 暂存区不按名称
删除；先对应数据库 upload record 与哈希。

## 安全变更检查表

1. 外部输入是否有长度/数量/depth 上限？
2. 秘密是否可能进入日志、panic 或 metrics label？
3. 取消/timeout 后谁拥有工作？
4. 崩溃在每个持久化的 point 后如何恢复？
5. 第二实例或路径换绑能否绕过锁？
6. 是否无意加入旧名称/旧结构定义兼容？

## 提交与评审

一个大问题一个提交：协议、存储、平台 UI、发行/运维分别可回滚。提交前查看 `git diff --check`、旧名
称零残留、生成物未提交和文档链接。评审描述不只写“测试通过”，还列出失败语义和未覆盖平台。
