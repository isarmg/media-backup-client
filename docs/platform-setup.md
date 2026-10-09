# xszc 分平台安装与维护

适用于 xszc `1.0.0`。Android 与 iOS 都通过应用完成配对、设置和任务管理；Client 没有桌面服务或用于注入账户信息的 CLI。本指南覆盖安装、重新配对、后台任务查看/启停、诊断、升级和卸载，具体备份设置见[配置指南](configuration.md)，队列数据边界见[运维文档](operations.md)。

## 安装前准备

1. 请 Server 管理员创建备份实例，提供 Server HTTPS 根地址和实例授权码。应用登录弹窗中的“密码”就是此授权码。
2. Server 地址例如 `https://backup.example.com`，不能附加 `/admin`、`/v1`、查询参数或片段。手机需能访问它，设备时间与证书必须正常。
3. 从 [Client Releases](https://github.com/isarmg/xszc/releases) 下载同版资产与 `SHA256SUMS`。Android 正式包是 `xszc-android-1.0.0-arm64.apk`；iOS 是未签名的 `xszc-ios-1.0.0-unsigned.ipa`。
4. 安装包、手机系统版本、CPU 架构要匹配。Android 最低 API 26（Android 8），正式 APK 仅 arm64-v8a；iOS 最低 26.0。不要用卸载来解决 Debug/Release 签名冲突，卸载会删除待传数据。
5. ADB/curl 等命令在开发机执行，不需要安装到手机。注释解释用途；`ACTUAL_PID` 换成实际进程 ID，域名换成你的 Server。

可从开发机先检查公开健康入口：

```sh
# 仅访问公开健康端点，不发送授权码；-f 遇到 HTTP 错误返回失败，-sS 隐藏进度但显示错误。
# -o /dev/null 丢弃响应体，-w 输出状态码，最长等待 15 秒；正常应为 204。
curl -fsS --max-time 15 -o /dev/null -w '%{http_code}\n' https://backup.example.com/healthz
```

开发机可达不等于手机可达；验收仍需在手机完成真实上传。

## Android

### 1. 下载、校验和安装

有两种安装方式，选择一种即可。普通用户在手机打开已下载 APK，按系统提示仅为当前安装来源允许安装，完成后打开“媒体备份”；升级使用同签名正式 APK 覆盖安装，保留数据。

使用 ADB 的运维人员先安装 Android platform-tools，启用手机“开发者选项 → USB 调试”，连接后在手机接受电脑授权：

```sh
# 计算正式 APK 哈希，人工与同版 SHA256SUMS 的对应行比较。
sha256sum ./xszc-android-1.0.0-arm64.apk
# 列出设备；应为 device，unauthorized 需在手机确认。多设备时给每条 adb 加 -s 实际序列号。
adb devices
# 查看 CPU ABI，正式包要求列表包含 arm64-v8a。
adb shell getprop ro.product.cpu.abilist
# 覆盖安装同签名应用，-r 保留已有应用数据；看到 Success 才继续。
adb install -r ./xszc-android-1.0.0-arm64.apk
# 打开应用主界面。
adb shell am start -n org.sarmg.xszc/.MainActivity
# 只读查看安装版本及权限信息，核对 versionName 与目标版本。
adb shell dumpsys package org.sarmg.xszc
```

macOS 开发机计算哈希可用 `shasum -a 256 文件名`；Windows PowerShell 用 `Get-FileHash 文件名 -Algorithm SHA256`。这些命令只计算哈希，需自行对比校验文件，不会自动确认来源。

开发用 Debug APK 的构建与安装见配置指南。`INSTALL_FAILED_UPDATE_INCOMPATIBLE` 多为签名不匹配，核对原应用来源与[正式签名身份](android-signing.md)，不能通过卸载重装保留队列。

### 2. 首次配对与权限设置

1. 打开“本地”顶部的“备份”，或“设置”中的账户信息行。
2. 登录弹窗填 Server HTTPS 根地址，在“密码”填实例授权码，点“登录”。等待显示“备份实例已登录”。授权码隐藏输入，由应用安全存储管理。
3. 在“设置 → 照片权限设置”打开系统应用设置，按需要授予照片/视频权限。Android 13+ 图片和视频分别授权；Android 14+ 可以仅选定部分媒体。
4. 配置自动备份、仅 Wi-Fi、后台仅充电等条件，至少启用照片或视频一种。使用“仅相机目录”，或选择已授权的备份相册。
5. 开关和相册选择立即保存；先用少量媒体完成下一步验收，再依赖自动备份。

ADB 不写入账号、授权码、SQLite 或照片选择结果；照片权限应由用户在系统界面选择。

### 3. 验收与后台任务查看

在“本地”选择一两张照片手动备份；到“传输”查看从准备、上传到完成，再到“云端”打开刚上传的照片。最后请 Server 管理员核对同一实例、设备和媒体记录。

后台任务由 WorkManager 调度，Android 正常上传时使用数据同步前台服务及通知。自动任务当前以 6 小时周期请求调度，受 Wi-Fi、充电、电量和系统后台限制影响，不能保证每隔 6 小时准时执行。

```sh
# 查看本应用运行中的 Android 服务，辅助判断数据同步前台服务是否存在。
adb shell dumpsys activity services org.sarmg.xszc
# 获取应用进程 ID；输出为空表示当前没有运行进程。
adb shell pidof org.sarmg.xszc
```

没有常驻进程可能只是等待调度，不能据此认定备份失败；“传输”的逐项状态和 Server 完成记录才是业务验收依据。

### 4. 启动、停止与重新配对

- 启动自动备份：已登录、照片可访问后，在设置开启自动备份并选择媒体类型/相册，确保网络与电源条件满足。
- 停止未来自动任务：关闭“自动备份”。它不等于取消所有已开始的手动上传。
- 停止当前会话的全部上传/下载及自动任务：在设置点击“退出”，等待传输停止。退出保留安全存储凭据与本地队列；以后显式登录会核验并复用仍有效的同实例凭据。
- 取消单个上传批次：在“传输”对应批次菜单点“取消上传”，核对该批次结果；这表示取消任务，不应当作无损暂停。

授权码轮换时按顺序操作：先退出/停止当前任务，请管理员确认仍是同一个实例并提供新码，打开账户登录弹窗，保持相同 Server 地址，填新授权码登录，然后查看原有传输记录并做一次小文件上传验收。Client 会核对返回身份，不能把同实例旧队列改属新实例。

首次 Server 已配对但手机没保存 token 时，先修复存储/权限故障，再请管理员轮换授权码重新登录；不要反复提交已使用的旧码。切换账户或 Server 前先处理旧队列并保留证据。

### 5. 诊断

先看应用“传输”和错误提示，再检查系统权限、剩余空间、网络、电量及后台限制。USB 调试可用：

```sh
# 核对软件版本和系统实际授予的权限；只读，不授予或修改照片权限。
adb shell dumpsys package org.sarmg.xszc
# 先取得实际 pid，进程为空时先打开应用。
adb shell pidof org.sarmg.xszc
# 用实际 pid 查看应用日志，避免收集整个设备日志；Ctrl+C 结束。
adb logcat --pid=ACTUAL_PID
```

如需应急强制停止，可执行 `adb shell am force-stop org.sarmg.xszc`：它终止进程并让包进入 stopped 状态，后台任务可能直到用户再次打开才恢复。这不是正常暂停流程，优先在应用里退出；重新打开后检查队列恢复情况。日志可能含私人文件名、路径，分享前脱敏。

### 6. 升级与卸载

校验同签名新版 APK 后按第 1 步覆盖安装，核对版本、原队列和新上传。不要用 `adb shell pm clear`、系统“清除存储”或直接删应用数据库修复问题，它们会丢失队列和凭据。

卸载前：关闭自动备份，确认待传任务已完成或明确放弃，退出账号；正式退役还需 Server 轮换授权码/处理设备授权。然后在系统应用信息页卸载，或执行：

```sh
# 卸载应用并删除本机私有数据、数据库、待传分块和 Android 私有凭据。
adb uninstall org.sarmg.xszc
# 验收已无安装路径；正常应无输出。
adb shell pm path org.sarmg.xszc
```

卸载会丢失本机尚未完成的传输记录，不删除系统照片原件，也不删除 Server 已备份媒体。重装需要按当前 Server 授权重新配对；普通“退出”适合暂时停用，卸载用于确实移除软件。

## iOS 26 及以上

### 1. 安装与签名

Release 的 `xszc-ios-1.0.0-unsigned.ipa` 是未签名制品，不能直接在普通 iPhone 上安装。先校验：

```sh
# 在 macOS 计算 IPA 的 SHA-256，与同版 SHA256SUMS 对比。
shasum -a 256 ./xszc-ios-1.0.0-unsigned.ipa
```

组织已有 Apple 签名/受管理部署流程时，用自己的有效签名身份与适用于目标设备的 provisioning 完成签名，再通过该部署流程安装。仓库不提供签名证书或通用重签助手。

开发者的可执行安装路径是从同版源码使用 Xcode 签名到真机：

1. 在 macOS 安装 Xcode 26/iOS 26 SDK、XcodeGen 和仓库固定的 Rust 1.99.0，打开 Xcode 完成工具/SDK初始化，并登录自己的 Apple 开发身份。
2. 从源码根目录运行以下命令。

```sh
# 验证本机 Xcode/iOS SDK 满足当前工程要求。
./scripts/verify-ios-toolchain.sh
# 安装 iOS 实机与模拟器所需 Rust 目标标准库。
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
# 构建原生 Rust 库与 XCFramework，供 Swift 工程链接。
./scripts/build-ios-rust.sh
# 切换到 iOS 工程目录，按 project.yml 生成工程并用 Xcode 打开。
cd clients/ios
xcodegen generate
open Xszc.xcodeproj
```

3. 在 Xcode 选择 `Xszc` target → “Signing & Capabilities”，选择自己的 Team，检查 `org.sarmg.xszc` 的签名和 Keychain entitlement，解决 provisioning 错误后再运行。
4. 连接并信任 iPhone，按设备提示启用 Developer Mode，选择该真机为运行目标，点击 Run。首次打开按系统要求确认开发者信任。
5. 不要使用禁用签名的应用验证配对。模拟器配对测试也需有效的本地签名，否则 Keychain 可能返回 `-34018`，造成远端已配对、本机无法保存凭据。

### 2. 首次配对与设置

打开“本地”顶部“备份”或设置账户行，在弹窗输入 Server HTTPS 根地址与实例授权码，点击“登录”，等待“备份实例已配对”。然后在“照片权限设置”选择有限/完整访问，按需要开启自动备份、仅 Wi-Fi、充电限制，并至少启用照片或视频一种，选定可访问的自动备份相册。

iOS 使用 PhotoKit 相册选择范围，没有 Android 的“仅相机目录”选项。有限权限下只能处理用户允许的媒体。设置立即保存。

### 3. 传输查看、启停与验收

在本地选少量媒体创建备份，查看“传输”逐项完成，到“云端”打开照片，最后核对 Server 媒体记录。iOS 通过 BGProcessingTask/后台 URLSession 请求后台执行，实际运行时间由系统决定；关闭后台刷新、低电量或权限变化会推迟任务。

开启自动备份需有效登录、相册与类型选择，并满足网络/电源条件。关闭自动备份只取消后续自动调度；停止当前上传/下载及后台会话使用设置中的“退出”。退出保留安全存储凭据和本地任务，之后显式登录核验复用。取消具体批次在“传输”中使用“取消上传”，核对批次结果。不要把从多任务界面强制划掉应用当作支持后台持续备份的操作。

### 4. 重新配对

先退出当前会话，请管理员提供同一实例的新授权码；账户弹窗保持原 Server 地址，输入新码登录。成功后查看原队列、上传一张新照片并核对云端记录。已有有效凭据时应用会验证复用；授权码轮换后需新码，返回不同实例/设备身份时会拒绝错误绑定。

出现 Keychain `-34018` 时先修复安装签名和 entitlement，再请管理员轮换实例码重新配对。删除应用或改 SQLite 无法修复签名。

### 5. 诊断

检查应用传输状态、系统照片权限、存储空间、Wi-Fi/充电条件、后台 App 刷新及网络证书；前台重新打开应用，观察队列是否继续。通过 Xcode “Devices and Simulators” 选择已连接设备查看相关崩溃信息，或使用 macOS Console 选择该设备并筛选应用日志。只保留必要的脱敏错误、版本和任务 ID。

App 没有 `launchctl` 或 `systemctl` 服务入口；需要查看的是应用内任务和系统调度情况。不要把 Server 的 systemd 操作写成手机客户端启停步骤。

### 6. 升级与卸载

使用相同应用标识、兼容签名与 entitlement 的新版覆盖安装；完成后检查旧队列、登录状态和新上传。不同签名、不同 bundle ID 或 provisioning 不适用时，先修复部署，不以删除旧应用绕过。

卸载前关闭自动备份、确认待传任务处理完毕、退出会话，正式退役时再处理 Server 授权。系统“设置 → 通用 → iPhone 储存空间 → 媒体备份 → 删除 App”会删除应用及私有传输数据；“卸载 App/Offload”会保留文稿与数据，不是完整删除。删除后原系统照片和 Server 备份仍在。

Keychain 项可能由系统保留，卸载不等于撤销远端 token。重新安装后按实际安全存储/界面状态核验授权，必要时用 Server 新码配对；不能假定待传队列会随重装恢复。

## 常见故障与完成判据

| 现象 | 检查/处理 | 成功依据 |
|---|---|---|
| APK 无法覆盖安装 | 确认 arm64、系统版本、同 application ID 和同正式签名 | `adb install -r` 成功且旧队列仍在 |
| IPA 无法安装 | 确认已签名、provisioning 允许该设备、系统版本和 entitlement | 真机打开应用并能保存配对 |
| 健康检查正常但登录失败 | 核对实例授权码、实例是否存在/已轮换，以及手机自身网络 | 应用登录成功并保存凭据 |
| 后台长时间无上传 | 检查权限、相册、媒体类型、电量、Wi-Fi/充电、后台限制 | 前台真实任务完成，自动任务在条件允许时执行 |
| `retry_wait` | 查看下一次重试与网络；保留已有分块 | 到期恢复，不重写已有任务身份 |
| 永久失败/身份不一致 | 保存任务 ID 和错误，核对 Server 身份及源媒体 | 同一身份下完成定位或明确单任务取消 |
| 缓存占用空间 | 使用“清空浏览缓存”，仅清可重建预览 | 上传队列和照片原件不受影响 |
| 准备完成却上传失败 | 保留队列及 prepared 分块，核对认证/网络 | 原任务继续投递并在云端可查看 |
