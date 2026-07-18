import Foundation
import SwiftUI

// MARK: - 凭据状态

/// ASC 凭据的四种状态，全应用统一用这一组徽章与文案。
enum ASCCredentialState: Equatable {
    /// 三项设置有缺失。
    case unconfigured
    /// 三项齐全但没有联网验证过。
    case unverified
    /// 校验返回 200。
    case ready
    /// 校验返回 401/403。
    case invalid(String)

    var title: String {
        switch self {
        case .unconfigured: "Not configured"
        case .unverified: "Not verified"
        case .ready: "Ready"
        case .invalid: "Invalid"
        }
    }

    var tint: Color {
        switch self {
        case .unconfigured: .secondary
        case .unverified: .orange
        case .ready: .green
        case .invalid: .red
        }
    }

    var canCreateCertificate: Bool {
        switch self {
        case .unconfigured, .invalid: false
        case .unverified, .ready: true
        }
    }
}

/// 创建成功后一次性展示的结果。
struct CreatedCertificateReveal: Identifiable {
    let id = UUID()
    var nickname: String
    var password: String
    var serialNumber: String?
    var expiration: Date?
    var certificateID: UUID
}

// MARK: - 编排

extension AppStore {
    var hasCompleteASCSettings: Bool {
        !appStoreConnect.issuerID.trimmed.isEmpty
            && !appStoreConnect.keyID.trimmed.isEmpty
            && !appStoreConnect.privateKeyPath.trimmed.isEmpty
    }

    /// 从设置推导状态，不新增持久化字段。已经在线校验过的结果保留。
    func refreshCredentialState() {
        guard hasCompleteASCSettings else {
            credentialState = .unconfigured
            credentialTeamIdentifier = nil
            return
        }
        if case .ready = credentialState { return }
        if case .invalid = credentialState { return }
        credentialState = .unverified
    }

    /// 当前三项凭据的指纹，用来判断校验结论是否还对得上。
    var credentialFingerprint: String {
        [appStoreConnect.issuerID.trimmed, appStoreConnect.keyID.trimmed, appStoreConnect.privateKeyPath.trimmed]
            .joined(separator: "\u{1F}")
    }

    /// 用户改了三项里的任何一项，之前的校验结论就作废了——否则界面会拿着
    /// 旧的"可用"徽章，配着一份新的错凭据。
    ///
    /// 只在指纹真的变了时才重置：向导保存凭据后紧接着就会校验，而 onChange 是
    /// 下一轮更新才触发的，不加这个判断会把刚拿到的"可用"又打回"待校验"。
    func invalidateCredentialVerification() {
        guard credentialFingerprint != verifiedCredentialFingerprint else { return }
        credentialTeamIdentifier = nil
        portalSerialNumbers = nil
        verifiedCredentialFingerprint = nil
        credentialState = hasCompleteASCSettings ? .unverified : .unconfigured
    }

    /// 功能 A 第 4 步 / 证书页"重新校验"。
    @discardableResult
    func validateASCCredentials() async -> Bool {
        guard hasCompleteASCSettings else {
            credentialState = .unconfigured
            log(.error, "Configure App Store Connect Issuer ID, Key ID, and .p8 key first.")
            return false
        }
        var succeeded = false
        await runBusy("Verifying App Store Connect credentials...") {
            do {
                let summary = try await self.developerService.validateCredentials(settings: self.appStoreConnect)
                await MainActor.run {
                    self.credentialState = .ready
                    self.credentialTeamIdentifier = summary.teamIdentifier
                    self.verifiedCredentialFingerprint = self.credentialFingerprint
                    // 不管从向导还是从"校验"按钮进来，都把团队 ID 记回密钥记录，
                    // 否则列表里永远只显示 Issuer 前缀，多账号时分不清哪把是哪个团队。
                    self.cacheTeamIdentifier(summary.teamIdentifier, for: self.appStoreConnect.activeKey?.id)
                    self.log(.success, "App Store Connect credentials verified.")
                }
                succeeded = true
            } catch {
                let message = Self.credentialErrorMessage(for: error)
                await MainActor.run {
                    self.credentialState = .invalid(message)
                    self.credentialTeamIdentifier = nil
                    // 失效的结论也绑在这份凭据上，改了才重算。
                    self.verifiedCredentialFingerprint = self.credentialFingerprint
                    self.log(.error, message)
                }
            }
        }
        return succeeded
    }

