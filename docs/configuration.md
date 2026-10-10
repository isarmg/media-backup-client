# xszc 配置指南

首次部署或日常维护请先阅读[分平台全流程指南](platform-setup.md)：按本机平台完成安装、配对、重新配对、服务/后台任务查看与启停、诊断和卸载，命令旁均说明用途。本文详细说明配置字段和业务操作。

本文适用于 xszc `1.1.0`。账号、授权码和备份偏好由 Android/iOS 应用管理；项目没有用于写入这些设置的命令行接口，也不支持用 `adb`、Plist 或 SQLite 直接注入配置。

## 命令用途与执行边界

移动配置通过应用界面保存，下列命令用于构建、安装和只读验收，不用于写入账号或照片权限。

| 命令/脚本 | 用途 |
|---|---|
| `curl ... /healthz` | 检查公开 HTTPS 健康入口，正常 HTTP 204；不验证登录或上传 |
| `rustup target add ...` | 安装交叉编译目标标准库，按平台准备 Android/iOS 构建 |
| `cargo install cargo-ndk --version 4.1.2 --locked` | 安装与 CI 同版的 Android NDK/Rust 构建辅助工具，按工具锁文件解析依赖 |
| `./scripts/build-android-rust.ps1` | Windows PowerShell 中编译 Android 原生 Rust 库 |
| `gradle -p clients/android testDebugUnitTest assembleDebug` | 运行 Android JVM 单元测试并构建 Debug APK，不生成正式签名发行 |
| `adb devices` | 查看已连接的调试设备和授权状态 |
| `adb install -r APK` | 安装/覆盖同签名 APK，保留应用数据 |
| `adb shell am start -n org.sarmg.xszc/.MainActivity` | 打开应用主界面 |
| `adb shell dumpsys package org.sarmg.xszc` | 只读查看版本和系统权限信息；配合 sed 只筛选显示区段 |
| `adb shell pidof org.sarmg.xszc` | 获取正在运行的应用 pid，未运行时为空 |
| `adb logcat --pid=PID` | 只查看实际应用进程日志，Ctrl+C 结束查看 |
| `./scripts/verify-ios-toolchain.sh` | 验证 Xcode 26 和 iOS 26 SDK |
| `./scripts/build-ios-rust.sh` | 编译实机/模拟器库并打包供 Swift 链接的 XCFramework |
| `xcodegen generate` | 按 project.yml 生成 Xcode 工程 |
| `xcodebuild ... test` | 构建并执行模拟器测试，配对/Keychain 测试不能禁用本地签名 |

`adb` 多设备时指定 `-s 实际序列号`；应用未运行时先打开再查日志，不能将空 pid 传给 `logcat`。原始完整设备日志可能包含隐私，不作为默认工单附件。


## 1. 服务端准备

先由服务端管理员完成以下操作：

1. 登录配套服务端 xszs 的管理 Web；
2. 创建一个备份实例；
3. 通过受保护渠道把该实例的授权码交给设备用户；
4. 确认外部 HTTPS 根地址可以从手机访问。

在开发机验证公开健康端点；正常结果为 HTTP `204`：

```sh
curl -fsS -o /dev/null -w '%{http_code}\n' \
  https://backup.example.com/healthz
```

健康检查只证明服务可达，不代表授权码有效或备份已完成。服务端地址必须是 HTTPS origin，例如 `https://backup.example.com`；不要填写 `/admin`、`/v1`、查询参数或片段。

Android 使用无标题的居中 Material 3 原生弹窗，iOS 使用无标题的居中 Liquid Glass 弹窗。两端均以两个独立的原生输入框显示服务器地址和密码，下方显示“登录 / 取消”按钮；密码仍使用服务端实例授权码，并始终隐藏输入内容。提交期间暂停编辑。授权码禁用自动更正，并由系统安全存储保存。

## 2. Android 安装与打开

构建 Debug APK：

```powershell
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
cargo install cargo-ndk --version 4.1.2 --locked
./scripts/build-android-rust.ps1
gradle -p clients/android testDebugUnitTest assembleDebug
```

