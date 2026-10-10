# 移动协议与状态身份

本页面向修改 Rust 核心或平台宿主的开发者。线上 DTO 从 Cargo 固定的 xszs protocol Git revision 获取；账户管理、管理 Web 与服务端存储实现见 [xszs 文档](https://github.com/isarmg/xszs/tree/main/docs)。

## 身份

| 身份 | 当前值 |
|---|---|
| 软件发行版 | `1.1.0`，根 `VERSION` |
| 移动应用/数据库合同版本 | `1.0.0` |
| 移动 revision / 数据库 revision | `1` / `1` |
| 移动 epoch | `xszc-mobile-v1` |
| C/JNI ABI | `1` |
| 移动 HTTP 路径前缀 | `/v1` |
| 存储编码 | `plain-v1` |

软件发布号与持久状态身份分别校验，1.1.0 保留同合同的队列、回执、绑定和自动排除。当前数据库身份或结构不匹配时保留原数据并拒绝打开。

TLS 保护传输；服务端保存原始媒体字节，服务器和数据卷管理员可以读取媒体。内容哈希用于完整性验证与完全重复识别，访问控制由设备凭据和账户身份完成。

## 登录与请求

`/v1/auth/bootstrap` 使用实例 `authorization_code`、`device_name` 和 `platform` 换取设备 Bearer Token。管理员轮换授权码后旧设备 Token 失效。设备使用实例凭据；管理 Cookie、API Key 和监控凭据有各自用途。

鉴权资源请求保持同源 HTTPS，禁止携带 Token 跟随重定向；视频请求同样遵循该规则。错误依据稳定 `code`、HTTP 状态和 `retryable` 分支，`request_id` 是可选诊断字段，429 依据 `Retry-After` 等待。

## 上传与回执

客户端持久化资源身份、大小、BLAKE3 和分块计划，创建 upload 后只发送缺失分块，再提交完成请求。完成回执保存资产/资源身份与内容摘要。重复入队和重试复用同来源、版本及大小的现有任务；内容改变时建立独立任务。

单原件当前最多 2 GiB。移动 `part_size` 范围为 1 字节至 64 MiB，单文件最多 4096 块。多资源照片只有全部原始资源回执齐全才显示完整备份；缩略图失败单独处理。

## 图库与同步

时间线使用不透明游标，每页 100 项，切换筛选后重建分页。完整快照先捕获 `/v1/sync/head` 水位，再分页读取 `/v1/library/snapshot`，最后消费之后的变化。资产变化与 sequence 在同一 SQLite 事务提交，失败保留原游标。

本地授权撤销和照片删除不传播为云端删除。移动端永久删除只作用于回收站资产，并要求二次确认。接口消费范围见[接口参考](../interface-consumers.md)。

## FFI 与验证

宿主在调用前核对 ABI，使用生成的 C 头或 JNI 桥，按公共 ABI 释放结果。指针、长度、句柄代次与 panic 边界见[移动宿主参考](../beginner-guide/06-android-and-ios-clients.md#ffi-规则)。修改 DTO、状态或 FFI 时同时运行[合同及原生测试](../development.md)。
