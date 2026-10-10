# 第 1 章：项目全景与版本边界

## 学习目标

读完本章后，你应能说明 xszc 解决的问题、本仓库三个 Rust crate 与两个移动客户端的职责、媒体字节
经过哪些边界，以及为什么当前版本拒绝任何旧名称和旧状态。

## 产品目标

xszc 面向“把 Android/iOS 系统照片库中的原始照片和视频可靠保存到自己的服务器，并能在新
设备恢复”这一单一目标。核心成功标准不是页面数量，而是：扫描不越权、任务可续传、提交幂等、对象
可校验、恢复拿到原始字节、故障可诊断。

它不是完整媒体云。当前没有人脸、语义搜索、地图、分享、协作、服务端转码或机器学习集群。功能边界
详见[功能与取舍](../feature-inventory-and-tradeoffs.md)。

## 系统组成

```text
Android App                  iOS App
MediaStore                   PhotoKit
WorkManager                  Background URLSession
Keystore                     Keychain
      \                      /
       mobile-ffi + client-core
                 |
              HTTPS /v1
                 |
       xszs
       ├─ admin Web
       ├─ SQLite metadata
       └─ DATA_DIR blobs
```

服务端仓库中的 `protocol` crate 定义线上协议 DTO，本仓库以完整 Git revision 引用它；`crypto` 定义内容
哈希等基础能力；`client-core` 定义移动任务库；`mobile-ffi` 只做语言边界。账户、上传、图库、文件和
运维命令属于独立的服务端仓库。

## 两类持久状态

- 服务端 SQLite：账户、设备、上传、资源、资产、相册、标签、同步序列、会话、API Key 和审计。
- 服务端 `DATA_DIR`：原始媒体、缩略图与暂存分块。
- 移动 SQLite：待处理任务、已上传分块、失败与游标。
- 移动安全存储：服务地址与设备 Bearer Token。

服务端数据库与 `DATA_DIR` 是一个组合一致性单元。只备份其中一项无法证明可恢复。

## 当前版本身份

客户端发行版本由根目录 `VERSION` 指定，当前为 `1.1.0`。持久状态与线上协议合同有独立兼容身份：产品
`xszc`、应用版本 `1.0.0`、revision 1、移动 HTTP `/v1`、存储 `plain-v1`、epoch
`xszc-mobile-v1`、本地 SQLite 结构修订 1 和 xcsc ABI 修订 1。发行号变化
不会静默改写这些持久化身份；合同字段或本地结构定义不匹配时失败关闭。

项目不注册旧项目名、不识别旧应用 ID、不扫描旧状态目录，也不为旧 JSON 字段添加别名。

## 推荐源码阅读入口

先读根 `Cargo.toml`、`xcsc-client.toml` 和各 crate 清单，再读 `crates/client-core/src/lib.rs`、
`crates/crypto/src/lib.rs` 与 `crates/mobile-ffi/src/lib.rs`。随后分别进入 Android `BackupWorker.kt` 与 iOS
`BackupCoordinator.swift`。需要查看 DTO 或服务端处理函数时，再进入固定依赖所指向的服务端仓库。

## 本章检查题

1. 为什么 TLS 不等于端到端加密？
2. 为什么 SQLite 与 DATA_DIR 必须一起备份？
3. 为什么移动端安全存储不由 Rust FFI 直接拥有？
4. 哪些身份字段共同阻止旧版本被当前产品误读？
