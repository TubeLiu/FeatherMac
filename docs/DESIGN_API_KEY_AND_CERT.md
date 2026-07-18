# 设计稿：ASC API 开通向导 & 应用内申请 P12 证书

状态：待批准（批准后实施）
日期：2026-07-18

## 1. 背景与目标

当前 FeatherMac 的自动签名链路依赖两样手工准备的材料：

1. **App Store Connect API 凭据**（Issuer ID + Key ID + AuthKey_*.p8）：目前只能用户自己去苹果网页后台开通、下载，再手动填到应用里。步骤多、易填错、无校验。
2. **签名证书（.p12）**：目前只能用户在 Xcode / 钥匙串里创建、导出，再导入应用。2026-07-18 的实际故障（证书 7 月 15 日过期后签名全链路瘫痪）证明这个环节需要一个应用内的一键续期/新建能力。

目标：把这两件事做成应用功能，让用户在应用内完成从"零凭据"到"可签名"的全过程。

## 2. 官方能力边界（关键事实，先讲清楚）

| 事项 | 能否程序化 | 依据 |
|---|---|---|
| 创建 ASC API Key（拿 .p8） | **官方 API 不支持**，只能在 appstoreconnect.apple.com 网页操作 | ASC API 无任何创建 API Key 的端点；网页入口为 用户和访问 → 集成 → App Store Connect API |
| 校验 API Key 是否可用 | 可以 | 任意一次 API 调用（如 `GET /v1/certificates?limit=1`）即可验证 JWT 是否被接受 |
| 创建开发证书（CSR → 证书） | **可以** | `POST /v1/certificates`（`certificateType=IOS_DEVELOPMENT`），2026-07-18 已用同一账号实测 201 成功 |
| 吊销证书 | 可以 | `DELETE /v1/certificates/{id}` |
| 创建/查询 Bundle ID、描述文件、注册设备 | 可以（应用已实现） | 现有 `AppleDeveloperService` |
| 免费（Personal Team）账号使用 ASC API | **不行** | ASC API 仅对付费 Apple Developer Program 账号开放；免费账号无"集成"入口 |

由此得出两个功能的形态：

- **功能 A（.p8 获取）**：无法做到一键全自动，只能做"引导式向导"——应用负责指路、减负、校验，用户在苹果网页上点一次"生成"并下载。
- **功能 B（申请证书）**：可以一键全自动（生成密钥/CSR → 调 API → 下载证书 → 打包 p12 → 导入）。

## 3. 功能 A：ASC API 配置向导（半自动）

### 3.1 状态机

```
未配置 ──> 向导引导（打开网页）──> 待校验 ──在线校验──> 已配置可用
   ^                                  │ 失败（401/403/格式错误）
   └────────────── 错误提示并引导修正 <─┘
```

状态由现有 `AppStoreConnectSettings`（issuerID/keyID/privateKeyPath）推导，不新增持久化字段；校验结果只作为界面状态展示。

### 3.2 界面与流程

入口：自动配置页"App Store Connect API"区块 + 证书页顶部横幅（未配置/校验失败时出现）。

向导分 4 步（应用内一个 Sheet）：

1. **前提检查**：说明需要付费开发者账号 + Account Holder/Admin 角色；检测到免费账号特征时给出明确提示。
2. **打开苹果后台**：一键 `NSWorkspace.open` 到 `https://appstoreconnect.apple.com/access/integrations/api`，并给出网页上的操作指引（"生成 API 密钥"→ 下载 .p8，注意只能下载一次）。
3. **导入 .p8**：文件选择器选 `AuthKey_XXXXXXXXXX.p8`。
   - **自动解析 Key ID**：从文件名 `AuthKey_<KeyID>.p8` 提取，免去手输。
   - **本地校验 .p8 格式**：必须是 PEM 封装的 EC P-256 私钥，不对就报错并阻止下一步。
   - Issuer ID 仍需从网页复制粘贴（API 无法反查，界面上给出它在网页中的位置说明）。
