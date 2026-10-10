# 第 3 章：Rust、移动宿主与 HTTP 基础

## Rust 工作区的依赖方向

本仓库的方向大致为 `Server protocol Git 依赖 <- crypto <- client-core <- mobile-ffi`。Rust crate 不
应反向依赖 Android 或 iOS 宿主；服务端也不是本工作区成员。循环依赖通常意味着职责放错。

Rust 中 `Result<T, E>` 表示可恢复失败；`?` 传播错误并保留上下文。处理外部输入时不要 `unwrap`。
`serde(deny_unknown_fields)` 是当前线上协议 contract 的重要组成，不能为了“客户端方便”删除。

## 阻塞工作与宿主调度

Rust 客户端核心执行 SQLite 与本地文件操作，Android/iOS 宿主负责网络和后台调度。大文件不得在 UI
线程无界读入内存；系统随时可能暂停后台任务，因此每一步都要以持久队列为恢复边界。

## Android 宿主职责

Kotlin 拥有权限、MediaStore 游标、Compose UI、WorkManager、网络环境和 EncryptedSharedPreferences/
Keystore。JNI 方法只接收严格 JSON 和路径，不应在 Rust 中偷偷请求 Android 权限或持有 Activity。

系统可能延迟、合并或取消后台任务，因此算法必须依赖持久队列和幂等服务端，而不是假设 Worker 永远
连续运行。

## iOS 宿主职责

Swift 拥有 PhotoKit 授权、SwiftUI 状态、Keychain、BGTask/URLSession delegate 与系统照片库
写入。FFI 句柄的生命周期由 `RustClient` 封装，C 字符串必须由匹配的当前 ABI 的对应释放函数释放。

Swift continuation 只能 resume 一次；后台 delegate、取消和进程恢复必须汇入同一状态机，不能在多个
回调重复提交。

## HTTP 约定

JSON 请求设置正确 Content-Type，并受请求体上限。错误使用稳定 HTTP 状态码及统一错误字段
`code/message/retryable`；当前服务端不生成请求 ID，客户端也不能依赖该可选字段。展示 message
不用于程序分支。下载与分块上传是二进制流，不能先无界读入内存再检查大小。

`GET`/`HEAD` 不改变业务状态；使用 `EmptyRequest` 的 action POST/DELETE 要求精确 `{}`，以拒绝未审计
字段。登录、创建上传、PATCH 等路由则各自使用明确 DTO，不能把 `{}` 规则泛化到全部写请求。

## SQLite 基础

SQLite transaction 只能原子管理数据库，不能原子覆盖文件系统和移动系统照片库。项目通过 staged
file、哈希、rename、持久 upload record 和恢复扫描组合出可证明状态。WAL 使读写并发更好，也意味着
运维必须按完整代次处理伴随文件。

## 安全编码原则

- 外部长度先验证再分配。
- 路径按组件和已打开目录描述符约束，不用字符串前缀判断。
- 秘密使用专用类型/日志脱敏，不进入错误详情。
- 秘密 Token 的摘要与比较必须沿用既有认证边界；内容 BLAKE3 不是授权凭据。
- 启动的任务必须写明生命周期。当前周期协调任务由进程拥有，没有独立取消句柄或关闭等待；
  不得在文档中把尚未实现的优雅关闭当成保障。
