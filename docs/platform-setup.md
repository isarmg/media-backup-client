# 安装、更新与卸载

当前版本 `1.1.0` 支持 Android 8.0（API 26）及以上的 arm64 设备，以及 iOS 26.0 及以上。安装后按[第一次备份](getting-started.md)登录和验证。

## Android

### 安装正式 APK

从 [v1.1.0 发行页](https://github.com/isarmg/xszc/releases/tag/v1.1.0)下载 `xszc-android-1.1.0-arm64.apk` 和 `SHA256SUMS`。核对 APK 的 SHA-256 后，在手机打开文件，按系统提示为本次来源允许安装。

电脑计算哈希：Linux 使用 `sha256sum 文件名`，macOS 使用 `shasum -a 256 文件名`，Windows PowerShell 使用 `Get-FileHash 文件名 -Algorithm SHA256`。结果应与同版清单对应行一致。

已安装 Android platform-tools、手机开启 USB 调试并授权电脑时，可用以下命令安装。多设备连接时给每条 `adb` 加 `-s 实际序列号`。

```sh
adb devices
adb shell getprop ro.product.cpu.abilist
adb install -r ./xszc-android-1.1.0-arm64.apk
adb shell am start -n org.sarmg.xszc/.MainActivity
```

设备应显示 `device`，ABI 包含 `arm64-v8a`，安装返回 `Success`。`-r` 用同签名包覆盖安装并保留应用数据。

### 更新

使用同应用 ID、同签名的正式 APK 覆盖安装，再确认版本、原队列和一次新上传。签名不匹配时先核对安装来源和[正式签名身份](android-signing.md)。卸载或“清除存储”会删除待传状态，不适合作为签名冲突的修复方式。

### 卸载

先关闭自动备份，完成或明确放弃待传任务，再退出账户。在系统应用信息页卸载，或执行：

```sh
adb uninstall org.sarmg.xszc
adb shell pm path org.sarmg.xszc
```

第二条正常无输出。卸载删除本机数据库、待传分块和 Android 私有凭据；系统照片原件和服务端已备份媒体保留。正式退役还需请管理员处理设备授权。

## iOS

### 安装发行包

发行资产 `xszc-ios-1.1.0-unsigned.ipa` 未签名。先计算 SHA-256，与同版 `SHA256SUMS` 对应行核对：

```sh
shasum -a 256 ./xszc-ios-1.1.0-unsigned.ipa
```

使用自己的有效 Apple 签名身份和适用于目标设备的 provisioning 完成签名，再通过 Xcode、Apple Configurator 或已有受管理部署流程安装。仓库提供未签名包，具体证书与设备准入由所选 Apple 部署方式决定。

### 从源码安装到设备

在有 Xcode 26、iOS 26 SDK、XcodeGen `2.46.0` 和 Rust `1.99.0` 的 Mac 上，按[构建指南](development.md#ios)生成工程。选择 `Xszc` target 的 Signing & Capabilities，设置自己的 Team，连接并信任设备，按提示启用 Developer Mode 后运行。

配对会保存 Keychain 凭据。设备及模拟器测试均保留适用的签名和 entitlement；禁用签名可能导致 `-34018`，此时先修复签名，再处理登录。

### 更新与删除

使用同应用标识、兼容签名和 entitlement 的新版覆盖安装，检查原队列、登录状态和新上传。删除前先处理待传任务并退出。

“设置 → 通用 → iPhone 储存空间 → 媒体备份 → 删除 App”删除应用与私有传输数据；“卸载 App/Offload”保留文稿与数据。系统照片及服务端备份保留。Keychain 项可能继续存在，删除应用不等于撤销远端 Token；退役时另行处理设备授权。

## 安装后

按[第一次备份](getting-started.md)完成登录、照片权限和小文件上传。登录和后台问题见[排查问题](troubleshooting.md)，开发用 Debug 构建见[构建与测试](development.md)。