4. **在线校验**：用填好的三项生成 JWT 调 `GET /v1/certificates?limit=1`：
   - 200 → 显示"配置成功"，写回 `AppStoreConnectSettings` 并保存；
   - 401 → 提示 Issuer ID / Key ID 填错或 .p8 不对应；
   - 403 → 提示角色权限不足或 API 功能未开通；
   - 其他错误原样展示。

校验逻辑复用现有 `AppStoreConnectClient`（其 init 已会生成一次 JWT，天然暴露签名/读取错误）。

### 3.3 明确不做：全自动开通（非官方私有接口）

理论上可用 Apple ID + 双重认证模拟网页会话走未公开接口创建 Key（fastlane/spaceship 路线）。不做，原因：

- 私有接口无契约，随时失效，维护成本高；
- 必须经手用户 Apple ID 密码与二次验证码，安全与合规风险大；
- 对一次性操作收益极低，向导方案已把用户操作压缩到"网页上点两下"。

## 4. 功能 B：一键申请开发证书（全自动）

### 4.1 业务流程

```
点击"创建证书"
  → 前置检查：ASC API 已配置且在线校验通过（否则跳功能 A 向导）
  → 选择证书类型（默认 iOS Development；备选 Apple Development）
  → 本地生成 RSA 2048 私钥 + CSR（subject 仅需 CN=用户昵称/C=CN，苹果签发时会改写）
  → POST /v1/certificates { certificateType, csrContent }
       ├─ 201 → 取 certificateContent（Base64 DER）
       ├─ 409（该类型证书数量达上限）→ 列出现有证书 → 用户确认后吊销（DELETE）→ 重试
       └─ 其他错误 → 分类提示
  → 下载 DER → 与本地私钥打包成 p12（用户设置密码；默认自动生成强密码并仅显示一次）
  → 写入证书目录，按现有 CertificateService.importCertificate 的元数据解析流程登记
  → 追加到证书列表，可选"设为默认"，活动日志输出结果
```

私钥全程不出本机，只有 CSR（公钥）上传。临时密钥/CSR/DER 文件用完即删。

### 4.2 界面

- 证书页"导入证书"区下方新增"创建证书"区块：证书类型 Picker、p12 密码输入（带"自动生成"按钮）、创建按钮。
- 证书详情区补充该证书与门户的对应状态（本地序列号是否仍存在于 ASC 列表，过期/被吊销时给出"一键续期"入口——续期即再走一遍创建流程）。
- 409 吊销流程弹确认框：列出将吊销的证书（类型/序列号/过期时间），明确"仅影响开发证书，不影响已安装应用"。Distribution 类证书不提供吊销入口。

### 4.3 错误分类

| 场景 | 处理 |
|---|---|
| ASC API 未配置/校验失败 | 引导去功能 A 向导 |
| 401/403 | Key 失效或角色不足，提示重新配置 |
| 409 数量上限 | 进入吊销重建流程 |
| CSR/密钥生成失败 | 本地错误，提示重试（基本不会发生） |
| p12 打包失败 | 保留已创建证书的提示（门户已存在，可在网页下载后手动导入） |
| 网络错误 | 原样展示 + 重试按钮 |

### 4.4 证书类型范围

v1 只做开发签名需要的两类：`IOS_DEVELOPMENT`（iOS Development，默认）与 `DEVELOPMENT`（Apple Development）。Distribution 证书涉及发布，风险高，v1 不做。

## 5. 技术方案

### 5.1 密钥/CSR/p12 的实现路径

两个候选：

1. **`/usr/bin/openssl` + `ProcessRunner`（推荐）**：macOS 自带，三条命令完成（`req -new -newkey rsa:2048`、`pkcs12 -export`）。与现有 `CertificateService.p12Metadata` 的做法完全一致，2026-07-18 已在本机实测走通全流程。零新增依赖、改动最小。
2. 打包的 OpenSSL.framework（Zsign 已链）写 C 桥接：更自包含，但要写 C/Swift 互操作代码，维护成本更高。

推荐方案 1；若未来要去掉系统依赖，再替换为方案 2，接口不变。

### 5.2 API 客户端扩展（`AppStoreConnectClient`）

