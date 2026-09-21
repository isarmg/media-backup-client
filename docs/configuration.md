# Media Backup Client 配置指南

本文适用于 Media Backup Client `0.4.11`。账号、授权码和备份偏好由 Android/iOS 应用管理；项目没有用于写入这些设置的命令行接口，也不支持用 `adb`、Plist 或 SQLite 直接注入配置。

## 1. Server 准备

先由 Server 管理员完成以下操作：

1. 登录 Media Backup 管理 Web；
2. 创建一个备份实例；
3. 通过受保护渠道把该实例的授权码交给设备用户；
4. 确认外部 HTTPS 根地址可以从手机访问。

在开发机验证公开健康端点；正常结果为 HTTP `204`：

```sh
curl -fsS -o /dev/null -w '%{http_code}\n' \
  https://backup.example.com/healthz
```

健康检查只证明服务可达，不代表授权码有效或备份已完成。Server 地址必须是 HTTPS origin，例如 `https://backup.example.com`；不要填写 `/admin`、`/v2`、查询参数或片段。

## 2. Android 安装与打开

构建 Debug APK：

```powershell
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
cargo install cargo-ndk
./scripts/build-android-rust.ps1
gradle -p clients/android testDebugUnitTest assembleDebug
```

连接已启用 USB 调试的设备，安装并打开应用：

```sh
adb devices
adb install -r clients/android/app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n org.sarmg.mediabackup/.MainActivity
```

正式 APK 只包含 `arm64-v8a`，必须使用正式 Release 的签名产物；Debug APK 不应作为正式更新分发。

## 3. Android 配对与备份设置

在应用中按以下顺序操作：

1. 点击顶部的“登录 / 账户”，或在“设置”中点击“登录 / 切换账户”；
2. 在服务器地址中填写 HTTPS 根地址；
3. 在实例授权码中粘贴 Server 管理员提供的授权码；
4. 点击“配对”，等待页面显示“备份实例已配对”；
5. 打开“设置”，选择“自动备份”“仅 Wi-Fi”“仅充电时上传”；
6. 至少启用“自动备份照片”或“自动备份视频”之一；
7. 选择“仅相机目录”，或关闭它后点击“授权并读取自动备份相册”并勾选相册；
8. 点击“保存备份偏好”；
9. 在“浏览缓存”中把磁盘缓存设置为 `64`～`1024 MiB`。

Android 13+ 会分别请求照片和视频权限；Android 14+ 还允许只授权选中的媒体。应用只能处理系统实际授予的内容。可用以下只读命令检查安装和权限状态：

```sh
adb shell dumpsys package org.sarmg.mediabackup | \
  sed -n '/requested permissions:/,/install permissions:/p'
adb shell dumpsys package org.sarmg.mediabackup | \
  sed -n '/runtime permissions:/,/Queries:/p'
```

不要用 `pm grant` 代替用户在系统界面中的照片选择，尤其是 Android 14 的“仅选中的照片和视频”。

## 4. iOS 构建与运行

iOS 最低部署目标为 27.0，需要 Xcode 27 和 iOS 27 SDK：

```sh
./scripts/verify-ios-toolchain.sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
./scripts/build-ios-rust.sh
cd clients/ios
xcodegen generate
xcodebuild -project MediaBackup.xcodeproj -scheme MediaBackup \
  -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO test
```

仓库 Release 提供的 `media-backup-ios-0.4.11-unsigned.ipa` 未签名，不能直接作为普通设备安装包。请使用自己的 Apple Developer 身份签名，再通过 Xcode、Apple Configurator 或受管理部署系统安装；仓库不保存或接收签名凭据。

## 5. iOS 配对与备份设置

在应用中按以下顺序操作：

1. 点击“登录账户”，或进入“设置”并点击“登录 / 切换账户”；
2. 填写 Server HTTPS 根地址和实例授权码；
3. 点击“配对”，等待页面显示“备份实例已配对”；
4. 进入“设置”，选择“自动备份”“仅 Wi-Fi 上传”“后台仅充电时运行”；
5. 点击“保存备份偏好”；
6. 展开“自动备份相册”，点击“选择可访问的相册”，按系统提示授予完整或有限照片权限；
7. 勾选需要自动备份的相册；
8. 将浏览缓存设置为 `64`～`1024 MiB`。

iOS 没有 Android 的“仅相机目录”“仅照片”“仅视频”开关。后台执行时间由系统决定；低电量、关闭后台刷新或照片权限变化都可能推迟上传。

## 6. 首次验证

完成配置后，不要只看“已配对”。按顺序验证：

1. 在“本地图库”选择少量媒体，手动创建备份；
2. 在“传输”查看任务从准备、排队/上传进入完成；
3. 在“云端图库”刷新并打开刚上传的照片或视频；
4. 在 Server 管理页确认同一实例、设备和媒体记录；
5. 再启用自动备份，观察 Wi-Fi/充电限制是否符合预期。

系统日志只用于定位崩溃和平台调度，禁止公开包含私人路径、文件名或账号信息的完整日志。Android 开发调试可先限定到应用进程：

```sh
adb shell pidof org.sarmg.mediabackup
adb logcat --pid="$(adb shell pidof org.sarmg.mediabackup | tr -d '\r')"
```

## 7. 授权码轮换和故障恢复

Server 管理员更换实例授权码后，旧设备 Token 会失效。回到“登录 / 切换账户”，保留相同 Server 地址，输入新授权码并重新配对。Client 会核对 Server 返回的实例身份；若身份不一致会拒绝把现有队列绑定到另一个实例。

出现失败时按以下顺序检查：

1. 用 `/healthz` 确认网络、DNS、时间和 TLS 证书；
2. 在 Server 管理页确认实例仍存在、授权码未再次轮换；
3. 检查系统实际授予的照片权限、可用空间、Wi-Fi和省电限制；
4. 在“传输”区分准备、等待重试、永久失败和完成；
5. 保留任务 ID 与必要的脱敏日志后再排障。

不要删除应用数据、队列 SQLite 或 `prepared` 分块来“清缓存”。“清空浏览缓存”只删除可重建的图库图片缓存，不改变上传队列或原始照片。更完整的数据边界与发布验收见[运维文档](operations.md)。