    /// 把苹果的 HTTP 状态翻译成能指导下一步的说法。未知错误原样保留。
    static func credentialErrorMessage(for error: Error) -> String {
        guard let apiError = error as? ASCAPIError else {
            return error.localizedDescription
        }
        switch apiError.status {
        case 401:
            return L10n.string("Credentials rejected (401). The Issuer ID, Key ID, and .p8 file do not match. Check them, or generate a new key on the Apple website.")
        case 403:
            return L10n.string("Insufficient permissions (403). This key's role cannot access certificates. Generate a new key as Account Holder or Admin with App Manager access or higher.")
        default:
            return apiError.localizedDescription
        }
    }

    // MARK: 创建证书

    func createCertificate() async {
        guard credentialState.canCreateCertificate else {
            log(.error, "Configure App Store Connect API first.")
            showASCWizard = true
            return
        }
        // 待校验状态下先校验一次，让失败停在"凭据不对"上，而不是让用户看一个
        // 生成 CSR 之后才冒出来的 401。
        if case .unverified = credentialState {
            guard await validateASCCredentials() else { return }
        }
        let password = newCertificatePasswordDraft.trimmed.nonEmpty ?? CertificateService.generatePassword()
        // 苹果签发时会重写 subject，CSR 里的 CN 只需合法，不需要有意义。
        let commonName = "FeatherMac"
        await runBusy("Creating certificate...") {
            try await self.performCreateCertificate(password: password, commonName: commonName, allowRevokeRetry: true)
        }
    }

    /// 续期就是再走一遍创建流程，但沿用旧证书的类型——用户点"一键续期"时
    /// 想要的是同一种证书，不是当前 Picker 里碰巧选中的那种。
    func renewCertificate(_ certificate: CertificateRecord) async {
        if let type = inferredType(for: certificate) {
            newCertificateType = type
        }
        newCertificatePasswordDraft = ""
        await createCertificate()
    }

    /// 本地记录里没存证书类型，从昵称反推：Xcode 的叫 "Apple Development: ..."。
    private func inferredType(for certificate: CertificateRecord) -> DeveloperCertificateType? {
        let name = certificate.nickname.lowercased()
        if name.contains("apple development") { return .development }
        if name.contains("ios development") || name.contains("iphone developer") { return .iosDevelopment }
        return nil
    }

    private func performCreateCertificate(password: String, commonName: String, allowRevokeRetry: Bool) async throws {
        let csr = try CertificateService.createCSR(commonName: commonName)
        let type = newCertificateType
        let created: CreatedCertificate
        do {
            created = try await developerService.createCertificate(
                type: type,
                csrPEM: csr.csrPEM,
                settings: appStoreConnect
            )
        } catch let apiError as ASCAPIError where apiError.status == 409 && allowRevokeRetry {
            // 数量达上限：列出现有开发证书，让用户确认吊销哪些，然后重试一次。
            guard try await confirmRevokeAndRetry() else {
                throw FeatherError.message(L10n.string("Certificate creation cancelled."))
            }
            try await performCreateCertificate(password: password, commonName: commonName, allowRevokeRetry: false)
            return
        }

        let p12URL = try CertificateService.packageP12(
            privateKeyPEM: csr.privateKeyPEM,
            certificateDER: created.der,
            password: password
        )
        defer { try? FileManager.default.removeItem(at: p12URL.deletingLastPathComponent()) }

        let record = try CertificateService.importCertificate(p12: p12URL, password: password, storage: storage)
        await MainActor.run {
            var stored = record
            if self.certificates.isEmpty {
                stored.isDefault = true
            }
            self.certificates.insert(stored, at: 0)
            self.selectedCertID = stored.id
            self.newCertificatePasswordDraft = ""
            self.saveAll()
            self.createdCertificateReveal = CreatedCertificateReveal(
                nickname: stored.nickname,
                password: password,
                serialNumber: stored.p12SerialNumber,
                expiration: stored.expiration,
                certificateID: stored.id
            )
            self.log(.success, "Created certificate \(stored.nickname).")
        }
        await refreshPortalStatus()
    }