- `create(path:body:)` 直接复用，新增 `POST certificates` 的调用封装；
- 新增 `delete(path:id:)`（DELETE 方法，204 视为成功）；
- `ASCResource` 增加 `certificateType`、`certificateContent` 字段解析。

### 5.3 服务层

`AppleDeveloperService` 新增：

- `validateCredentials(settings:) async throws`：供功能 A 校验步骤调用，返回团队摘要；
- `createDevelopmentCertificate(type:commonName:)`：生成 CSR + 提交 + 解析返回（DER、序列号、过期时间）；
- `revokeCertificate(id:)`；
- `listCertificates(type:)`：供 409 流程与"门户状态"展示。

`CertificateService` 新增 `createCSR(commonName:)` 与 `packageP12(key:certDER:password:)`，均基于 `ProcessRunner` 调 `/usr/bin/openssl`。

### 5.4 数据模型

- `CertificateRecord` 不改动（创建结果走现有字段）；
- `AppStoreConnectSettings` 不改动；
- 向导中间状态（步骤、草稿）用 `@State`/`@Published` 即可，不持久化。

### 5.5 顺带修复（来自 2026-07-18 故障排查的实证）

`matchingCertificate` 目前只过滤 `IOS_DEVELOPMENT`，Xcode 生成的"Apple Development"证书类型是 `DEVELOPMENT`，会误判"无匹配证书"。过滤条件扩展为 `IOS_DEVELOPMENT,DEVELOPMENT`（API 支持逗号多值）。

### 5.6 本地化

新增字符串同步进 `en.lproj` / `zh-Hans.lproj`（沿用现有 L10n.key 模式），向导步骤说明以中文为准翻译英文。

## 6. 代码改动清单

| 位置 | 改动 |
|---|---|
| `FeatherMacApp.swift` - `CertificatesView` | 新增"创建证书"区块、门户状态行、续期入口、吊销确认弹窗 |
| 同上 - `AutomationView` ASC 区块 | 新增"配置向导"按钮与状态徽章 |
| 同上 - 新增 `ASCSetupWizardView` | 功能 A 的 4 步向导 Sheet |
| 同上 - `AppleDeveloperService` | 校验/建证书/吊销/列证书接口 |
| 同上 - `AppStoreConnectClient` | DELETE 支持、证书字段解析 |
| 同上 - `CertificateService` | CSR 生成、p12 打包 |
| 同上 - `AppStore` | 向导与建证书的编排方法（`runBusy` 模式复用） |
| 同上 - `matchingCertificate` | 过滤类型扩展（5.5） |
| 同上 - `FeatherStorage.prepare()/save()` | 存储目录改 0700、JSON 文件改 0600（见 8.1） |
| 同上 - 导出/iCloud 同步入口 | 导出前明确提示"文件含 ASC 私钥"；iCloud 同步加同等警告 |
| `Resources/*.lproj/Localizable.strings` | 新增词条 |

不新增第三方依赖，不动 Zsign。

## 6bis. 功能 C：.p8 密钥管理（2026-07-18 追加，已批准）

原设计只解决了"怎么拿到 .p8"，没管它的生命周期。补齐后：

**修掉的两个缺陷**

1. **两条导入路径行为不一致**：向导会把 .p8 复制进应用目录，自动配置页的"选择 .p8"只记路径。用户从"下载"选完再清理下载，应用会在签 JWT 时才炸。现统一走 `AppStore.importASCKey`：一律复制进 `AppStoreConnect/`（0600），之后只认托管副本。
2. **孤儿私钥堆积**：换密钥后旧文件永远留在目录里没人删。新增 `pruneOrphanedASCKeys()`，启动时清理没有任何记录引用的 .p8。

**数据模型**

`AppStoreConnectSettings` 从"三项平铺的单份配置"改为 `keys: [ASCKeyRecord]` + `selectedKeyID`，支持多账号切换。`ASCKeyRecord` 含 issuerID / keyID / 托管路径 / 校验后缓存的 teamIdentifier。旧格式通过自定义 `init(from:)` 迁移成列表首项，并在启动时按新格式写回一次（否则每次启动都给迁移记录现分配 UUID）。对外保留 `issuerID`/`keyID`/`privateKeyPath` 三个**只读**计算属性，客户端签 JWT、服务层校验、导出配置的读取点全部不用改。

