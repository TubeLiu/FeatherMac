# FeatherMac 1.0.0

Sign iOS apps and install them on your own device — from one native Mac app, without opening Xcode.

## English

### What this is

If you have a paid Apple Developer account and you sideload apps onto your own iPhone, you know the routine: open Xcode to make a certificate, go to the developer portal for a bundle ID, register the device, download a provisioning profile, find a signing tool, then find another tool to install the result. Six places, and none of them talk to each other.

FeatherMac does the whole chain in one window. Import an IPA, and it creates the certificate, registers your device, generates the provisioning profile, signs, and installs — while showing you what it is doing at each step.

**This is for people who already pay for the Apple Developer Program.** Certificates come from Apple's App Store Connect API, which free (Personal Team) accounts cannot use. If you are looking for 7-day signing with a free Apple ID, this is not that tool.

### Why it exists

On 15 July 2026 a signing certificate expired and every part of a working setup stopped at once. Renewing it meant Xcode, the portal, re-exporting a `.p12`, re-importing it, regenerating profiles — an afternoon of clicking through five interfaces to recover from something entirely predictable.

FeatherMac was built so that never costs an afternoon again. Certificates are created, renewed, and revoked inside the app. It warns you before one expires, and tells you whether the certificate on your Mac still matches what Apple has on file — so the failure gets caught while it is still a warning, not after signing breaks.

### What you get

**Certificates without Xcode.** Create an iOS Development certificate from inside the app. The private key is generated on your Mac and never leaves it — only the certificate request is uploaded. When Apple's certificate limit is reached, FeatherMac lists what you have and offers to revoke one and continue. Expired certificates get a one-click renewal.

**A setup wizard that catches mistakes early.** Connecting your Apple account takes four steps. The Key ID is read from the `AuthKey_*.p8` file name, the file is checked before anything is sent to Apple, and when Apple rejects your credentials you get told which of the three values is wrong rather than a raw error code.

**One click from IPA to installed app.** The Automation page runs the full sequence: pick an app, create or reuse a provisioning profile, replace the icon, sign, install. Re-signing after a certificate renewal is the same one click — no setup to redo. There is a `--workflow` command-line mode for scripting it.

**The signing options you actually reach for.** Rename the app, rewrite its bundle identifier, replace the icon, inject tweaks and dylibs, toggle Info.plist capabilities, strip URL schemes.

**App sources.** Browse AltStore-style catalogs and APT repositories, download apps, and keep every signed result for reinstalling later.

**Credentials handled properly.** p12 passwords go in your keychain, not a config file — a stolen `cert.p12` is useless without one. Data directories are owner-only. Exporting your configuration warns you first that the file contains your API private key in plain text.

FeatherMac is signed with a Developer ID certificate and notarized by Apple, so it opens by double-clicking. Chinese and English throughout.

### Requirements

- macOS 14 or later
- A paid Apple Developer Program account
- `libimobiledevice` / `ideviceinstaller` to install to a device (`brew install libimobiledevice ideviceinstaller`)

### Not included

- Free Apple ID signing (the 7-day kind) — the App Store Connect API is not available to free accounts
- Distribution certificates and App Store submission
- Wireless install; the device connects over USB

## 中文

在一个 Mac 原生应用里完成 iOS 应用签名与安装，不用打开 Xcode。

### 这是什么

如果你有付费的 Apple 开发者账号，又常给自己的 iPhone 侧载应用，大概熟悉这套流程：开 Xcode 建证书，去开发者后台建 Bundle ID，注册设备，下载描述文件，找个签名工具，再找个安装工具。六个地方，彼此不通气。

FeatherMac 把整条链收进一个窗口。导入 IPA，它会创建证书、注册设备、生成描述文件、签名、安装——每一步都摆在你眼前。

**这个软件是给已经付费加入 Apple Developer Program 的人用的。** 证书通过苹果的 App Store Connect API 申请，而免费账号（Personal Team）用不了这个接口。如果你想找的是用免费 Apple ID 做 7 天签名，这不是那类工具。

### 为什么会有它

2026 年 7 月 15 日，一张签名证书过期，一套本来跑得好好的流程当场全线瘫痪。续期意味着重开 Xcode、进后台、重新导出 `.p12`、再导入、重建描述文件——为了一件完全可预期的事，在五个界面之间点掉一个下午。

FeatherMac 就是为了让这件事不再花掉一个下午。证书的申请、续期、吊销都在应用内完成。它会在证书过期前给出警告，并告诉你本机这张证书在苹果账号里是否还在——让问题在还是"警告"的时候被发现，而不是等签名断了才知道。

### 它能给你什么

**不用 Xcode 也能搞定证书。** 在应用里直接申请 iOS 开发证书，私钥在本机生成、全程不出本机，上传的只有证书请求。撞上苹果的证书数量上限时，它会列出你已有的证书，让你确认吊销一张后继续。证书过期则是一键续期。

**能提前拦住错误的配置向导。** 连接苹果账号只需四步。Key ID 从 `AuthKey_*.p8` 文件名自动读出，文件在发给苹果之前先本地校验；苹果拒绝你的凭据时，它会告诉你三项里哪一项不对，而不是甩一个原始错误码。

**从 IPA 到装进手机，一次点击。** "自动配置"页把整套流程跑完：选应用、创建或复用描述文件、替换图标、签名、安装。证书续期之后重签也还是这一次点击，不用重做任何配置。另有 `--workflow` 命令行模式便于脚本化。

**真正会用到的签名选项。** 改应用名、改 Bundle ID、换图标、注入插件与 dylib、开关 Info.plist 能力、移除 URL Scheme。

**软件源。** 浏览 AltStore 风格的源目录与 APT 仓库，下载应用，每次签名的产物都留着，随时可重装。

**凭据存放得当。** p12 密码存进钥匙串而非配置文件——别人拿到 `cert.p12` 没有密码也打不开。数据目录仅本人可读。导出配置前会先提示：文件里以明文内嵌着你的 API 私钥。

FeatherMac 已用 Developer ID 证书签名并通过苹果公证，下载后双击即可打开。全程中英双语。

### 环境要求

- macOS 14 或更高版本
- 付费的 Apple Developer Program 账号
- 安装到设备需要 `libimobiledevice` / `ideviceinstaller`（`brew install libimobiledevice ideviceinstaller`）

### 不包含

- 免费 Apple ID 签名（7 天那种）——App Store Connect API 不对免费账号开放
- 发布（Distribution）证书与上架 App Store
- 无线安装，设备需通过 USB 连接