    /// 409 流程：拉门户证书列表 → 弹确认框 → 吊销选中的。
    private func confirmRevokeAndRetry() async throws -> Bool {
        let portal = try await developerService.listCertificates(settings: appStoreConnect)
        guard !portal.isEmpty else { return false }
        let toRevoke = await MainActor.run { RevokeSelectionPrompt.present(certificates: portal) }
        guard !toRevoke.isEmpty else { return false }
        for certificate in toRevoke {
            try await developerService.revokeCertificate(id: certificate.id, settings: appStoreConnect)
            await MainActor.run {
                self.log(.info, "Revoked certificate \(certificate.name).")
            }
        }
        return true
    }

    /// 手动吊销门户里的某张开发证书（证书详情区入口）。
    func revokePortalCertificate(matching record: CertificateRecord) async {
        guard credentialState.canCreateCertificate else {
            log(.error, "Configure App Store Connect API first.")
            return
        }
        await runBusy("Revoking certificate...") {
            let portal = try await self.developerService.listCertificates(settings: self.appStoreConnect)
            guard let serial = record.p12SerialNumber?.uppercased(),
                  let match = portal.first(where: { $0.serialNumber == serial }) else {
                throw FeatherError.message(L10n.string("This certificate no longer exists in your account."))
            }
            let confirmed = await MainActor.run {
                Confirm.warn(
                    title: "Revoke this certificate?",
                    message: "Revoking only affects future signing: apps already installed on your device keep working, but signing again with this certificate will fail.",
                    confirmTitle: "Revoke",
                    destructive: true
                )
            }
            guard confirmed else { return }
            try await self.developerService.revokeCertificate(id: match.id, settings: self.appStoreConnect)
            await MainActor.run {
                self.log(.success, "Revoked certificate \(match.name).")
            }
            await self.refreshPortalStatus()
        }
    }

    // MARK: 门户状态

    func refreshPortalStatus() async {
        guard credentialState.canCreateCertificate else {
            portalSerialNumbers = nil
            return
        }
        do {
            let portal = try await developerService.listCertificates(settings: appStoreConnect)
            let serials = Set(portal.compactMap(\.serialNumber))
            await MainActor.run { self.portalSerialNumbers = serials }
        } catch {
            await MainActor.run { self.portalSerialNumbers = nil }
        }
    }

    /// 本地证书与门户的对应关系。nil 表示尚未校验过。
    func portalStatus(for certificate: CertificateRecord) -> Bool? {
        guard let portalSerialNumbers, let serial = certificate.p12SerialNumber?.uppercased() else {
            return nil
        }
        return portalSerialNumbers.contains(serial)
    }

    func generateNewCertificatePassword() {
        newCertificatePasswordDraft = CertificateService.generatePassword()
    }
}

// MARK: - 吊销选择弹窗

/// 409 时的吊销确认。默认勾选已过期的证书——让最安全的选择成为默认。
@MainActor
enum RevokeSelectionPrompt {
    static func present(certificates: [PortalCertificate]) -> [PortalCertificate] {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("Your account has reached Apple's development certificate limit")
        alert.informativeText = L10n.string("To continue, revoke one first. Revoking only affects future signing: apps already installed on your device keep working. Only development certificates are listed here.")

        let rowHeight: CGFloat = 42
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: rowHeight * CGFloat(certificates.count)))
        var checkboxes: [NSButton] = []
        for (index, certificate) in certificates.enumerated() {
            let checkbox = NSButton(checkboxWithTitle: title(for: certificate), target: nil, action: nil)
            checkbox.state = certificate.isExpired ? .on : .off
            checkbox.frame = NSRect(
                x: 0,
                y: container.frame.height - rowHeight * CGFloat(index + 1),
                width: container.frame.width,
                height: rowHeight
            )
            container.addSubview(checkbox)
            checkboxes.append(checkbox)
        }
        alert.accessoryView = container
        alert.addButton(withTitle: L10n.string("Revoke and Create")).hasDestructiveAction = true
        alert.addButton(withTitle: L10n.string("Cancel"))

        guard alert.runModal() == .alertFirstButtonReturn else { return [] }
        return zip(certificates, checkboxes)
            .filter { $0.1.state == .on }
            .map(\.0)
    }

    private static func title(for certificate: PortalCertificate) -> String {
        var parts = [certificate.name, certificate.type]
        if let serial = certificate.serialNumber {
            parts.append(serial)
        }
        if let expiration = certificate.expiration {
            let formatted = expiration.formatted(date: .abbreviated, time: .omitted)
            parts.append(certificate.isExpired ? "\(formatted) — \(L10n.string("expired"))" : formatted)
        }
        return parts.joined(separator: " · ")
    }
}
