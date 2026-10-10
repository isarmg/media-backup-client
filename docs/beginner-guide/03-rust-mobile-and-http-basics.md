# Rust 与移动宿主

Rust 核心提供同步的本地文件和 SQLite 操作，Android/iOS 负责网络与系统调度。耗时准备和大文件处理放在平台后台工作中，界面通过任务状态更新。

## Android

Kotlin 管理 MediaStore、Compose、WorkManager 和 Keystore 加密存储。使用授权的 content URI 读取媒体，Rust 接收已准备的输入与私有路径。Worker 再次运行时从持久队列继续。

## iOS

Swift 管理 PhotoKit、SwiftUI、Keychain、BGTask 和 URLSession。`RustClient` 管理 FFI 句柄，结果使用匹配的 ABI 释放函数。后台回调、取消和关闭汇入同一任务生命周期。

## 错误与状态

Rust 使用 `Result` 返回可恢复错误；HTTP 根据状态码和稳定错误码处理，界面消息用于解释原因。输入先验证预算再分配，输出只记录需要的脱敏信息。SQLite 事务管理数据库变化，文件准备和系统照片写入由明确的持久阶段衔接。

进一步查阅[宿主和 FFI](06-android-and-ios-clients.md)、[协议与状态](../reference/protocol-and-state.md)。