**界面**

自动配置页的 Issuer ID / Key ID 自由输入框撤掉——它们属于某一把密钥，手改只会让文件名与内容对不上。改为"API 密钥"列表：单选切换、状态徽章、`添加密钥…`（走向导）、`在访达中显示`、`从 FeatherMac 移除…`。

**移除的文案是重点**：移除只删应用保存的副本，**不等于在苹果后台吊销**，那把密钥在别处照样能用。这与证书的"吊销"是两回事，弹窗里写明了，否则用户会以为点完就作废了。

## 7bis. 实测结果（2026-07-18 实施后）

已构建、打包、替换 `/Applications/FeatherMac.app` 并启动，无崩溃。

**已验证**

| 项 | 方法 | 结果 |
|---|---|---|
| CSR → p12 全链路 | 按代码里的 openssl 参数逐条复现 | 通过；**发现并修掉一个会导致签名全线失败的 bug**，见下 |
| p12 跨实现可读性 | LibreSSL 与 OpenSSL 3.6.2 双向读取 | 双方均可读 |
| .p8 格式校验 | 真实 AuthKey / RSA 私钥 / 乱码三组输入 | 真 key 通过，另两者正确拒绝 |
| Key ID 文件名提取 | `AuthKey_XXX.p8` 与改名文件 | 提取正确，改名时留空待手填 |
| 在线校验（功能 A 第 4 步） | 真实账号 `GET /v1/certificates` | HTTP 200 |
| 新增字段解析 | 真实响应 | `certificateType` / `serialNumber` / `expirationDate`（含小数秒）/ `certificateContent` 均正确 |
| 团队标识 | 真实账号 `GET /v1/bundleIds` | `seedId=7P995MTR9S`；**修掉一处会显示垃圾字符串的设计缺陷**，见下 |
| 权限迁移 | 真实数据目录 | 根目录/证书目录/AppStoreConnect 目录 0700，全部 JSON 与 .p8/.p12 0600 |
| 多密钥迁移 | 用户真实的旧格式 `appstoreconnect.json` + 空配置 + 三项为空 + 悬空 selectedKeyID 四组 | 全部正确；真实配置迁移后 issuer/keyID/路径/前缀无损，用迁移后的配置再调 API 仍 200 |
| 孤儿密钥清理 | 放一个无人引用的假 .p8 后重启 | 孤儿被清理，真实密钥保留 |

**实测中发现并修正的两个问题**

1. **p12 加密算法不兼容（会导致签名全线失败）**：macOS 自带的是 LibreSSL，`pkcs12 -export` 默认用 `pbeWithSHA1And40BitRC2-CBC`；而 Zsign 链接的 OpenSSL 3 默认不加载 legacy provider，读这种 p12 会直接报 `unsupported algorithm RC2-40-CBC`。即：按原方案生成的证书**每一张都签不了名**。已显式指定 `-keypbe AES-256-CBC -certpbe AES-256-CBC -macalg sha256`，两种实现均可读。
2. **团队名是猜出来的**：原实现从证书名按冒号切后半段当团队名。实测该账号的证书叫 `iOS Development: Created via API`，切出来是 `Created via API`——界面会显示"已连接到 Created via API"。改为取 `bundleIds` 的 `seedId`（真正的团队 ID），取不到就不显示，不编。

另外自查修正了三处：待校验状态下创建证书会先校验（避免生成 CSR 后才冒出 401）；"一键续期"沿用旧证书类型而非当前 Picker 选中项；凭据改动后作废旧的校验结论（按指纹比对，避免向导保存后被 onChange 打回"待校验"）。

**界面实测（补做，2026-07-18 晚）**

开了辅助功能权限后改用 AppleScript 驱动真机界面（computer-use 的点击门禁另有问题，对任意坐标都误判为程序坞，未用）。逐项走查：

