# Media Backup Client

本仓库仅构建 Android/iOS、Rust Client 核心、媒体校验库和移动 FFI。Server、管理 Web、设备与管理员认证服务，
以及唯一产品协议源码位于 https://github.com/isarmg/media-backup-server 。Client 的 Cargo 依赖固定完整协议提交，
无需相邻 Server 或 Foundation 仓库。

独立 Client 开发版为 0.3.0，移动状态 epoch 为 `media-backup-mobile-v0.3-r1`，移动 C/JNI 调用仍使用明确的 ABI v2。
目录、队列数据库、后台工作标识属于新的当前状态，不兼容或迁移旧数据。Server 支持矩阵不等于移动状态恢复支持。

原产品仓库的 Git 历史、Android application ID、证书身份及 `android-signing` 环境保留在本仓库。
普通 CI 不读取签名 Secrets；正式发布工作流仍要求独立受保护签名环境及固定证书指纹，拒绝 Debug APK 和覆盖已有 Release。
本次只拆分源码与工作流，未触发签名或创建新 Release，也未将 Secrets 移到 Server。

原有跨端学习文档用于解释产品整体行为。文档里的 Server、管理 Web、Server Schema 及部署路径须在 Server 仓库阅读和执行，
不表示这些实现仍位于本仓库。
