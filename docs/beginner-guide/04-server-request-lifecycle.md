# 第 4 章：服务端请求生命周期

## 从套接字到处理函数

请求首先以连接扩展中的真实套接字对端为信任起点。可信代理模块只有在直接 peer 属于配置 CIDR 时
才解释转发链，并从右向左去除可信 hop；否则忽略所有 forwarded header。随后执行 HTTPS policy、body
limit、路由匹配、身份提取、CSRF/权限、DTO 反序列化，最后进入业务处理函数。当前没有请求 ID 中间件。

## 四种身份

1. 管理员浏览器：Secure Cookie Session + CSRF。
2. 移动设备：设备 Bearer Token。
3. 自动化：API Key Bearer 令牌。
4. 监控：独立指标 Bearer 令牌。

路由显式选择一种身份，不能“依次尝试”多种 Token。这样避免低权限凭据意外落入高权限解析路径。

管理员不是通用 RBAC 用户。服务端保存规范化的管理员 `username`，不保存 email 或恒等角色，
配置入口只有 `BOOTSTRAP_ADMIN_USERNAME`；线上协议 Session 的 `role` 由服务端固定输出 `admin`。operator/viewer、
角色切换和 `ADMIN_EMAIL` 都不存在。浏览器登录、恢复会话、退出分别固定为
`POST /api/v1/auth/login`、`GET /api/v1/auth/session`、`POST /api/v1/auth/logout`，管理处理函数固定在
`/api/v1/admin/*`。数据面 `accounts` 只是媒体租户；移动实例用独立授权码配对，与这套管理 username 完全隔离。

## 登录准入

管理员请求体在 Argon2 之前限为 16 KiB。服务端对真实套接字来源与规范化账户实施固定失败预算；
未知/停用账户执行等价的占位验证，Argon2 并发为 2、等待最多 2 秒。错误不暴露账户存在性。

规范化的 username（3–64 bytes、首尾字母数字、字符 `[a-z0-9._-]`）、唯一当前 Argon2id 参数、随机
Session/CSRF token、SHA-256 摘要/常量时间匹配和原始
Cookie 解析、登录准入、数据库 Store、Cookie 属性、TTL 和撤销由服务端的管理认证实现提供。
产品只挂接管理员身份来保护备份租户和实例管理；移动端只允许待配对实例的授权码 bootstrap。

## 上传路由

移动合约的 product/version/revision 在客户端入队边界验证；HTTP create upload 验证存储编码、
配额、资源 metadata、manifest body、part 连续编号/size 与 BLAKE3。PUT part 最多等待 30 秒取得全局与
账户准入 permit，取得 permit 后流式执行 size/Hash 校验并写入唯一暂存区；当前没有覆盖整个 body
传输的独立 wall-clock 期限。complete 先重新验证所有持久化的 record 与文件 identity，再合并、哈希、
发布对象并提交资产事务。

客户端断开不应让已经提交给持久状态机的任务变成无人拥有。相反，在进入持久化的 point 之前取消要
清理临时文件。

## 图库路由

时间线游标是服务端编码的不透明值，限制 limit 和筛选组合。相册/标签 mutation 验证同账户 owner；
完整扫描与分批扫描使用不同完成语义。收藏、归档、回收站改变时追加 sync sequence 和 audit。

永久删除先确认 trashed；asset/resource 删除提交后，无引用 blob 行保留为可重试的物理回收意图。目录锚定的
unlink 与 blob-row 删除在同一 SQLite 事务中收口，失败回滚并由协调器重试；204 表示已收口，202 表示
用户可见删除已提交但物理回收仍待处理。仍有账户内资源引用的 blob 不会进入回收；本项目不跨账户去重。

## 响应与日志

成功 JSON 使用当前 DTO；`AppError` 统一映射为顶层包含 `code/message/retryable` 的 ErrorEnvelope；
当前实现不生成请求 ID，因此不伪造该可选字段。TraceLayer 记录 HTTP span，关键认证、提交协调和
存储错误另写结构化事件；不得假定每条日志都有统一操作 ID 或耗时字段。日志不应包含密码、Token、
媒体字节或任意客户端路径。metrics 只输出固定聚合 gauge，不使用 username 等高基数标签。

## 请求失败分层

- 400/422：请求形状或业务约束，通常不可原样重试。
- 401/403：身份/权限；设备需重新 bootstrap 或由操作者更新当前凭据，不能凭空刷新 Token。
- 409：幂等 identity 或状态冲突，先读取权威状态。
- 429：等待 Retry-After。
- 5xx：服务暂不可用，采用有界退避并保留本地队列。