| 界面 | 结果 |
|---|---|
| 证书页整体 | 正常。凭据可用时横幅正确隐藏，"创建证书"按钮可点 |
| 详情区新增行 | 序列号 `389BBEE6…`、门户状态 **与账号一致**——与线上账号里那张证书的序列号一致，门户比对链路通 |
| "自动生成"密码 | 生成 `vD4q-3d7d-PjNQ-RjdH`，四组四位格式正确 |
| 自动配置页 API 密钥列表 | 单选、状态徽章、Issuer 前缀、⋯ 菜单、添加/校验按钮均正常 |
| 向导第 1–3 步 | 中文文案、步骤条勾选、格式校验绿条、预填全部正确 |
| **向导第 4 步（成功）** | **已连接到团队 `7P995MTR9S`**——与线上 `bundleIds.seedId` 一致，团队 ID 修正生效 |
| **向导第 4 步（401）** | 故意填错 Issuer ID：红条显示"凭据被拒绝（401）…"，主按钮变"重试"，密钥列表徽章同步变"失效"，日志记红。改回正确值后恢复"可用" |
| 密钥去重 | 反复导入同一把 key，记录数始终为 1 |

实测中又修了一处：向导预填已有配置时，Key ID 旁边仍显示"已从文件名自动识别"，但那个值来自设置而非文件名。加了 `keyIDFromFilename` 标记，只有真从文件名解析出来才显示。

测试用的错误 Issuer ID 已还原，配置与备份一致。

**端到端实测（2026-07-18 夜，真实账号 + 真机）**

用户授权后跑完整链路：吊销 → 重建证书 → 建描述文件 → 换图标 → 签名 → 安装到 iPhone。

| 环节 | 结果 |
|---|---|
| 创建证书 | 第一次点击即遇 409（账号开发证书名额已满），吊销确认框正确弹出，未过期证书**默认不勾选** |
| 吊销重建 | 吊销 `389BBEE6…`，新建 `139B0916…`；线上列表随后只剩新证书 |
| 密码展示 | 一次性 sheet 正确展示自动生成的密码（具体值不记录），文案为"会记住它"的如实版本 |
| 门户状态（反向） | 被吊销的本地旧证书详情随即变为**门户中已不存在**，吊销入口自动隐藏 |
| 新 p12 可用性 | OpenSSL 3.6.2（Zsign 所链）可读私钥与证书；subject `OU=7P995MTR9S`，issuer 为 Apple WWDR G3 |
| 建描述文件 | 通过（需先修复同名冲突，见下） |
| 换图标 | `FRIcon*.png` 三个尺寸写入，Info.plist 指向 `FRIcon`，内容为指定图标 |
| 签名 | 内嵌描述文件中的证书序列号 = `139B0916…`，即应用新建的那张；TeamIdentifier `7P995MTR9S` |
| 安装 | 设备上 `com.liuzijiao.app, "8.0.71", "Device"`，应用名保持 Device |

**端到端实测暴露并修复的两个问题**

1. **吊销证书会连带作废描述文件，且名字仍被占用**：旧证书一吊销，绑它的描述文件变成 INVALID，再建同名的会被苹果以 `Multiple profiles found with the name ...` 409 拒绝——即"吊销重建"之后必然卡在建描述文件这一步。已在 `createDevelopmentProfile` 中先清理同名旧描述文件（名字由本应用按固定规则生成，属自己的命名空间），并把清理动作写进活动日志。
2. **权限迁移把目录也设成了 0600（本次改动引入的回归）**：`hardenExistingFiles` 对证书目录下所有条目一律 chmod 600，没区分目录。`AutoProfiles` 因此丢掉执行位，描述文件写不进去，报错还很含糊（"You don't have permission to save the file…"）。已改为递归区分：目录 0700、文件 0600。

**CLI 回归（`--workflow`）**

退出码 0，无 Error 级日志，产物内嵌描述文件的证书序列号为 `139B0916…`（新证书），`FRIcon*` 三尺寸齐全，`CFBundleDisplayName` 为 `Device`，设备上 `com.liuzijiao.app "Device"` 安装成功。

