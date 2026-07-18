import CryptoKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - .p8 密钥的生命周期

extension AppStore {
    /// 导入一把 .p8。
    ///
    /// 无论从向导还是从自动配置页进来，都走这一条路径：**把文件复制进应用数据目录**（0600），
    /// 之后只认这份托管副本。用户常把 .p8 下载到"下载"里，清理掉之后应用会在签 JWT 时
    /// 才炸出来，那时早已看不出是文件没了。
    @discardableResult
    func importASCKey(from source: URL, issuerID: String, keyID: String) throws -> ASCKeyRecord {
        let trimmedKeyID = keyID.trimmed.nonEmpty ?? "Imported"
        let directory = storage.root.appendingPathComponent("AppStoreConnect", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = directory.appendingPathComponent("AuthKey_\(trimmedKeyID).p8")

        // 同一个 Key ID 视为同一把密钥：覆盖内容并复用原记录，不产生重复条目。
        if source.standardizedFileURL != destination.standardizedFileURL {
            try FileManager.default.removeItemIfExists(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)

        var record: ASCKeyRecord
        if let index = appStoreConnect.keys.firstIndex(where: { $0.keyID == trimmedKeyID }) {
            record = appStoreConnect.keys[index]
            record.issuerID = issuerID.trimmed
            record.privateKeyPath = destination.path
            record.teamIdentifier = nil
            appStoreConnect.keys[index] = record
        } else {
            record = ASCKeyRecord(
                issuerID: issuerID.trimmed,
                keyID: trimmedKeyID,
                privateKeyPath: destination.path
            )
            appStoreConnect.keys.append(record)
        }
        appStoreConnect.selectedKeyID = record.id
        invalidateCredentialVerification()
        saveAll()
        log(.success, "Added API key \(trimmedKeyID).")
        return record
    }

    /// 自动配置页的"添加密钥"：选文件 → 从文件名取 Key ID → 校验格式 → 需要 Issuer ID 时引导走向导。
    func pickAppStoreConnectKey() {
        guard let type = UTType(filenameExtension: "p8"),
              let url = FilePicker.open(types: [type]) else { return }
        do {
            let pem = try String(contentsOf: url, encoding: .utf8)
            _ = try P256.Signing.PrivateKey(pemRepresentation: pem)
        } catch {
            log(.error, L10n.string("This file is not a PEM-encoded EC P-256 private key. Make sure you picked the AuthKey_*.p8 downloaded from App Store Connect."))
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        let detectedKeyID = name.hasPrefix("AuthKey_") ? String(name.dropFirst("AuthKey_".count)) : ""
        // Issuer ID 只能从网页复制，API 反查不到。裸选文件补不齐凭据，交给向导。
        guard let issuer = appStoreConnect.activeKey?.issuerID.nonEmpty, !detectedKeyID.isEmpty else {
            pendingKeyImportPath = url.path
            showASCWizard = true
            return
        }
        do {
            try importASCKey(from: url, issuerID: issuer, keyID: detectedKeyID)
        } catch {
            log(.error, error.localizedDescription)
        }
    }

    func selectASCKey(_ key: ASCKeyRecord) {
        guard appStoreConnect.selectedKeyID != key.id else { return }
        appStoreConnect.selectedKeyID = key.id
        // 换了密钥，上一把的校验结论和门户列表都不作数了。
        invalidateCredentialVerification()
        saveAll()
        log(.info, "Switched to API key \(key.keyID).")
        Task { await refreshPortalStatus() }
    }

    /// 从应用里移除一把密钥。**不等于在苹果后台吊销**——文案必须说清楚，
    /// 否则用户会以为点完这把 key 就作废了，实际它在门户上照样能用。
    func removeASCKey(_ key: ASCKeyRecord) {
        let confirmed = Confirm.warn(
            title: "Remove this API key from FeatherMac?",
            message: "This deletes the key file stored by FeatherMac. It does NOT revoke the key on Apple's website — it will keep working anywhere else it is used. To disable it for good, revoke it in App Store Connect.",
            confirmTitle: "Remove",
            destructive: true
        )
        guard confirmed else { return }
        try? FileManager.default.removeItem(at: key.privateKeyURL)
        appStoreConnect.keys.removeAll { $0.id == key.id }
        if appStoreConnect.selectedKeyID == key.id {
            appStoreConnect.selectedKeyID = appStoreConnect.keys.first?.id
        }
        invalidateCredentialVerification()
        saveAll()
        log(.info, "Removed API key \(key.keyID).")
    }

    func revealASCKeyInFinder(_ key: ASCKeyRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([key.privateKeyURL])
    }

    /// 校验成功后把团队 ID 记在密钥上，列表里就能区分多个账号。
    func cacheTeamIdentifier(_ teamIdentifier: String?, for keyID: UUID?) {
        guard let keyID, let index = appStoreConnect.keys.firstIndex(where: { $0.id == keyID }) else { return }
        appStoreConnect.keys[index].teamIdentifier = teamIdentifier
        saveAll()
    }

    /// 启动时清理 AppStoreConnect 目录里没有任何记录引用的 .p8。
    /// 换密钥、删记录、旧版本残留都会留下这种孤儿私钥，不清理就是无人认领的密钥堆积。
    func pruneOrphanedASCKeys() {
        let directory = storage.root.appendingPathComponent("AppStoreConnect", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        let referenced = Set(appStoreConnect.keys.map { URL(fileURLWithPath: $0.privateKeyPath).standardizedFileURL })
        for file in files where file.pathExtension.lowercased() == "p8" {
            guard !referenced.contains(file.standardizedFileURL) else { continue }
            try? FileManager.default.removeItem(at: file)
            log(.info, "Removed an unreferenced API key file: \(file.lastPathComponent)")
        }
    }
}

// MARK: - 自动配置页的密钥区块

struct ASCKeyListSection: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if store.appStoreConnect.keys.isEmpty {
                HStack {
                    Text(L10n.string("No API key added yet"))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(store.appStoreConnect.keys) { key in
                        ASCKeyRow(key: key, isActive: key.id == store.appStoreConnect.activeKey?.id)
                        if key.id != store.appStoreConnect.keys.last?.id {
                            Divider()
                        }
                    }
                }
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Button {
                    store.showASCWizard = true
                } label: {
                    Label(L10n.string("Add Key…"), systemImage: "plus")
                }
                Button(L10n.string("Verify")) {
                    Task { await store.validateASCCredentials() }
                }
                .disabled(!store.hasCompleteASCSettings || store.isBusy)
                Spacer()
                // 密钥文件由应用托管，用户需要知道它在哪、以及那不是他当初选的那个文件。
                Text(L10n.string("Key files are stored by FeatherMac with owner-only permissions."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ASCKeyRow: View {
    @EnvironmentObject private var store: AppStore
    var key: ASCKeyRecord
    var isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(key.keyID)
                        .fontWeight(.medium)
                    if isActive {
                        Text(L10n.string(store.credentialState.title))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 1)
                            .background(store.credentialState.tint.opacity(0.16), in: Capsule())
                            .foregroundStyle(store.credentialState.tint)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Menu {
                Button(L10n.string("Reveal in Finder")) { store.revealASCKeyInFinder(key) }
                Divider()
                Button(role: .destructive) {
                    store.removeASCKey(key)
                } label: {
                    Text(L10n.string("Remove from FeatherMac…"))
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { store.selectASCKey(key) }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let team = key.teamIdentifier?.nonEmpty {
            parts.append(L10n.format("Team %@", team))
        }
        if let issuer = key.issuerID.nonEmpty {
            parts.append(L10n.format("Issuer %@", String(issuer.prefix(8)) + "…"))
        }
        // 托管副本被外部删掉了，早点说，别等到签 JWT 时才炸。
        // 文档截图用的是演示路径，本来就不存在，不必显示这条。
        let capturingScreenshots = ProcessInfo.processInfo.environment["FEATHERMAC_SCREENSHOT_DIR"] != nil
        if !capturingScreenshots && !FileManager.default.fileExists(atPath: key.privateKeyPath) {
            parts.append(L10n.string("key file missing"))
        }
        return parts.joined(separator: " · ")
    }
}
