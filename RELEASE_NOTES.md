# FeatherMac 1.1.0

Certificates and App Store Connect credentials can now be set up entirely inside the app.

## English

### App Store Connect API setup wizard

- Four-step guided setup: prerequisite check, opening the Apple portal, importing the `.p8`, and online verification.
- Key ID is detected automatically from the `AuthKey_*.p8` file name; the file is validated locally before anything is sent to Apple.
- Verification reports exactly what went wrong — rejected credentials (401) and insufficient permissions (403) each get their own explanation and next step.
- Free (Personal Team) accounts are identified up front rather than failing at the last step.

### Create signing certificates without Xcode

- Create an iOS Development or Apple Development certificate directly from the Certificates page. The private key is generated locally and never leaves your Mac.
- p12 passwords can be generated automatically, and are shown once on completion.
- When the account has reached Apple's certificate limit, FeatherMac lists your development certificates and offers to revoke one and retry. Already-installed apps are unaffected; only future signing is.
- Expired certificates show a warning and a one-click renewal that reuses the same certificate type.
- Certificate details now show the serial number and whether the certificate still exists in your Apple account.

### API key management

- Multiple API keys can be stored and switched between, for people working across accounts or teams.
- Key files are copied into FeatherMac's data directory with owner-only permissions, so cleaning your Downloads folder no longer breaks signing.
- Unreferenced key files are removed automatically at launch.
- Removing a key states plainly that it does **not** revoke the key on Apple's side.

### Credential storage

- Data directories are now `0700` and stored files `0600`, applied to existing installations on first launch.
- Exporting or syncing your configuration to iCloud Drive now warns that the file contains your API private key in plain text.

### Other changes

- APT repositories are now parsed alongside AltStore sources.
- Provisioning profile selection moved to the Signing page, where it is used.
- Refreshed the default source list.

### Fixes

- Certificates issued by Xcode ("Apple Development") are no longer reported as missing when creating a provisioning profile.
- Conflicting same-name provisioning profiles are removed automatically instead of failing with an Apple API error.

### Upgrading

Existing App Store Connect settings migrate automatically to the new multi-key format on first launch. No manual steps.

### Known limitations

- p12 passwords are still stored in FeatherMac's local configuration; the interface says so rather than implying otherwise. Keychain storage is planned and requires a signed build first.
- Certificate creation requires a paid Apple Developer Program account. Free accounts cannot use the App Store Connect API.

## 中文

### App Store Connect API 配置向导

- 四步引导：前提检查、打开苹果后台、导入 `.p8`、在线校验。
- Key ID 自动从 `AuthKey_*.p8` 文件名识别；文件在本地先校验格式，不合格不会发给苹果。
- 校验失败会说清是哪儿错了——凭据被拒（401）和权限不足（403）各有各的说明和下一步。
- 免费账号（Personal Team）在第一步就会被指出，不会走到最后才失败。

### 不用 Xcode 也能申请签名证书

- 在证书页直接申请 iOS Development 或 Apple Development 证书。私钥在本机生成，全程不出本机。
- p12 密码可自动生成，创建完成时展示一次。
- 账号证书名额已满时，FeatherMac 会列出你的开发证书，让你确认吊销一张后重试。已安装的 App 不受影响，只影响再次签名。
- 已过期证书会给出警告和一键续期，续期沿用原证书类型。
- 证书详情新增序列号，以及该证书在苹果账号中是否仍然存在。

### API 密钥管理

- 可保存多把密钥并切换，适合跨账号或跨团队使用。
- 密钥文件复制进 FeatherMac 数据目录并设为仅本人可读，清理"下载"文件夹不会再让签名失效。
- 启动时自动清理无人引用的密钥文件。
- 移除密钥时明确说明：这**不等于**在苹果后台吊销它。

### 凭据存储

- 数据目录改为 `0700`、文件改为 `0600`，已有安装在首次启动时自动收紧。
- 导出配置或同步到 iCloud Drive 前会提示：文件以明文内嵌你的 API 私钥。

### 其他改动

- 除 AltStore 源外，现在也支持解析 APT 仓库。
- 描述文件选择移到"签名"页——用它的地方。
- 更新了默认源列表。

### 修复

- 使用 Xcode 签发的 "Apple Development" 证书创建描述文件时，不再被误报为找不到匹配证书。
- 同名描述文件冲突时自动清理，不再直接抛出苹果 API 错误。

### 升级说明

已有的 App Store Connect 配置会在首次启动时自动迁移为新的多密钥格式，无需手动操作。

### 已知限制

- p12 密码目前仍存放在 FeatherMac 的本地配置中，界面对此如实说明，没有暗示更强的保护。钥匙串存储已列入计划，前置是先有正式签名的构建。
- 申请证书需要付费的 Apple Developer Program 账号，免费账号无法使用 App Store Connect API。

---

# FeatherMac 1.0.0

Initial public release.

## English

- Native macOS IPA library, source browser, certificate manager, signer, installer, and automation workflow.
- Chinese and English UI.
- App Store Connect API support for Bundle ID creation, connected-device registration, and development provisioning profile generation.
- CI-style automation page: select imported IPA, create or reuse profile, optionally replace icon, sign, install, and keep the signed result available for reinstall.
- iCloud Drive sync and import/export for App Store Connect configuration.
- Includes safe git ignore rules for signing keys, certificates, profiles, imported IPAs, signed IPAs, and local config.

## 中文

- 首个公开版本，包含 macOS 原生 IPA 资料库、源管理、证书管理、签名、安装和自动化工作流。
- 支持中文和英文界面。
- 支持 App Store Connect API 自动创建 Bundle ID、注册连接设备、生成开发描述文件。
- “自动配置”页面提供类似 CI/CD 的一键流程：选择已导入 IPA、创建或复用描述文件、可选替换图标、签名、安装，并保留签名产物用于重复安装。
- 支持 App Store Connect 配置导入/导出和 iCloud Drive 同步。
- 已加入安全忽略规则，避免提交私钥、证书、描述文件、导入 IPA、签名 IPA 和本地配置。
