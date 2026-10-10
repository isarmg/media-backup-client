# xszc 工作流程与流程树

## 1. 总流程树

```text
xszc
├─ 开发
│  ├─ 修改 Rust 移动核心、FFI 或 Android/iOS 宿主
│  ├─ 协议变化在独立 Server 仓库完成后更新精确 Git revision
│  ├─ 运行契约、格式、Clippy、测试
│  └─ CI 分别验证 Rust、Android、iOS 与发行归档
├─ 运行
│  ├─ 管理员登录并创建备份账户及设备实例
│  ├─ 移动端使用实例授权码配对、选择相册、扫描媒体
│  ├─ 本地队列分块上传并幂等提交
│  ├─ 服务端维护时间线、组织和变更序列
│  └─ 新设备分页下载并写回系统照片库
└─ 运维
   ├─ 验证不可变发行归档
   ├─ 安装固定物理版本并配置 TLS
   ├─ health/metrics/doctor 监测
   └─ 保全配置、私有数据和诊断记录
```

## 2. 配套服务端流程（不在本仓库执行）

以下步骤描述移动端依赖的系统边界，实际命令、配置和部署文件均位于
[xszs](https://github.com/isarmg/xszs)，不能在本仓库执行：

1. 启动脚本、systemd 和进程分别确认运行主机为 Linux x86_64。
2. 确认命令是 `xszs run --release-root RELEASE_ROOT`，进程位于 manifest 声明的固定物理版本目录。
3. 校验源码 revision、`x86_64-unknown-linux-gnu` target、API、结构定义、FFI、Web 与全树文件摘要和权限。
4. 解析环境配置，规范化并验证 `BOOTSTRAP_ADMIN_USERNAME`，再验证生产 HTTPS、可信代理和路径组合。
5. 按稳定顺序取得数据库和 `DATA_DIR` 相邻的运行锁。
6. 数据库不存在时排他创建当前结构定义；存在时在私有副本上验证元数据与现场指纹。
7. 启动时先协调上传提交、无引用 blob 回收和 orphan commit 暂存区，再启动每 120 秒一次、跳过错过 tick
   的周期协调任务；停机诊断可用 `reconcile scan` 走相同持锁路径。
8. 服务端统一监听、信号处理、健康/诊断和有界优雅关闭；上传协调作为 Degrading 任务注册。
   中断时的 SQLite/文件系统持久状态仍由下一次启动的产品协调逻辑处理。

## 3. 管理员与设备接入

```text
首次启动环境中的 BOOTSTRAP_ADMIN_USERNAME + BOOTSTRAP_ADMIN_PASSWORD
  -> 管理员认证对 username 执行 trim ASCII whitespace + ASCII lowercase
  -> 要求 canonical 3..64 bytes、首尾字母数字、字符仅 [a-z0-9._-]，明确拒绝 @
  -> 服务端在没有管理员时创建管理员记录
  -> POST /api/v1/auth/login {username,password}
  -> 精确 AdministratorSession + HttpOnly Cookie
  -> GET /api/v1/auth/session 轮换 CSRF
  -> /api/v1/admin/* 创建备份账户及设备实例
  -> 手机 /v1/auth/bootstrap {authorization_code,device_name,platform}
  -> 设备 Token 安全存储
```

浏览器、设备、API Key、指标 Token 是四条独立授权链。浏览器登录由服务端根据真实套接字对端
和规范化账户实施准入，并以并发上限和超时保护 Argon2；代理来源解析只属于产品移动业务授权链。
这里的管理员 username 只属于服务端管理面；移动端使用设备实例授权码配对并取得
设备 Token。设备/API Key 与管理员身份独立，不能互换凭据。

## 4. 扫描与入队

Android 通过 MediaStore、iOS 通过 PhotoKit 读取用户授权范围。扫描结果经过相册选择/排除规则。
Android 只在扫描未截断、非“仅相机目录”、照片和视频均启用且完整授权时请求替换；iOS 在完整授权时请求替换。其他情况使用 `replace_members=false` 追加同步。两端每个请求最多发送 10,000 个成员，替换标志只用于首批，后续批次追加。
原始媒体和缩略图形成资源
描述后，任务先写入 `client-v1.sqlite`，暂存区使用 `backup-staging-v1`，然后才交给系统后台调度。

这里的“持久队列”不是无条件恢复保证。`ready` 与带 `prepared_json` 的到期 `retry_wait` 会直接复用
已落盘分块；只有没有准备结果的任务才重新读取源文件。准备使用每次唯一的代次目录，成功将
新结果持久化后回收同一任务的旧代次；若准备在持久化前失败，本轮未引用目录要等后续成功准备
才能回收。排障时应定位并保全单个 job 证据，不能删除整个 `backup-staging-v1/`。

## 5. 分块上传与提交

```text
创建 upload
  -> 服务端返回 upload_id/缺失分块
  -> 客户端逐块 PUT
  -> 服务端限制大小并验证分块
  -> complete 请求
       ├─ 分块不完整：返回可重试状态
       ├─ Hash/协议不符：拒绝
       └─ 完整：合并临时对象、验证 BLAKE3、原子提交数据库与最终文件
```

同一资源重复提交必须返回同一逻辑结果；账户内相同内容可复用对象，但资源归属与权限仍按账户隔离。
临时文件和最终路径都经过目录锚定文件系统校验，禁止路径逃逸、符号链接和特殊文件。

## 6. 图库与增量同步

所有会影响移动视图的变更取得单调 sequence。客户端保存上次游标并请求 `/v1/sync?after=...`；完整
时间线使用不透明分页游标，不能解析或自行构造。收藏、归档、标签、相册关系、回收站和重复组都
写入同一当前结构定义。永久删除先验证资产处于回收站，在一个事务中删除 asset/resource 并写 change/audit；
最后一个引用消失后，blob 行继续作为持久化的物理回收意图。协调器在 SQLite 删除事务仍打开时执行
目录锚定的 unlink：成功后提交删行，失败则回滚并保留行。请求即时收口返回 204，仍待重试返回 202；启动、
每 120 秒周期和手工 `reconcile scan` 都会继续处理，不会因用户可见删除已经提交而返回可诱导盲重放的 500。

## 7. 恢复流程

新设备登录后分页取得时间线，先下载鉴权缩略图供选择，再按单项或批量请求原始资源，最后交给
MediaStore/PhotoKit 写入系统照片库。当前 Android/iOS 宿主会检查 HTTP 成功和 `plain-v1` 合同，但恢复
前会读取资源清单，将下载文件暂存到私有目录，并调用 Rust 流式校验 size/BLAKE3；校验失败不会发布到
系统照片库。服务端保存原始字节，所以不存在服务端解密步骤或设备密钥依赖。

## 8. 发行流程

```text
干净 checkout + 精确 v1.1.0 tag
  -> 校验 tag、VERSION、Android versionName 与 iOS MARKETING_VERSION
  -> 运行 Rust、合同、供应链与移动平台测试
  -> Android 从受保护 Environment 取得规范 alias 的既有签名 PKCS#12，assembleRelease
  -> apksigner 唯一 signer/固定指纹 + aapt2 application ID + arm64-v8a ABI 复验
  -> 构建未签名 iOS IPA、校验和与身份清单
  -> GitHub Release（禁止覆盖既有资产）
```

Android 与 iOS 制品使用同一版本和移动 epoch；静态门禁发现的身份/ABI 漂移会阻止发行，运行行为仍需
各平台测试覆盖，不能把静态字符串门禁当成完整端到端证明。普通 CI 只构建 Debug/unsigned 移动制品，
不得取得 Android 正式秘密；当前签名身份不接受旧包、旧证书或旧秘密名作为回退。

## 10. xcsc 依赖流程

```text
`xcsc-client.toml` 声明 xcsc platform generation 1、版本 1.0.0
  -> `crates/mobile-ffi/Cargo.toml` 固定单个 `xcsc =1.0.0`、mobile-ffi feature 和完整 Git revision
  -> Cargo.lock 固定完整依赖图
  -> C/JNI 验收检查 ABI revision 1、长度边界、结果释放与 stale handle
  -> Android/iOS 宿主启动时再次核对 ABI revision
```

当前公共依赖是单个 `xcsc =1.0.0` 包，通过 `xcsc::mobile_ffi` 内部模块消费移动 FFI；Android 另外启用同包的 `jni` 功能开关。Git revision 为
`c45e48e93e360542c2e1db6c6441a9e29b344b03`。仓库负责 Android/iOS 宿主、移动核心和原生桥接，不包含管理 Web 或 npm 工作区。
核心验证命令为：

```bash
./scripts/check-mobile-contract.sh
./scripts/test-mobile-ffi-c.sh
./scripts/test-mobile-ffi-jni.sh
cargo test --workspace --locked
```