注意该路径下日志为"Reused provisioning profile Device."——本地已有描述文件时走复用分支，不会重新调用建描述文件接口，因此同名清理逻辑在 CLI 这条路上未被触发（GUI 路径已验证）。

至此 §7 验收计划五项全部完成。

## 7. 验收计划

1. 向导：从空配置开始走一遍，错误路径（故意填错 Key ID）与正确路径各验一次。
2. 建证书：用真实账号创建一张 iOS Development 证书 → 苹果后台可见 → 应用证书列表出现且元数据正确（序列号与门户一致、有效期约 1 年）。
3. 409 流程：在数量满时触发一次，验证吊销重建（会先在测试 App ID 上演示，不动生产材料）。
4. 端到端回归：用新建的证书跑一次自动配置工作流（建描述文件 → 签名 → 安装到 iPhone），确认全链路无人工步骤。
5. CLI 回归：`--workflow` 模式在新证书下通过。

## 8. 风险与限制

- 功能 A 本质受苹果限制，无法免去网页上的一次点击；设计已把用户操作压到最少并全程校验兜底。
- 建证书消耗账号的证书名额（各类型有上限），吊销流程必须二次确认且仅限开发证书。
- 免费账号两个功能都不可用，界面需明确告知而不是含糊报错。
### 8.1 凭据存储现状（2026-07-18 复核，修正本节初稿的乐观描述）

初稿写的是"p12 密码明文存本地 JSON，本设计不扩大该面"。复核代码后发现现状比这更差，且有两处应在本次一并修掉：

| 实证 | 位置 | 处置 |
|---|---|---|
| `FeatherStorage.prepare()` 用默认权限建目录（0755），JSON 落盘 0644 —— **同机任何用户可读** `certificates.json` | `FeatherStorage` | **本次修**：目录 0700、文件 0600，与导出路径已有的 `chmod 0600` 对齐 |
| p12 密码与它加密的 `Certificates/<uuid>/cert.p12` 放在同一目录树，PKCS#12 加密形同虚设 | 同上 | 本次靠权限收紧缓解；根治见下 |
| 导出 `.feathermacconfig` 把 **ASC 私钥裸 PEM 写进 JSON**，且有一键同步到 **iCloud Drive** 的入口 | 约 1239 / 1264 行 | **本次修**：导出与同步前明确提示内含私钥 |

根治方案是把 p12 密码与 .p8 迁入钥匙串，但有硬前置：`scripts/package_app.sh:61` 是 `codesign --sign -`（ad-hoc），钥匙串 ACL 绑定代码签名身份，ad-hoc 的 cdhash 每次构建都变 → 每次重装弹授权；data protection keychain 需 entitlements + 正式签名，同样不适用。另外 `--workflow` 无头 CLI 模式读钥匙串会卡在弹窗上。

**结论：钥匙串迁移单独立项，前置是把 ad-hoc 换成 Developer ID 正式签名。** 本功能自动生成的强密码会让该迁移在落地时真正产生价值（攻击者拿到 p12 也打不开），但收益要等签名身份到位才兑现。在此之前，界面文案不得暗示密码"别处再也拿不到"（见 §9.2）。

## 9. 待批准决策点

1. **向导与建证书入口位置**：建议证书页为主入口、自动配置页放辅助入口（本稿按此写）。是否同意？
2. ~~**p12 密码策略**：默认"自动生成强密码 + 只显示一次"，同时允许用户自填。~~
   **已定（2026-07-18）**：自动生成强密码 + 允许自填保留；但"只显示一次"的说法作废——应用自己明文留着密码，界面不能给假的安全感。文案改为如实告知"应用会记住它，此处是唯一一次明文展示"。存储安全按 §8.1 分层处理：权限收紧与 iCloud 私钥警告本次做，钥匙串迁移另立项（前置：Developer ID 签名）。
3. **吊销重建**：是否纳入 v1（建议纳入，仅限开发证书 + 确认框）？
4. **证书类型**：v1 只做 Development 两类，不做 Distribution。是否同意？
5. **CSR 实现**：采用 `/usr/bin/openssl` 方案（5.1 推荐项）。是否同意？
