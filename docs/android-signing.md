# Android 正式签名

应用 ID 为 `org.sarmg.mediabackup`，PKCS#12 alias 为 `media-backup-android-release`。
当前发布证书 SHA-256 为 `0cfc2811d48cdeab3e6d857029d879e001ab9531c06784b4d48d15a847771421`。
正式 APK 使用这一固定签名身份；Debug APK 仅用于开发验证。

GitHub 仓库 `isarmg/media-backup-client` 的 `android-signing` 环境保存两个 Secrets：

- `MEDIA_BACKUP_ANDROID_SIGNING_PKCS12_BASE64`
- `MEDIA_BACKUP_ANDROID_SIGNING_PKCS12_PASSWORD`

签名环境仅允许审定的发行标签；具体规则以 GitHub 环境配置为准。发布前需核对对应提交、发布工作流和标签准入，不放行任意分支或 pull request。
私钥和密码不进入 Git、Release 附件或构建日志；发布任务只在临时目录生成权限受限的签名输入。

正式流水线执行 `assembleRelease`，并使用 `apksigner` 验证签名、唯一证书及以上指纹；同时检查 application ID 和唯一 `arm64-v8a` 原生库。
只有客户端校验、Android 和 iOS 全部完成后才创建 Release。本仓库不发布 Server。iOS 制品明确标注 unsigned，不冒充具有 Apple provisioning 的可安装包。

签名私钥另有受限权限的离线备份。仓库管理员应将备份转存至自己的加密存储并妥善保存密码；GitHub Secrets 不能作为唯一可恢复备份。
