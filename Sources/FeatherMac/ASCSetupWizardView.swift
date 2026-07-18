import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

/// 功能 A：ASC API 配置向导。
///
/// 苹果没有任何创建 API 密钥的端点，只能在网页上操作，所以这里做的是"引导式向导"——
/// 应用负责指路、自动填、校验兜底，用户在浏览器里点两下。
struct ASCSetupWizardView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    enum Step: Int, CaseIterable {
        case prerequisites, generate, importKey, verify

        var title: String {
            switch self {
            case .prerequisites: "Prerequisites"
            case .generate: "Generate Key"
            case .importKey: "Import .p8"
            case .verify: "Verify"
            }
        }
    }

    private static let portalURL = URL(string: "https://appstoreconnect.apple.com/access/integrations/api")!

    @State private var step: Step = .prerequisites
    @State private var keyPath = ""
    @State private var keyID = ""
    @State private var issuerID = ""
    @State private var keyFormatError: String?
    @State private var keyFormatValid = false
    /// Key ID 是否真的是从文件名解析出来的——只有这样才配显示"已从文件名自动识别"。
    /// 预填已有配置时它来自设置，不是文件名。
    @State private var keyIDFromFilename = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepIndicator(current: step)
            Divider()
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 560, height: 430)
        .onAppear(perform: seedFromExistingSettings)
    }

    // MARK: 各步内容

    @ViewBuilder
    private var content: some View {
        switch step {
        case .prerequisites: prerequisitesStep
        case .generate: generateStep
        case .importKey: importStep
        case .verify: verifyStep
        }
    }

    private var prerequisitesStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("Before you start, confirm two things"))
                .font(.headline)
            // 免费账号是唯一一个走到最后才会失败、且用户完全无法自救的分支，提前说清楚。
            RequirementRow(
                title: "A paid Apple Developer Program account",
                detail: "Free accounts (Personal Team) have no Integrations section on the Apple website and cannot use this feature."
            )
            RequirementRow(
                title: "Your role is Account Holder or Admin",
                detail: "Other roles cannot see the key generation button. Ask a team admin to do this step."
            )
            Callout(
                systemImage: "lock.shield",
                text: "Your private key stays on this Mac. FeatherMac never uploads the .p8 file and never asks for your Apple ID password.",
                tint: .blue
            )
        }
    }

    private var generateStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("Complete these three steps in your browser"))
                .font(.headline)
            // 整句翻译，不做 Text 片段拼接——中文语序与英文不同，拼接会译出病句。
            VStack(alignment: .leading, spacing: 10) {
                NumberedInstruction(number: 1) {
                    Text(L10n.string("Click “Generate API Key”. Any name works. Set access to App Manager or higher."))
                }
                NumberedInstruction(number: 2) {
                    Text(L10n.string("Download the AuthKey_XXXXXXXXXX.p8 file and save it somewhere it will not be cleaned up."))
                }
                NumberedInstruction(number: 3) {
                    Text(L10n.string("Copy the Issuer ID from the top of the page. You will paste it in the next step."))
                }
            }
            // 全稿唯一一处红色正文：这是流程里唯一不可逆、忽略了就得重新生成密钥的提示。
            Callout(
                systemImage: "exclamationmark.triangle",
                text: "You can only download the .p8 once. Apple will not let you download it again.",
                tint: .red
            )
            HStack {
                Button {
                    NSWorkspace.shared.open(Self.portalURL)
                } label: {
                    Label(L10n.string("Open App Store Connect"), systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)
                Text(Self.portalURL.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var importStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.string("Key file")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(keyPath.isEmpty ? L10n.string("No file selected") : (keyPath as NSString).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(keyPath.isEmpty ? .secondary : .primary)
                    Spacer()
                    Button(L10n.string("Choose…"), action: chooseKey)
                }
                .padding(7)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(L10n.string("Key ID")).font(.caption).foregroundStyle(.secondary)
                    if keyIDFromFilename && !keyID.isEmpty {
                        Text(L10n.string("Detected from the file name"))
                            .font(.caption).foregroundStyle(.green)
                    }
                }
                TextField("", text: $keyID).textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(L10n.string("Issuer ID")).font(.caption).foregroundStyle(.secondary)
                    // API 反查不到 Issuer ID，这是唯一必须手输的东西。
                    Text(L10n.string("Copy it from the top of the web page"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField("", text: $issuerID).textFieldStyle(.roundedBorder)
            }

            if let keyFormatError {
                Callout(systemImage: "xmark.circle", text: keyFormatError, tint: .red)
            } else if keyFormatValid {
                Callout(
                    systemImage: "checkmark.circle",
                    text: "File format is valid: a PEM-encoded EC P-256 private key.",
                    tint: .green
                )
            }
        }
    }

    private var verifyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch store.credentialState {
            case .ready:
                Callout(
                    systemImage: "checkmark.circle",
                    text: successMessage,
                    tint: .green
                )
            case .invalid(let message):
                Callout(systemImage: "xmark.circle", text: message, tint: .red)
            default:
                if store.isBusy {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(L10n.string("Verifying with Apple…"))
                    }
                } else {
                    Text(L10n.string("Ready to verify your credentials with Apple."))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var successMessage: String {
        // 拿不到团队 ID 就不显示，不编一个出来。
        guard let team = store.credentialTeamIdentifier else {
            return L10n.string("Connected. Your account is ready to create certificates.")
        }
        return L10n.format("Connected to team %@. Your account is ready to create certificates.", team)
    }

    // MARK: 底部按钮

    private var footer: some View {
        HStack {
            Button(L10n.string("Cancel")) { dismiss() }
            Spacer()
            if step != .prerequisites {
                Button(L10n.string("Back")) { goBack() }
            }
            primaryButton
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case .prerequisites:
            Button(L10n.string("Next")) { step = .generate }
                .buttonStyle(.borderedProminent)
        case .generate:
            Button(L10n.string("I downloaded the .p8")) { step = .importKey }
                .buttonStyle(.borderedProminent)
        case .importKey:
            Button(L10n.string("Verify and Save")) { Task { await verify() } }
                .buttonStyle(.borderedProminent)
                .disabled(!canVerify)
        case .verify:
            if case .ready = store.credentialState {
                Button(L10n.string("Done")) { dismiss() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(L10n.string("Retry")) { Task { await verify() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isBusy)
            }
        }
    }

    private var canVerify: Bool {
        keyFormatValid && !keyID.trimmed.isEmpty && !issuerID.trimmed.isEmpty
    }

    private func goBack() {
        // 校验失败后退回导入步，方便就地改；其他情况按顺序退一步。
        step = step == .verify ? .importKey : (Step(rawValue: step.rawValue - 1) ?? .prerequisites)
    }

    // MARK: 行为

    private func seedFromExistingSettings() {
        // 从自动配置页选了文件但凭据不全被转过来的，直接落到导入步，别让用户重走前两步。
        if let pending = store.pendingKeyImportPath {
            store.pendingKeyImportPath = nil
            keyPath = pending
            issuerID = store.appStoreConnect.activeKey?.issuerID ?? ""
            validateKeyFile(at: URL(fileURLWithPath: pending), extractKeyID: true)
            step = .importKey
            return
        }
        // 已经配过的，预填当前这把，方便改 Issuer ID 后重新校验。
        if keyPath.isEmpty, let active = store.appStoreConnect.activeKey {
            keyPath = active.privateKeyPath
            keyID = active.keyID
            issuerID = active.issuerID
            validateKeyFile(at: active.privateKeyURL, extractKeyID: false)
        }
    }

    private func chooseKey() {
        guard let type = UTType(filenameExtension: "p8"),
              let url = FilePicker.open(types: [type]) else { return }
        keyPath = url.path
        validateKeyFile(at: url, extractKeyID: true)
    }

    /// 选完文件立刻做本地格式校验，不合格当场报错并禁用主按钮，不等到联网那一步。
    private func validateKeyFile(at url: URL, extractKeyID: Bool) {
        keyFormatValid = false
        keyFormatError = nil
        do {
            let pem = try String(contentsOf: url, encoding: .utf8)
            // 与运行时签 JWT 用的是同一个解析器，这里能过后面就不会因为密钥格式失败。
            _ = try P256.Signing.PrivateKey(pemRepresentation: pem)
            keyFormatValid = true
        } catch {
            keyFormatError = L10n.string("This file is not a PEM-encoded EC P-256 private key. Make sure you picked the AuthKey_*.p8 downloaded from App Store Connect.")
            return
        }
        // 文件名形如 AuthKey_2X9KJ4L8QP.p8，从中提取 Key ID 省去手输；用户改过文件名时字段仍可编辑。
        if extractKeyID {
            let name = url.deletingPathExtension().lastPathComponent
            if name.hasPrefix("AuthKey_") {
                keyID = String(name.dropFirst("AuthKey_".count))
                keyIDFromFilename = true
            } else {
                keyIDFromFilename = false
            }
        }
    }

    private func verify() async {
        step = .verify
        do {
            // 导入与托管统一走 AppStore.importASCKey，向导不再自己搬文件。
            try store.importASCKey(
                from: URL(fileURLWithPath: keyPath),
                issuerID: issuerID,
                keyID: keyID
            )
        } catch {
            store.log(.error, error.localizedDescription)
            return
        }
        // 团队 ID 由 validateASCCredentials 统一写回记录，这里不再重复。
        if await store.validateASCCredentials() {
            store.pruneOrphanedASCKeys()
            await store.refreshPortalStatus()
        }
    }
}

// MARK: - 向导内的小部件

private struct StepIndicator: View {
    var current: ASCSetupWizardView.Step

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(ASCSetupWizardView.Step.allCases.enumerated()), id: \.element.rawValue) { index, step in
                HStack(spacing: 6) {
                    marker(for: step, index: index)
                    Text(L10n.string(step.title))
                        .font(.caption)
                        .fontWeight(step == current ? .semibold : .regular)
                        .foregroundStyle(step == current ? .primary : .secondary)
                }
                if index < ASCSetupWizardView.Step.allCases.count - 1 {
                    Rectangle()
                        .fill(.quaternary)
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 8)
                }
            }
        }
    }

    @ViewBuilder
    private func marker(for step: ASCSetupWizardView.Step, index: Int) -> some View {
        let isDone = step.rawValue < current.rawValue
        ZStack {
            Circle()
                .fill(step == current ? Color.accentColor : (isDone ? Color.green.opacity(0.18) : Color.clear))
                .overlay(Circle().strokeBorder(.quaternary, lineWidth: step == current ? 0 : 1))
                .frame(width: 20, height: 20)
            if isDone {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
            } else {
                Text("\(index + 1)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(step == current ? .white : .secondary)
            }
        }
    }
}

private struct RequirementRow: View {
    var title: String
    var detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string(title)).fontWeight(.medium)
                Text(L10n.string(detail)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct NumberedInstruction<Content: View>: View {
    var number: Int
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(number).")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Color.accentColor)
            content.fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct Callout: View {
    var systemImage: String
    var text: String
    var tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(L10n.string(text))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}