连接已启用 USB 调试的设备，安装并打开应用：

```sh
adb devices
adb install -r clients/android/app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n org.sarmg.xszc/.MainActivity
```

正式 APK 只包含 `arm64-v8a`，必须使用正式 Release 的签名产物；Debug APK 不应作为正式更新分发。

## 3. Android 配对与备份设置

在应用中按以下顺序操作：

1. 点击“本地”顶部的“备份”，或在“设置”中点击账户信息行；
2. 在居中弹窗中填写 HTTPS 服务器根地址；
3. 在“密码”栏输入服务端管理员提供的实例授权码；
4. 点击“登录”，等待账户行显示“备份实例已登录”，右侧显示“退出”；
5. 在“设置 → 照片权限设置”直接进入系统 App 设置页，选择全部访问或限制访问；
6. 按需要开启“自动备份”“仅 Wi-Fi 上传”“后台仅充电时运行”，开关变更立即保存并生效；
7. 至少启用“自动备份照片”或“自动备份视频”之一；
8. 选择“仅相机目录”，或关闭它后勾选可访问的自动备份相册，相册选择立即生效；
9. 在“浏览缓存”中把磁盘缓存设置为 `64`～`1024 MiB`。

本地图库只显示系统实际授权的照片，不提供独立照片选择器或导入确认页。图库监听 MediaStore 变化并自动刷新；顶部按钮固定，日期随照片滚动，双指缩放范围为每行 1～8 张照片。退出会停止上传和自动任务，保留加密存储中的配对凭据供下次显式登录验证复用。

Android 13+ 会分别请求照片和视频权限；Android 14+ 还允许只授权选中的媒体。应用只能处理系统实际授予的内容。可用以下只读命令检查安装和权限状态：

```sh
adb shell dumpsys package org.sarmg.xszc | \
  sed -n '/requested permissions:/,/install permissions:/p'
adb shell dumpsys package org.sarmg.xszc | \
  sed -n '/runtime permissions:/,/Queries:/p'
```

不要用 `pm grant` 代替用户在系统界面中的照片选择，尤其是 Android 14 的“仅选中的照片和视频”。

## 4. iOS 构建与运行

iOS 最低部署目标为 26.0，需要 Xcode 26 和 iOS 26 SDK：

```sh
./scripts/verify-ios-toolchain.sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
./scripts/build-ios-rust.sh
cd clients/ios
xcodegen generate
# 列出可用模拟器，选用已安装 iOS 26 运行时的实际 iPhone 设备 UUID。
xcrun simctl list devices available
# 将占位值替换为上一条输出中的实际 UUID，不使用通用的仅构建目标运行测试。
simulator_udid="REPLACE_WITH_AVAILABLE_IOS26_SIMULATOR_UUID"
xcodebuild -project Xszc.xcodeproj -scheme Xszc \
  -sdk iphonesimulator -destination "platform=iOS Simulator,id=$simulator_udid" test
```

模拟器构建使用本地临时签名，无需 Apple Developer 证书。不要设置 `CODE_SIGNING_ALLOWED=NO` 运行配对流程，否则钥匙串可能返回 `-34018`，导致服务器已完成配对而应用无法保存凭据。

仓库 Release 提供的 `xszc-ios-1.1.0-unsigned.ipa` 未签名，不能直接作为普通设备安装包。请使用自己的 Apple Developer 身份签名，再通过 Xcode、Apple Configurator 或受管理部署系统安装；仓库不保存或接收签名凭据。

## 5. iOS 配对与备份设置

首次打开本地图库时按系统提示选择部分访问或完整访问；“设置 → 照片权限设置”直接进入系统中的 App 设置页，调整可访问范围。部分访问时只显示系统授权的照片。应用不再提供独立的系统照片选择器或导入确认页，本地图库监听系统照片变化并自动刷新。本地和云端均支持双指捏合缩小缩略图、张开放大，每行可显示 1～8 张照片；顶部按钮固定并保留原生玻璃效果，照片从按钮下方滚动，日期不吸顶。点击照片直接全屏显示，关闭时直接返回图库。云端自动同步变化，“筛选”与本地一样使用原生菜单，相册、类型和设备选择立即生效，自定日期范围使用原生浮窗；“更多”保留回收站和重复项入口。

