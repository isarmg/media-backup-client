# 第 10 章：源码路线、练习与术语表

## 四周阅读路线

### 第一周：契约与入口

读 workspace manifest、`sarmg-client.toml`、Client constants、SQLite Schema 与 protocol Git pin。画出
发行版本、持久状态身份、FFI ABI 和 HTTP API 四类版本边界，并解释它们为什么不能互换。

### 第二周：上传与存储

读 `crypto::prepare_file`、`client-core::next_prepared`、generation 回收和数据库测试。为准备、上传重试、
完成清理逐个标出 `sync_all`、SQLite 提交和 crash point。

### 第三周：移动端

读 mobile-ffi、Android Worker、iOS Coordinator 与两端安全存储。画出系统终止后恢复路径，运行
epoch gate，并证明旧命名空间不会被读取。

### 第四周：发布与运维

读 Android/iOS 构建脚本、release workflow、签名门禁与 IPA 打包器。验证 Debug 与 Release 的 ABI、
签名材料隔离、版本一致性和制品命名；Server 的 release tree/systemd 属于独立仓库。

## 推荐练习

1. 构造在 WAL 中提交 current Schema 的 fixture，证明验证不改原件。
2. 准备并删除宿主临时源，再把任务标为可重试失败，证明下次复用同一准备结果。
3. 在准备持久化前模拟失败，再成功重试，证明只回收同一 job 的旧 generation。
4. 让移动增量缓存事务在游标提交前终止，证明不会提前推进。
5. 用跨域、降级 HTTP 或 redirect 资源地址请求下载，证明 Android/iOS 拒绝携带 Bearer 跟随。

## 术语表

| 术语 | 含义 |
|---|---|
| Asset | 用户可见的一张照片或视频逻辑实体 |
| Resource | 原始媒体或缩略图等具体内容对象 |
| Blob | DATA_DIR 中按内容 identity 保存的字节 |
| BLAKE3 | 内容完整性/完全重复判断 Hash |
| Part | resumable upload 的编号分块 |
| Cursor | 服务端生成、客户端原样保存的不透明分页位置 |
| Sequence | 图库变更的单调序号 |
| FFI/JNI | Rust 与 Swift/Kotlin 的二进制调用边界 |
| Epoch | 一组不兼容状态/协议的当前代 |
| WAL | SQLite 预写日志 sidecar |
| CSRF | Cookie 浏览器写请求的跨站伪造防护 |
| Argon2 | 密码 Hash 算法 |
| Rooted FS | 所有路径操作锚定已验证根目录的文件系统策略 |
| Idempotent | 相同请求重试得到同一效果而非重复副作用 |
| Fail closed | 无法证明安全或身份时拒绝 |
| Source-bound | binary 身份绑定精确源码 revision |

## 继续查阅

- [工作流程与流程树](../project-workflow.md)
- [功能与取舍清单](../feature-inventory-and-tradeoffs.md)
- [运维文档](../operations.md)
- 当前行为最终回到源码、Schema、manifest 和测试核对。