在应用中按以下顺序操作：

1. 点击“本地”页顶部的“备份”，或进入“设置”并点击账户行；
2. 在居中的 iOS 原生玻璃控件中填写服务端 HTTPS 根地址，并在“密码”栏输入实例授权码；
3. 点击“登录”，等待页面显示“备份实例已配对”；
4. 进入“设置”，选择“自动备份”“仅 Wi-Fi 上传”“后台仅充电时运行”；
5. 至少启用“自动备份照片”或“自动备份视频”之一；
6. 展开“自动备份相册”，点击“选择可访问的相册”，按系统提示授予完整或有限照片权限；
7. 勾选至少一个需要自动备份的相册，选择和开关变更立即保存并生效；
8. 将浏览缓存设置为 `64`～`1024 MiB`。

云端顶部提供“选择”和“下载”：点击“选择”后勾选照片或视频，右侧“全选”会选择当前筛选范围内的全部媒体，也可按月份全选；点击“下载”后原件依次校验并保存到系统相册。未进入选择模式时点击“下载”会先进入多选。下载进度和逐项结果显示在“传输”中，单项失败不阻止后续下载；退出或切换账户会停止下载。“仅收藏”位于筛选菜单内。

iOS 通过 PhotoKit 相册选择自动备份范围，没有 Android 的“仅相机目录”开关。备份偏好在配对前也能即时保存。登录后账户行右侧显示“退出”；退出会停止当前会话和后台任务，并保留安全存储的配对凭据供下次显式登录复用。后台执行时间由系统决定；低电量、关闭后台刷新或照片权限变化都可能推迟上传。

## 6. 首次验证

完成配置后，不要只看“已配对”。按顺序验证：

1. 在“本地图库”选择少量媒体，手动创建备份；
2. 在“传输”查看任务从准备、排队/上传进入完成；
3. 在“云端”打开刚上传的照片或视频；
4. 在服务端管理页确认同一实例、设备和媒体记录；
5. 再启用自动备份，观察 Wi-Fi/充电限制是否符合预期。

系统日志只用于定位崩溃和平台调度，禁止公开包含私人路径、文件名或账号信息的完整日志。Android 开发调试可先限定到应用进程：

```sh
adb shell pidof org.sarmg.xszc
adb logcat --pid="$(adb shell pidof org.sarmg.xszc | tr -d '\r')"
```

## 7. 授权码轮换和故障恢复

服务端管理员更换实例授权码后，旧设备 Token 会失效。点击“设置”中的账户信息行打开登录弹窗，保留相同服务端地址，输入新授权码并重新配对。客户端会核对服务端返回的实例身份；若身份不一致会拒绝把现有队列绑定到另一个实例。

两端在本机已有有效配对凭据时，会验证并复用该凭据，不再次提交已使用的授权码。若第一次配对时服务器已成功，但本机未保存 Token，需要先修正本机存储或签名问题，再在服务端实例详情更换授权码后重新配对。

出现失败时按以下顺序检查：

1. 用 `/healthz` 确认网络、DNS、时间和 TLS 证书；
2. 在服务端管理页确认实例仍存在、授权码未再次轮换；
3. 检查系统实际授予的照片权限、可用空间、Wi-Fi和省电限制；
4. 在“传输”区分准备、等待重试、永久失败和完成；
5. 保留任务 ID 与必要的脱敏日志后再排障。

不要删除应用数据、队列 SQLite 或 `prepared` 分块来“清缓存”。“清空浏览缓存”只删除可重建的图库图片缓存，不改变上传队列或原始照片。更完整的数据边界与发布验收见[运维文档](operations.md)。
