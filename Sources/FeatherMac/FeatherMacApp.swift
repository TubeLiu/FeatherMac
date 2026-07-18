import AltSourceKit
import AppKit
import CryptoKit
import Darwin
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import ZsignSwift

@main
enum FeatherMacMain {
    static func main() {
        if FeatherMacCLI.runIfRequested() {
            return
        }
        FeatherMacApp.main()
    }
}

struct FeatherMacApp: App {
    @StateObject private var store = AppStore()
    @AppStorage("FeatherMac.language") private var language = AppLanguage.system.rawValue

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .id(language)
                .frame(minWidth: 1120, minHeight: 720)
                .task {
                    await store.bootstrap()
                    await DocumentationScreenshotRunner.captureIfRequested(store: store)
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.string("Import IPA...")) {
                    Task { await store.pickAndImportIPA() }
                }
                .keyboardShortcut("i", modifiers: [.command])

                Button(L10n.string("Add Source...")) {
                    store.showAddSource = true
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
        }
    }
}

@MainActor
enum FeatherMacCLI {
    /// 命令行模式：`FeatherMac --workflow [--app-id <uuid>] [--app-name <name>] [--icon <path>] [--no-install]`
    /// 返回 true 表示已按命令行模式处理（进程会驻留到任务结束后自行退出）。
    static func runIfRequested() -> Bool {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.contains("--workflow") else { return false }

        let store = AppStore()
        Task { @MainActor in
            let code = await run(store: store, arguments: arguments)
            exit(code)
        }
        dispatchMain()
    }

    private static func run(store: AppStore, arguments: [String]) async -> Int32 {
        do {
            try store.storage.prepare()
            store.library = try store.storage.loadLibrary()
            store.certificates = try store.storage.loadCertificates()
            store.options = try store.storage.loadOptions()
            store.appStoreConnect = try store.storage.loadAppStoreConnectSettings()
            store.automation = try store.storage.loadAutomationPipeline()

            if let appID = value(after: "--app-id", in: arguments), let uuid = UUID(uuidString: appID) {
                store.automation.appID = uuid
            }
            if store.automation.appID == nil {
                store.automation.appID = store.library.first(where: { $0.kind == .imported })?.id
            }
            if store.automation.certificateID == nil {
                store.automation.certificateID = store.certificates.first(where: \.isDefault)?.id ?? store.certificates.first?.id
            }
            if let appName = value(after: "--app-name", in: arguments)?.trimmed.nonEmpty {
                store.automation.appName = appName
            }
            if let iconPath = value(after: "--icon", in: arguments)?.trimmed.nonEmpty {
                store.automation.iconPath = iconPath
            }
            if arguments.contains("--no-install") {
                store.automation.installAfterSigning = false
            }
            store.saveAll()

            print("FeatherMac CLI: running workflow...")
            await store.runAutomationPipeline()

            for entry in store.logs.reversed() {
                print("[\(entry.level.rawValue)] \(entry.message)")
            }

            let failed = store.logs.contains { $0.level == .error }
            let signed = store.automation.completedSteps.contains(.sign) && store.automation.lastSignedAppID != nil
            let installExpected = store.automation.installAfterSigning
            let installed = !installExpected || store.automation.completedSteps.contains(.install)
            if failed || !signed || !installed {
                fputs("FeatherMac CLI: workflow failed.\n", stderr)
                return 1
            }
            print("FeatherMac CLI: workflow completed.")
            return 0
        } catch {
            fputs("FeatherMac CLI error: \(error)\n", stderr)
            return 1
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

@MainActor
enum DocumentationScreenshotRunner {
    static func captureIfRequested(store: AppStore) async {
        guard let outputPath = ProcessInfo.processInfo.environment["FEATHERMAC_SCREENSHOT_DIR"] else { return }
        let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            seedDemoState(store: store)
            try await Task.sleep(nanoseconds: 700_000_000)

            guard let window = NSApp.windows.first(where: { $0.isVisible }) else {
                throw NSError(domain: "FeatherMacScreenshots", code: 1, userInfo: [NSLocalizedDescriptionKey: "No visible FeatherMac window."])
            }
            window.setContentSize(NSSize(width: 1120, height: 720))
            window.center()
            window.makeKeyAndOrderFront(nil)

            for (pane, filename) in [(Pane.library, "library.png"), (.automation, "automation.png"), (.signing, "signing.png")] {
                store.pane = pane
                try await Task.sleep(nanoseconds: 500_000_000)
                try captureWindow(window, to: outputDirectory.appendingPathComponent(filename))
            }

            NSApp.terminate(nil)
        } catch {
            fputs("Documentation screenshot capture failed: \(error.localizedDescription)\n", stderr)
            NSApp.terminate(nil)
        }
    }

    private static func seedDemoState(store: AppStore) {
        let importedID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let signedID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let certificateID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let root = "~/Library/Application Support/FeatherMac"
        let demoIconPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Assets/Source/FeatherMacIcon.png")
            .path

        store.library = [
            LibraryApp(
                id: importedID,
                kind: .imported,
                name: "Feather iOS",
                bundleIdentifier: "com.example.feather",
                version: "2.8.2",
                sourceURL: nil,
                storagePath: "\(root)/Imported/Feather",
                ipaPath: "\(root)/Imported/Feather.ipa",
                iconPath: demoIconPath,
                importedAt: Date(),
                certificateID: nil
            ),
            LibraryApp(
                id: signedID,
                kind: .signed,
                name: "Feather iOS Signed",
                bundleIdentifier: "com.example.feathermac.feather",
                version: "2.8.2",
                sourceURL: nil,
                storagePath: "\(root)/Signed/Feather",
                ipaPath: "\(root)/Signed/Feather-signed.ipa",
                iconPath: demoIconPath,
                importedAt: Date(),
                certificateID: certificateID
            )
        ]
        store.selectedAppID = signedID
        store.certificates = [
            CertificateRecord(
                id: certificateID,
                nickname: "Apple Development Demo",
                p12Path: "~/Certificates/demo.p12",
                provisionPath: "~/Profiles/demo.mobileprovision",
                password: "",
                expiration: Calendar.current.date(byAdding: .year, value: 1, to: Date()),
                teamName: "Example Team",
                teamIdentifier: "ABCDE12345",
                appIdentifierPrefix: "ABCDE12345",
                appIDName: "FeatherMac Demo",
                p12SerialNumber: "DEMO-SERIAL",
                importedAt: Date(),
                isDefault: true
            )
        ]
        store.selectedCertID = certificateID
        store.options.appName = "Feather Mac Demo"
        store.options.appVersion = "2.8.2"
        store.options.appIdentifier = "com.example.feathermac.feather"
        store.options.fileSharing = true
        store.options.iTunesFileSharing = true
        store.options.proMotion = true
        store.options.iPadFullscreen = true
        store.options.supportLiquidGlass = true
        store.options.installAfterSigning = true
        let demoKey = ASCKeyRecord(
            issuerID: "00000000-0000-0000-0000-000000000000",
            keyID: "DEMO123456",
            privateKeyPath: "~/Keys/AuthKey_DEMO123456.p8",
            teamIdentifier: "A1B2C3D4E5"
        )
        store.appStoreConnect = AppStoreConnectSettings(
            keys: [demoKey],
            selectedKeyID: demoKey.id,
            bundleIdentifierPrefix: "com.example.feathermac",
            registerConnectedDevice: true
        )
        store.automation = AutomationPipeline(
            appID: importedID,
            certificateID: certificateID,
            iconPath: "~/Pictures/demo-icon.png",
            installAfterSigning: true,
            lastSignedAppID: signedID,
            activeStep: nil,
            completedSteps: [.selectApp, .createProfile, .replaceIcon, .sign]
        )
        store.logs = [
            LogEntry(level: .success, message: "FeatherMac is ready."),
            LogEntry(level: .info, message: "Automation workflow prepared."),
            LogEntry(level: .success, message: "Signed Feather iOS Signed.")
        ]
        store.isBusy = false
        store.progressText = ""
    }

    private static func captureWindow(_ window: NSWindow, to url: URL) throws {
        let windowID = CGWindowID(window.windowNumber)
        let options = CGWindowImageOption.boundsIgnoreFraming.union(.bestResolution)
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            throw NSError(domain: "FeatherMacScreenshots", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not load window capture API."])
        }
        typealias WindowCaptureFunction = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> CGImage?
        let capture = unsafeBitCast(symbol, to: WindowCaptureFunction.self)
        guard let image = capture(.null, CGWindowListOption.optionIncludingWindow.rawValue, windowID, options.rawValue) else {
            throw NSError(domain: "FeatherMacScreenshots", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not capture FeatherMac window."])
        }
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "FeatherMacScreenshots", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG."])
        }
        try data.write(to: url, options: .atomic)
    }
}

enum Pane: String, CaseIterable, Identifiable {
    case library = "Library"
    case sources = "Sources"
    case certificates = "Certificates"
    case signing = "Signing"
    case automation = "Automation"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .library: "square.stack.3d.up"
        case .sources: "tray.full"
        case .certificates: "person.text.rectangle"
        case .signing: "signature"
        case .automation: "wand.and.stars"
        case .settings: "gearshape"
        }
    }
}

enum LogLevel: String, Codable {
    case info = "Info"
    case success = "Success"
    case warning = "Warning"
    case error = "Error"
}

enum L10n {
    static func string(_ key: String) -> String {
        let selected = UserDefaults.standard.string(forKey: "FeatherMac.language") ?? AppLanguage.system.rawValue
        let language = AppLanguage(rawValue: selected) ?? .system
        guard let bundle = localizedBundle(for: language) else {
            return NSLocalizedString(key, bundle: Bundle.module, comment: "")
        }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: AppLanguage.current.locale, arguments: arguments)
    }

    private static func localizedBundle(for language: AppLanguage) -> Bundle? {
        guard let localization = language.localization else { return nil }
        if let path = Bundle.module.path(forResource: localization, ofType: "lproj") {
            return Bundle(path: path)
        }

        let target = localization.lowercased()
        if let url = Bundle.module.urls(forResourcesWithExtension: "lproj", subdirectory: nil)?
            .first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == target }) {
            return Bundle(url: url)
        }

        return nil
    }
}

struct LogEntry: Identifiable, Codable {
    var id = UUID()
    var date = Date()
    var level: LogLevel
    var message: String
}

struct SourceRecord: Identifiable, Codable, Hashable {
    enum Kind: String, Codable, Hashable {
        case altSource
        case apt
    }

    var id = UUID()
    var url: URL
    var name: String
    var identifier: String?
    var iconURL: URL?
    var kind: Kind? = nil
    var addedAt = Date()
}

struct RepoCache: Identifiable {
    var id: UUID { source.id }
    var source: SourceRecord
    var repository: ASRepository? = nil
    var aptRepository: APTRepository? = nil
    var error: String? = nil
}

struct APTRepository: Hashable {
    var name: String
    var packages: [APTPackage]
}

struct APTPackage: Identifiable, Hashable {
    var id: String { packageIdentifier }
    var packageIdentifier: String
    var name: String?
    var version: String?
    var section: String?
    var architecture: String?
    var maintainer: String?
    var author: String?
    var summary: String?
    var description: String?
    var filename: String?
    var size: Int64?
    var depictionURL: URL?
    var iconURL: URL?
    var downloadURL: URL?
}

struct LibraryApp: Identifiable, Codable, Hashable {
    enum Kind: String, Codable {
        case imported
        case signed
    }

    var id = UUID()
    var kind: Kind
    var name: String
    var bundleIdentifier: String
    var version: String
    var sourceURL: URL?
    var storagePath: String
    var ipaPath: String?
    var iconPath: String?
    var importedAt = Date()
    var certificateID: UUID?

    var storageURL: URL { URL(fileURLWithPath: storagePath) }
    var ipaURL: URL? { ipaPath.map { URL(fileURLWithPath: $0) } }
    var iconURL: URL? { iconPath.map { URL(fileURLWithPath: $0) } }
}

struct CertificateRecord: Identifiable, Codable, Hashable {
    var id = UUID()
    var nickname: String
    var p12Path: String
    var provisionPath: String? = nil
    /// 只在内存里；持久化时走钥匙串，不写进 certificates.json。见 `KeychainStore`。
    var password: String
    var expiration: Date?
    var teamName: String?
    var teamIdentifier: String? = nil
    var appIdentifierPrefix: String? = nil
    var appIDName: String?
    var p12SerialNumber: String? = nil
    var importedAt = Date()
    var isDefault = false

    var p12URL: URL { URL(fileURLWithPath: p12Path) }
    var provisionURL: URL? { provisionPath.map { URL(fileURLWithPath: $0) } }

    /// 密码不参与编解码。`FeatherStorage` 负责在读写时与钥匙串同步。
    private enum CodingKeys: String, CodingKey {
        case id, nickname, p12Path, provisionPath, expiration, teamName
        case teamIdentifier, appIdentifierPrefix, appIDName, p12SerialNumber
        case importedAt, isDefault
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        nickname = try container.decode(String.self, forKey: .nickname)
        p12Path = try container.decode(String.self, forKey: .p12Path)
        provisionPath = try container.decodeIfPresent(String.self, forKey: .provisionPath)
        password = ""
        expiration = try container.decodeIfPresent(Date.self, forKey: .expiration)
        teamName = try container.decodeIfPresent(String.self, forKey: .teamName)
        teamIdentifier = try container.decodeIfPresent(String.self, forKey: .teamIdentifier)
        appIdentifierPrefix = try container.decodeIfPresent(String.self, forKey: .appIdentifierPrefix)
        appIDName = try container.decodeIfPresent(String.self, forKey: .appIDName)
        p12SerialNumber = try container.decodeIfPresent(String.self, forKey: .p12SerialNumber)
        importedAt = try container.decodeIfPresent(Date.self, forKey: .importedAt) ?? Date()
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }

    init(
        id: UUID = UUID(),
        nickname: String,
        p12Path: String,
        provisionPath: String? = nil,
        password: String,
        expiration: Date? = nil,
        teamName: String? = nil,
        teamIdentifier: String? = nil,
        appIdentifierPrefix: String? = nil,
        appIDName: String? = nil,
        p12SerialNumber: String? = nil,
        importedAt: Date = Date(),
        isDefault: Bool = false
    ) {
        self.id = id
        self.nickname = nickname
        self.p12Path = p12Path
        self.provisionPath = provisionPath
        self.password = password
        self.expiration = expiration
        self.teamName = teamName
        self.teamIdentifier = teamIdentifier
        self.appIdentifierPrefix = appIdentifierPrefix
        self.appIDName = appIDName
        self.p12SerialNumber = p12SerialNumber
        self.importedAt = importedAt
        self.isDefault = isDefault
    }
}

/// 一把 App Store Connect API 密钥。私钥文件由应用托管（复制进数据目录，0600），
/// `privateKeyPath` 指向的始终是这份副本，不是用户当初选的原始文件。
struct ASCKeyRecord: Identifiable, Codable, Hashable {
    var id = UUID()
    var issuerID: String
    var keyID: String
    var privateKeyPath: String
    /// 校验成功后缓存的团队 ID，用于在列表里区分多个账号。
    var teamIdentifier: String?
    var addedAt = Date()

    var privateKeyURL: URL { URL(fileURLWithPath: privateKeyPath) }

    var displayName: String {
        [keyID, teamIdentifier].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct AppStoreConnectSettings: Codable, Equatable {
    var keys: [ASCKeyRecord] = []
    var selectedKeyID: UUID?
    var bundleIdentifierPrefix = ""
    var registerConnectedDevice = true

    var activeKey: ASCKeyRecord? {
        keys.first { $0.id == selectedKeyID } ?? keys.first
    }

    // 只读兼容层：客户端签 JWT、服务层校验、导出配置都还按这三项读，保持不变。
    var issuerID: String { activeKey?.issuerID ?? "" }
    var keyID: String { activeKey?.keyID ?? "" }
    var privateKeyPath: String { activeKey?.privateKeyPath ?? "" }
}

extension AppStoreConnectSettings {
    private enum CodingKeys: String, CodingKey {
        case keys, selectedKeyID, bundleIdentifierPrefix, registerConnectedDevice
        // 旧版本平铺的三项，只用于读取迁移。
        case issuerID, keyID, privateKeyPath
    }

    /// 兼容旧版 appstoreconnect.json：三项平铺的单份配置迁移成列表里的第一把密钥。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var keys = try container.decodeIfPresent([ASCKeyRecord].self, forKey: .keys) ?? []
        var selected = try container.decodeIfPresent(UUID.self, forKey: .selectedKeyID)

        if keys.isEmpty {
            let legacyIssuer = (try container.decodeIfPresent(String.self, forKey: .issuerID) ?? "").trimmed
            let legacyKeyID = (try container.decodeIfPresent(String.self, forKey: .keyID) ?? "").trimmed
            let legacyPath = (try container.decodeIfPresent(String.self, forKey: .privateKeyPath) ?? "").trimmed
            if !legacyIssuer.isEmpty || !legacyKeyID.isEmpty || !legacyPath.isEmpty {
                let migrated = ASCKeyRecord(
                    issuerID: legacyIssuer,
                    keyID: legacyKeyID,
                    privateKeyPath: legacyPath
                )
                keys = [migrated]
                selected = migrated.id
            }
        }
        if selected == nil || !keys.contains(where: { $0.id == selected }) {
            selected = keys.first?.id
        }

        self.init(
            keys: keys,
            selectedKeyID: selected,
            bundleIdentifierPrefix: try container.decodeIfPresent(String.self, forKey: .bundleIdentifierPrefix) ?? "",
            registerConnectedDevice: try container.decodeIfPresent(Bool.self, forKey: .registerConnectedDevice) ?? true
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keys, forKey: .keys)
        try container.encodeIfPresent(selectedKeyID, forKey: .selectedKeyID)
        try container.encode(bundleIdentifierPrefix, forKey: .bundleIdentifierPrefix)
        try container.encode(registerConnectedDevice, forKey: .registerConnectedDevice)
    }
}

struct AutomationPipeline: Codable, Equatable {
    enum Step: String, CaseIterable, Codable, Identifiable {
        case selectApp = "Select IPA"
        case createProfile = "Create Profile"
        case replaceIcon = "Replace Icon"
        case sign = "Sign"
        case install = "Install"

        var id: String { rawValue }
    }

    var appID: UUID?
    var certificateID: UUID?
    var appName = ""
    var iconPath = ""
    var installAfterSigning = true
    var lastSignedAppID: UUID?
    var activeStep: Step?
    var completedSteps: [Step] = []

    mutating func resetRun() {
        activeStep = nil
        completedSteps = []
        lastSignedAppID = nil
    }
}

extension AutomationPipeline {
    /// 兼容旧版本持久化的 automation.json（缺少新增字段如 appName 时按默认值解码）。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            appID: try container.decodeIfPresent(UUID.self, forKey: .appID),
            certificateID: try container.decodeIfPresent(UUID.self, forKey: .certificateID),
            appName: try container.decodeIfPresent(String.self, forKey: .appName) ?? "",
            iconPath: try container.decodeIfPresent(String.self, forKey: .iconPath) ?? "",
            installAfterSigning: try container.decodeIfPresent(Bool.self, forKey: .installAfterSigning) ?? true,
            lastSignedAppID: try container.decodeIfPresent(UUID.self, forKey: .lastSignedAppID),
            activeStep: try container.decodeIfPresent(Step.self, forKey: .activeStep),
            completedSteps: try container.decodeIfPresent([Step].self, forKey: .completedSteps) ?? []
        )
    }
}

struct AppStoreConnectExport: Codable {
    var issuerID: String
    var keyID: String
    var privateKeyPEM: String
    var bundleIdentifierPrefix: String
    var registerConnectedDevice: Bool
}

struct SigningOptions: Codable, Equatable {
    enum Appearance: String, CaseIterable, Codable, Identifiable {
        case `default` = "Default"
        case light = "Light"
        case dark = "Dark"
        var id: String { rawValue }
    }

    enum MinimumOS: String, CaseIterable, Codable, Identifiable {
        case `default` = "Default"
        case v16 = "16.0"
        case v15 = "15.0"
        case v14 = "14.0"
        case v13 = "13.0"
        case v12 = "12.0"
        var id: String { rawValue }
    }

    enum SigningMode: String, CaseIterable, Codable, Identifiable {
        case certificate = "Certificate"
        case modifyOnly = "Modify only"
        var id: String { rawValue }
    }

    enum InjectPath: String, CaseIterable, Codable, Identifiable {
        case executable = "@executable_path"
        case rpath = "@rpath"
        var id: String { rawValue }
    }

    enum InjectFolder: String, CaseIterable, Codable, Identifiable {
        case frameworks = "Frameworks"
        case root = "Root"
        var id: String { rawValue }
    }

    var appName = ""
    var appVersion = ""
    var appIdentifier = ""
    var provisionPath: String? = nil
    var entitlementsPath = ""
    var iconPath = ""
    var appearance: Appearance = .default
    var minimumOS: MinimumOS = .default
    var signingMode: SigningMode = .certificate
    var injectPath: InjectPath = .executable
    var injectFolder: InjectFolder = .frameworks
    var ppqString = SigningOptions.randomString()
    var ppqProtection = false
    var dynamicProtection = false
    var identifierRules = ""
    var displayNameRules = ""
    var injectionFilePaths: [String] = []
    var disinjectLoadCommands = ""
    var removeFileRules = ""
    var fileSharing = false
    var iTunesFileSharing = false
    var proMotion = false
    var gameMode = false
    var iPadFullscreen = false
    var removeURLScheme = false
    var removeProvisioning = false
    var changeLanguageFilesForCustomDisplayName = true
    var injectIntoExtensions = false
    var supportLiquidGlass = false
    var replaceSubstrateWithElleKit = false
    var installAfterSigning = false
    var deleteAfterSigning = false
    var zipCompressionLevel = 6

    static func randomString() -> String {
        String((0..<6).compactMap { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement() })
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published var pane: Pane = .library
    @Published var sources: [SourceRecord] = []
    @Published var repos: [RepoCache] = []
    @Published var library: [LibraryApp] = []
    @Published var certificates: [CertificateRecord] = []
    @Published var selectedAppID: UUID?
    @Published var selectedCertID: UUID?
    @Published var options = SigningOptions()
    @Published var appStoreConnect = AppStoreConnectSettings()
    @Published var automation = AutomationPipeline()
    @Published var logs: [LogEntry] = []
    @Published var isBusy = false
    @Published var progressText = ""
    @Published var sourceURLDraft = ""
    @Published var certificatePasswordDraft = ""
    @Published var showAddSource = false

    // MARK: ASC 凭据与证书申请
    @Published var showASCWizard = false
    @Published var credentialState: ASCCredentialState = .unconfigured
    @Published var credentialTeamIdentifier: String?
    @Published var newCertificateType: DeveloperCertificateType = .iosDevelopment
    @Published var newCertificatePasswordDraft = ""
    /// 创建成功后一次性展示的密码；用户关掉即清空。
    @Published var createdCertificateReveal: CreatedCertificateReveal?
    /// 门户证书序列号集合，用于在详情区显示"与账号一致 / 门户中已不存在"。
    @Published var portalSerialNumbers: Set<String>?
    /// 产生当前校验结论的那份凭据的指纹，凭据变了就作废。
    @Published var verifiedCredentialFingerprint: String?
    /// 用户在自动配置页选了 .p8 但凭据不全时，暂存路径交给向导接着走。
    @Published var pendingKeyImportPath: String?

    let storage = FeatherStorage()
    let sourceService = SourceService()
    let ipaService = IPAService()
    let installService = InstallService()
    let developerService = AppleDeveloperService()

    var selectedApp: LibraryApp? {
        get { library.first { $0.id == selectedAppID } }
        set { selectedAppID = newValue?.id }
    }

    var selectedCert: CertificateRecord? {
        get { certificates.first { $0.id == selectedCertID } ?? certificates.first(where: \.isDefault) }
        set { selectedCertID = newValue?.id }
    }

    func bootstrap() async {
        do {
            try storage.prepare()
            sources = try storage.loadSources()
            library = try storage.loadLibrary()
            certificates = try storage.loadCertificates()
            options = try storage.loadOptions()
            appStoreConnect = try storage.loadAppStoreConnectSettings()
            automation = try storage.loadAutomationPipeline()
            refreshCredentialState()
            // 旧格式解码时会给迁移出来的密钥现分配 UUID，不落盘的话每次启动都换一个 id。
            // 立刻按新格式写回，规范化一次即可（与上面 sanitizedSources 的做法一致）。
            try storage.saveAppStoreConnectSettings(appStoreConnect)
            pruneOrphanedASCKeys()
            let sanitizedSources = SourceService.sanitizedSources(sources)
            if sanitizedSources != sources {
                sources = sanitizedSources
                try storage.saveSources(sources)
            }
            selectedAppID = library.first?.id
            selectedCertID = certificates.first(where: \.isDefault)?.id ?? certificates.first?.id
            if options.provisionPath?.trimmed.nonEmpty == nil,
               let legacyProvisionPath = selectedCert?.provisionPath?.trimmed.nonEmpty {
                options.provisionPath = legacyProvisionPath
            }
            if automation.appID == nil {
                automation.appID = library.first(where: { $0.kind == .imported })?.id
            }
            if automation.certificateID == nil {
                automation.certificateID = selectedCertID
            }
            log(.success, "FeatherMac is ready.")
            await refreshSources()
        } catch {
            log(.error, error.localizedDescription)
        }
    }

    func log(_ level: LogLevel, _ message: String) {
        logs.insert(LogEntry(level: level, message: message), at: 0)
        logs = Array(logs.prefix(300))
    }

    func saveAll() {
        do {
            try storage.saveSources(sources)
            try storage.saveLibrary(library)
            try storage.saveCertificates(certificates)
            try storage.saveOptions(options)
            try storage.saveAppStoreConnectSettings(appStoreConnect)
            try storage.saveAutomationPipeline(automation)
        } catch {
            log(.error, error.localizedDescription)
        }
    }

    func refreshSources() async {
        repos = sources.map { RepoCache(source: $0, repository: nil, error: nil) }
        for source in sources {
            do {
                let fetched = try await sourceService.fetchSource(url: source.url)
                if let index = repos.firstIndex(where: { $0.source.id == source.id }) {
                    switch fetched {
                    case .altSource(let repository):
                        repos[index].repository = repository
                        repos[index].aptRepository = nil
                    case .apt(let repository):
                        repos[index].repository = nil
                        repos[index].aptRepository = repository
                    }
                    repos[index].error = nil
                }
                if let sourceIndex = sources.firstIndex(where: { $0.id == source.id }) {
                    switch fetched {
                    case .altSource(let repository):
                        sources[sourceIndex].name = repository.name ?? source.name
                        sources[sourceIndex].identifier = repository.id
                        sources[sourceIndex].iconURL = repository.currentIconURL
                        sources[sourceIndex].kind = .altSource
                    case .apt(let repository):
                        sources[sourceIndex].name = repository.name
                        sources[sourceIndex].identifier = nil
                        sources[sourceIndex].iconURL = nil
                        sources[sourceIndex].kind = .apt
                    }
                }
                try? storage.saveSources(sources)
            } catch {
                if let index = repos.firstIndex(where: { $0.source.id == source.id }) {
                    repos[index].error = error.localizedDescription
                }
                log(.warning, "Could not refresh \(source.name): \(error.localizedDescription)")
            }
        }
    }

    func addSource() async {
        guard let url = URL(string: sourceURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            log(.error, "Enter a valid source URL.")
            return
        }
        do {
            let fetched = try await sourceService.fetchSource(url: url)
            let source: SourceRecord
            switch fetched {
            case .altSource(let repo):
                source = SourceRecord(
                    url: url,
                    name: repo.name ?? url.host ?? url.absoluteString,
                    identifier: repo.id,
                    iconURL: repo.currentIconURL,
                    kind: .altSource
                )
            case .apt(let repo):
                source = SourceRecord(
                    url: url,
                    name: repo.name,
                    identifier: nil,
                    iconURL: nil,
                    kind: .apt
                )
            }
            sources.removeAll { $0.url == url }
            sources.append(source)
            sourceURLDraft = ""
            showAddSource = false
            try storage.saveSources(sources)
            log(.success, "Added source \(source.name).")
            await refreshSources()
        } catch {
            log(.error, "Source import failed: \(error.localizedDescription)")
        }
    }

    func deleteSource(_ source: SourceRecord) {
        sources.removeAll { $0.id == source.id }
        repos.removeAll { $0.source.id == source.id }
        saveAll()
        log(.info, "Removed source \(source.name).")
    }

    func pickAndImportIPA() async {
        guard let url = FilePicker.open(types: [.init(filenameExtension: "ipa")!, .init(filenameExtension: "tipa")!]) else { return }
        await importIPA(url: url, source: nil)
    }

    func downloadAndImport(_ app: ASRepository.App) async {
        guard let url = app.bestDownloadURL else {
            log(.error, "This app does not expose a download URL.")
            return
        }
        await runBusy("Downloading \(app.name ?? "app")...") {
            let downloaded = try await self.sourceService.download(url: url, to: self.storage.downloadsDirectory)
            await MainActor.run {
                self.log(.success, "Downloaded \(downloaded.lastPathComponent).")
            }
            try await self.importIPAThrowing(url: downloaded, source: url)
        }
    }

    func importIPA(url: URL, source: URL?) async {
        await runBusy("Importing \(url.lastPathComponent)...") {
            try await self.importIPAThrowing(url: url, source: source)
        }
    }

    private func importIPAThrowing(url: URL, source: URL?) async throws {
        let app = try await ipaService.importIPA(url: url, source: source, storage: storage)
        await MainActor.run {
            library.removeAll { $0.id == app.id }
            library.insert(app, at: 0)
            selectedAppID = app.id
            saveAll()
            log(.success, "Imported \(app.name) \(app.version).")
        }
    }

    func pickCertificateFiles() async {
        let p12 = FilePicker.open(types: [.init(filenameExtension: "p12")!])
        guard let p12 else { return }
        await importCertificate(p12: p12, password: certificatePasswordDraft)
    }

    func importCertificate(p12: URL, password: String) async {
        await runBusy("Importing certificate...") {
            let cert = try CertificateService.importCertificate(p12: p12, password: password, storage: self.storage)
            await MainActor.run {
                var record = cert
                if self.certificates.isEmpty {
                    record.isDefault = true
                }
                self.certificates.insert(record, at: 0)
                self.selectedCertID = record.id
                self.certificatePasswordDraft = ""
                self.saveAll()
                self.log(.success, "Imported certificate \(record.nickname).")
            }
        }
    }

    func setDefaultCertificate(_ cert: CertificateRecord) {
        for index in certificates.indices {
            certificates[index].isDefault = certificates[index].id == cert.id
        }
        selectedCertID = cert.id
        saveAll()
    }

    func deleteCertificate(_ cert: CertificateRecord) {
        try? FileManager.default.removeItem(at: cert.p12URL.deletingLastPathComponent())
        // 一并清掉钥匙串条目，否则删过的证书会在钥匙串里留下无主密码越积越多。
        KeychainStore.delete(for: cert.id)
        certificates.removeAll { $0.id == cert.id }
        selectedCertID = certificates.first?.id
        saveAll()
        log(.info, "Deleted certificate \(cert.nickname).")
    }

    func signSelectedApp() async {
        guard let app = selectedApp else {
            log(.error, "Select an imported app first.")
            return
        }
        let cert = selectedCert
        if options.signingMode == .certificate && cert == nil {
            log(.error, "Import a certificate or switch signing mode to Modify only.")
            return
        }
        let provisionURL = selectedProvisionURL()
        if options.signingMode == .certificate && provisionURL == nil {
            log(.error, L10n.string("Choose a provisioning profile before signing."))
            return
        }
        await runBusy("Signing \(app.name)...") {
            if let cert, let provisionURL {
                try self.validateSigningMaterials(app: app, certificate: cert, provisionURL: provisionURL, options: self.options)
            }
            let signed = try await self.ipaService.sign(app: app, certificate: cert, provisionURL: provisionURL, options: self.options, storage: self.storage) { message in
                Task { @MainActor in self.progressText = message }
            }
            await MainActor.run {
                self.library.insert(signed, at: 0)
                self.selectedAppID = signed.id
                if self.options.deleteAfterSigning {
                    self.deleteApp(app, silent: true)
                }
                self.saveAll()
                self.log(.success, "Signed \(signed.name).")
            }
            if await MainActor.run(body: { self.options.installAfterSigning }) {
                try await self.installService.install(app: signed)
                await MainActor.run { self.log(.success, "Install command completed.") }
            }
        }
    }

    private func validateSigningMaterials(app: LibraryApp, certificate: CertificateRecord, provisionURL: URL, options: SigningOptions) throws {
        // 密码存在钥匙串里，可能读不到（换了机器、恢复了备份、条目被删）。
        // 早点说清楚怎么恢复，别让它变成 openssl 的一句 "invalid password"。
        if certificate.password.isEmpty {
            throw FeatherError.message(L10n.format(
                "The p12 password for “%@” is not in your keychain. Import the .p12 again to restore it.",
                certificate.nickname
            ))
        }
        guard FileManager.default.fileExists(atPath: provisionURL.path) else {
            throw FeatherError.message(L10n.string("Provisioning profile file is missing."))
        }
        let metadata = CertificateService.parseProvision(provisionURL)
        let expectedBundleID = options.appIdentifier.trimmed.nonEmpty ?? app.bundleIdentifier
        if let profileBundleID = metadata.bundleIdentifier, profileBundleID != expectedBundleID {
            throw FeatherError.message(L10n.format("Provisioning profile Bundle ID %@ does not match %@.", profileBundleID, expectedBundleID))
        }
        if let profileTeamID = metadata.teamIdentifier,
           let certificateTeamID = certificate.teamIdentifier,
           profileTeamID != certificateTeamID {
            throw FeatherError.message(L10n.format("Provisioning profile team %@ does not match certificate team %@.", profileTeamID, certificateTeamID))
        }
        let serial = try CertificateService.p12CertificateSerialNumber(p12: certificate.p12URL, password: certificate.password)
        if let serial, !serial.isEmpty {
            let provisionSerials = try CertificateService.developerCertificateSerials(in: provisionURL)
            if !provisionSerials.isEmpty && !provisionSerials.contains(serial.uppercased()) {
                throw FeatherError.message(L10n.string("Provisioning profile does not include the selected certificate."))
            }
        }
    }

    func installSelectedApp() async {
        guard let app = selectedApp else { return }
        await runBusy("Installing \(app.name)...") {
            try await self.installService.install(app: app)
            await MainActor.run { self.log(.success, "Install command completed.") }
        }
    }

    func exportSelectedIPA() {
        guard let ipaURL = selectedApp?.ipaURL else {
            log(.error, "This app does not have an IPA archive yet.")
            return
        }
        guard let destination = FilePicker.save(defaultName: ipaURL.lastPathComponent) else { return }
        do {
            try FileManager.default.removeItemIfExists(at: destination)
            try FileManager.default.copyItem(at: ipaURL, to: destination)
            log(.success, "Exported \(destination.lastPathComponent).")
        } catch {
            log(.error, error.localizedDescription)
        }
    }

    func revealSelectedApp() {
        guard let url = selectedApp?.ipaURL ?? selectedApp?.storageURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func deleteSelectedApp() {
        guard let app = selectedApp else { return }
        deleteApp(app, silent: false)
    }

    private func deleteApp(_ app: LibraryApp, silent: Bool) {
        try? FileManager.default.removeItem(at: app.storageURL)
        if let ipaURL = app.ipaURL {
            try? FileManager.default.removeItem(at: ipaURL)
        }
        library.removeAll { $0.id == app.id }
        selectedAppID = library.first?.id
        saveAll()
        if !silent {
            log(.info, "Deleted \(app.name).")
        }
    }

    func pickEntitlements() {
        if let url = FilePicker.open(types: [.propertyList]) {
            options.entitlementsPath = url.path
            saveAll()
        }
    }

    func pickIcon() {
        let png = UTType.png
        let jpeg = UTType.jpeg
        if let url = FilePicker.open(types: [png, jpeg]) {
            options.iconPath = url.path
            saveAll()
        }
    }

    func pickProvisioningProfile() {
        guard let url = FilePicker.open(types: [.init(filenameExtension: "mobileprovision")!, .init(filenameExtension: "provisionprofile")!]) else { return }
        options.provisionPath = url.path
        let metadata = CertificateService.parseProvision(url)
        if let bundleIdentifier = metadata.bundleIdentifier {
            options.appIdentifier = bundleIdentifier
        }
        saveAll()
        log(.success, L10n.format("Selected provisioning profile %@.", url.lastPathComponent))
    }

    func selectedProvisionURL() -> URL? {
        if let path = options.provisionPath?.trimmed.nonEmpty {
            return URL(fileURLWithPath: path)
        }
        return selectedCert?.provisionURL
    }

    func pickAutomationIcon() {
        let png = UTType.png
        let jpeg = UTType.jpeg
        if let url = FilePicker.open(types: [png, jpeg]) {
            automation.iconPath = url.path
            saveAll()
        }
    }


    func applySuggestedBundleIdentifier() {
        guard let app = selectedApp else {
            log(.error, "Select an imported app first.")
            return
        }
        let suggestion = BundleIdentifierGenerator.suggestedIdentifier(
            app: app,
            certificate: selectedCert,
            configuredPrefix: appStoreConnect.bundleIdentifierPrefix
        )
        options.appName = app.name
        options.appIdentifier = suggestion
        saveAll()
        log(.success, "Suggested Bundle ID \(suggestion).")
    }

    func autoConfigureProvisioning() async {
        guard let app = selectedApp, app.kind == .imported else {
            log(.error, "Select an imported app first.")
            return
        }
        guard let cert = selectedCert else {
            log(.error, "Import a certificate or switch signing mode to Modify only.")
            return
        }
        await runBusy("Creating provisioning profile...") {
            let suggestedIdentifier = await MainActor.run {
                BundleIdentifierGenerator.suggestedIdentifier(
                    app: app,
                    certificate: cert,
                    configuredPrefix: self.appStoreConnect.bundleIdentifierPrefix
                )
            }
            let configured = await MainActor.run { self.appStoreConnect }
            var workingCert = cert
            if workingCert.p12SerialNumber?.isEmpty != false {
                workingCert.p12SerialNumber = try CertificateService.p12CertificateSerialNumber(
                    p12: workingCert.p12URL,
                    password: workingCert.password
                )
            }
            let profile = try await self.developerService.createDevelopmentProfile(
                appName: self.options.appName.trimmed.nonEmpty ?? app.name,
                bundleIdentifier: suggestedIdentifier,
                certificate: workingCert,
                settings: configured,
                progress: { message in
                    Task { @MainActor in self.log(.info, message) }
                }
            )
            let profileDirectory = workingCert.p12URL.deletingLastPathComponent().appendingPathComponent("AutoProfiles", isDirectory: true)
            try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
            let profileURL = profileDirectory.appendingPathComponent("\(BundleIdentifierGenerator.safeComponent(suggestedIdentifier)).mobileprovision")
            try profile.data.write(to: profileURL, options: .atomic)
            let metadata = CertificateService.parseProvision(profileURL)
            workingCert.expiration = metadata.expiration
            workingCert.teamName = metadata.teamName ?? workingCert.teamName
            workingCert.teamIdentifier = metadata.teamIdentifier ?? workingCert.teamIdentifier
            workingCert.appIdentifierPrefix = metadata.appIdentifierPrefix ?? workingCert.appIdentifierPrefix
            workingCert.appIDName = metadata.appIDName ?? profile.name
            await MainActor.run {
                if let index = self.certificates.firstIndex(where: { $0.id == workingCert.id }) {
                    self.certificates[index] = workingCert
                }
                self.selectedCertID = workingCert.id
                self.options.appName = app.name
                self.options.appIdentifier = suggestedIdentifier
                self.options.provisionPath = profileURL.path
                self.options.signingMode = .certificate
                self.saveAll()
                self.log(.success, "Created provisioning profile \(profile.name).")
                self.log(.success, "Updated signing Bundle ID to \(suggestedIdentifier).")
            }
        }
    }

    var automationApp: LibraryApp? {
        library.first { $0.id == automation.appID && $0.kind == .imported }
    }

    var automationCertificate: CertificateRecord? {
        certificates.first { $0.id == automation.certificateID } ?? certificates.first(where: \.isDefault)
    }

    var automationLastSignedApp: LibraryApp? {
        library.first { $0.id == automation.lastSignedAppID }
    }

    func runAutomationPipeline() async {
        guard let app = automationApp else {
            log(.error, "Select an imported app first.")
            return
        }
        guard let cert = automationCertificate else {
            log(.error, "Import a certificate or switch signing mode to Modify only.")
            return
        }
        let displayName = await MainActor.run { self.automation.appName.trimmed.nonEmpty ?? app.name }
        await runBusy("Running workflow...") {
            await MainActor.run {
                self.automation.resetRun()
                self.automation.activeStep = .selectApp
                self.saveAll()
                self.log(.info, "Workflow selected \(app.name) -> \(displayName).")
            }
            await self.finishAutomationStep(.selectApp)

            await MainActor.run { self.automation.activeStep = .createProfile }
            let configured = await MainActor.run { self.appStoreConnect }
            let bundleID = BundleIdentifierGenerator.suggestedIdentifier(
                app: app,
                certificate: cert,
                configuredPrefix: configured.bundleIdentifierPrefix
            )
            let (updatedCert, profileURL) = try await self.createProvisioningProfile(app: app, displayName: displayName, certificate: cert, bundleIdentifier: bundleID, settings: configured)
            await MainActor.run {
                self.options.appName = displayName
                self.options.appIdentifier = bundleID
                self.options.provisionPath = profileURL.path
                self.options.signingMode = .certificate
                self.selectedAppID = app.id
                self.selectedCertID = updatedCert.id
                self.log(.success, "Created provisioning profile for \(bundleID).")
            }
            await self.finishAutomationStep(.createProfile)

            await MainActor.run { self.automation.activeStep = .replaceIcon }
            let iconPath = await MainActor.run { self.automation.iconPath }
            await MainActor.run {
                self.options.iconPath = iconPath
                if iconPath.isEmpty {
                    self.log(.info, "Workflow kept original app icon.")
                } else {
                    self.log(.success, "Workflow will replace app icon.")
                }
            }
            await self.finishAutomationStep(.replaceIcon)

            await MainActor.run { self.automation.activeStep = .sign }
            let workflowOptions = await MainActor.run { self.options }
            let signed = try await self.ipaService.sign(app: app, certificate: updatedCert, provisionURL: profileURL, options: workflowOptions, storage: self.storage) { message in
                Task { @MainActor in self.progressText = message }
            }
            await MainActor.run {
                self.library.insert(signed, at: 0)
                self.automation.lastSignedAppID = signed.id
                self.selectedAppID = signed.id
                self.log(.success, "Workflow signed \(signed.name).")
                self.saveAll()
            }
            await self.finishAutomationStep(.sign)

            if await MainActor.run(body: { self.automation.installAfterSigning }) {
                await MainActor.run { self.automation.activeStep = .install }
                try await self.installService.install(app: signed)
                await MainActor.run { self.log(.success, "Workflow installed \(signed.name).") }
                await self.finishAutomationStep(.install)
            }

            await MainActor.run {
                self.automation.activeStep = nil
                self.saveAll()
                self.log(.success, "Workflow completed.")
            }
        }
    }

    func installAutomationResult() async {
        guard let app = automationLastSignedApp else {
            log(.error, "No workflow signed app is available.")
            return
        }
        await runBusy("Installing \(app.name)...") {
            try await self.installService.install(app: app)
            await MainActor.run { self.log(.success, "Install command completed.") }
        }
    }

    private func finishAutomationStep(_ step: AutomationPipeline.Step) async {
        await MainActor.run {
            if !self.automation.completedSteps.contains(step) {
                self.automation.completedSteps.append(step)
            }
            self.saveAll()
        }
    }

    private func createProvisioningProfile(app: LibraryApp, displayName: String, certificate: CertificateRecord, bundleIdentifier: String, settings: AppStoreConnectSettings) async throws -> (CertificateRecord, URL) {
        var workingCert = certificate
        if workingCert.p12SerialNumber?.isEmpty != false {
            workingCert.p12SerialNumber = try CertificateService.p12CertificateSerialNumber(
                p12: workingCert.p12URL,
                password: workingCert.password
            )
        }
        let profileDirectory = workingCert.p12URL.deletingLastPathComponent().appendingPathComponent("AutoProfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        let profileURL = profileDirectory.appendingPathComponent("\(BundleIdentifierGenerator.safeComponent(bundleIdentifier)).mobileprovision")
        let profileName: String
        if let reusableProfile = reusableProvisioningProfile(for: workingCert, bundleIdentifier: bundleIdentifier) {
            if reusableProfile.standardizedFileURL != profileURL.standardizedFileURL {
                try FileManager.default.copyItemReplacing(from: reusableProfile, to: profileURL)
            }
            profileName = CertificateService.parseProvision(profileURL).appIDName ?? profileURL.deletingPathExtension().lastPathComponent
            await MainActor.run { self.log(.success, "Reused provisioning profile \(profileName).") }
        } else {
            let profile = try await developerService.createDevelopmentProfile(
                appName: displayName,
                bundleIdentifier: bundleIdentifier,
                certificate: workingCert,
                settings: settings,
                progress: { message in
                    Task { @MainActor in self.log(.info, message) }
                }
            )
            try profile.data.write(to: profileURL, options: .atomic)
            profileName = profile.name
        }
        let metadata = CertificateService.parseProvision(profileURL)
        workingCert.expiration = metadata.expiration
        workingCert.teamName = metadata.teamName ?? workingCert.teamName
        workingCert.teamIdentifier = metadata.teamIdentifier ?? workingCert.teamIdentifier
        workingCert.appIdentifierPrefix = metadata.appIdentifierPrefix ?? workingCert.appIdentifierPrefix
        workingCert.appIDName = metadata.appIDName ?? profileName
        await MainActor.run {
            if let index = self.certificates.firstIndex(where: { $0.id == workingCert.id }) {
                self.certificates[index] = workingCert
            }
            self.selectedCertID = workingCert.id
            self.saveAll()
        }
        return (workingCert, profileURL)
    }

    private func reusableProvisioningProfile(for certificate: CertificateRecord, bundleIdentifier: String) -> URL? {
        let autoProfilesDirectory = certificate.p12URL.deletingLastPathComponent().appendingPathComponent("AutoProfiles", isDirectory: true)
        var candidates: [URL] = []
        if let legacyProvision = certificate.provisionURL {
            candidates.append(legacyProvision)
        }
        if let autoProfiles = try? FileManager.default.contentsOfDirectory(
            at: autoProfilesDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            candidates.append(contentsOf: autoProfiles.filter { $0.pathExtension.lowercased() == "mobileprovision" })
        }
        let minimumExpiration = Date().addingTimeInterval(24 * 60 * 60)
        return candidates
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { lhs, rhs in
                let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return leftDate > rightDate
            }
            .first { url in
                let metadata = CertificateService.parseProvision(url)
                return metadata.expiration.map { $0 > minimumExpiration } == true
                    && metadata.bundleIdentifier == bundleIdentifier
            }
    }

    func exportAppStoreConnectConfig() {
        guard Confirm.warn(
            title: "This file contains your API private key",
            message: "The exported file embeds your App Store Connect .p8 private key in plain text. Anyone who obtains it can create and revoke certificates on your account. Store it somewhere safe and do not share it.",
            confirmTitle: "Export Anyway"
        ) else { return }
        guard let export = makeAppStoreConnectExport() else { return }
        guard let destination = FilePicker.save(defaultName: "FeatherMac-AppStoreConnect.feathermacconfig") else { return }
        do {
            try writeSecureExport(export, to: destination)
            log(.success, "Exported App Store Connect configuration.")
        } catch {
            log(.error, error.localizedDescription)
        }
    }

    func importAppStoreConnectConfig() {
        guard let configType = UTType(filenameExtension: "feathermacconfig"),
              let url = FilePicker.open(types: [configType, .json]) else { return }
        do {
            try importAppStoreConnectExport(from: url)
            saveAll()
            log(.success, "Imported App Store Connect configuration.")
        } catch {
            log(.error, error.localizedDescription)
        }
    }

    func syncAppStoreConnectConfigToICloud() {
        guard Confirm.warn(
            title: "Upload your API private key to iCloud Drive?",
            message: "Your App Store Connect .p8 private key will be written to iCloud Drive in plain text and synced to every device signed in to your Apple ID. Only continue if you trust that account.",
            confirmTitle: "Upload to iCloud"
        ) else { return }
        guard let export = makeAppStoreConnectExport() else { return }
        do {
            let destination = try storage.iCloudConfigURL()
            try writeSecureExport(export, to: destination)
            log(.success, "Synced App Store Connect configuration to iCloud Drive.")
        } catch {
            log(.error, error.localizedDescription)
        }
    }

    func restoreAppStoreConnectConfigFromICloud() {
        do {
            let url = try storage.iCloudConfigURL()
            try importAppStoreConnectExport(from: url)
            saveAll()
            log(.success, "Restored App Store Connect configuration from iCloud Drive.")
        } catch {
            log(.error, error.localizedDescription)
        }
    }

    private func makeAppStoreConnectExport() -> AppStoreConnectExport? {
        do {
            guard !appStoreConnect.privateKeyPath.isEmpty else {
                log(.error, "No API private key")
                return nil
            }
            let pem = try String(contentsOf: URL(fileURLWithPath: appStoreConnect.privateKeyPath), encoding: .utf8)
            return AppStoreConnectExport(
                issuerID: appStoreConnect.issuerID,
                keyID: appStoreConnect.keyID,
                privateKeyPEM: pem,
                bundleIdentifierPrefix: appStoreConnect.bundleIdentifierPrefix,
                registerConnectedDevice: appStoreConnect.registerConnectedDevice
            )
        } catch {
            log(.error, error.localizedDescription)
            return nil
        }
    }

    private func writeSecureExport(_ export: AppStoreConnectExport, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(export)
        try FileManager.default.removeItemIfExists(at: url)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func importAppStoreConnectExport(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let imported = try JSONDecoder().decode(AppStoreConnectExport.self, from: data)
        // 先把 PEM 落到临时文件，再走统一的导入路径，托管与去重逻辑只有一份。
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeatherMac-ImportedKey-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let keyID = imported.keyID.trimmed.nonEmpty ?? "Imported"
        let staged = staging.appendingPathComponent("AuthKey_\(keyID).p8")
        try imported.privateKeyPEM.write(to: staged, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)

        appStoreConnect.bundleIdentifierPrefix = imported.bundleIdentifierPrefix
        appStoreConnect.registerConnectedDevice = imported.registerConnectedDevice
        try importASCKey(from: staged, issuerID: imported.issuerID, keyID: keyID)
    }

    func pickInjectionFiles() {
        let dylib = UTType(filenameExtension: "dylib")!
        let deb = UTType(filenameExtension: "deb")!
        let files = FilePicker.openMultiple(types: [dylib, deb])
        guard !files.isEmpty else { return }
        options.injectionFilePaths.append(contentsOf: files.map(\.path))
        saveAll()
    }

    func resetAll() {
        do {
            try storage.reset()
            sources = []
            repos = []
            library = []
            certificates = []
            options = SigningOptions()
            appStoreConnect = AppStoreConnectSettings()
            automation = AutomationPipeline()
            selectedAppID = nil
            selectedCertID = nil
            log(.success, "Reset complete.")
            Task { await bootstrap() }
        } catch {
            log(.error, error.localizedDescription)
        }
    }

    func runBusy(_ text: String, operation: @escaping () async throws -> Void) async {
        isBusy = true
        progressText = text
        do {
            try await operation()
        } catch {
            log(.error, error.localizedDescription)
        }
        progressText = ""
        isBusy = false
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("FeatherMac.language") private var language = AppLanguage.system.rawValue

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $store.pane) { pane in
                Label(L10n.string(pane.rawValue), systemImage: pane.icon)
                    .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            VStack(spacing: 0) {
                toolbar
                Divider()
                Group {
                    switch store.pane {
                    case .library: LibraryView()
                    case .sources: SourcesView()
                    case .certificates: CertificatesView()
                    case .signing: SigningView()
                    case .automation: AutomationView()
                    case .settings: SettingsView()
                    }
                }
                .overlay(alignment: .bottom) {
                    if store.isBusy {
                        BusyOverlay(text: store.progressText)
                            .padding(18)
                    }
                }
            }
        }
        .sheet(isPresented: $store.showAddSource) {
            AddSourceSheet()
        }
        // 向导可以从证书页横幅和自动配置页两处打开，所以挂在顶层。
        .sheet(isPresented: $store.showASCWizard) {
            ASCSetupWizardView()
        }
        .sheet(item: $store.createdCertificateReveal) { reveal in
            CreatedCertificateSheet(reveal: reveal)
        }
        .id(language)
        .environment(\.locale, AppLanguage(rawValue: language)?.locale ?? .autoupdatingCurrent)
    }

    private var toolbar: some View {
        HStack {
            Text(L10n.string(store.pane.rawValue))
                .font(.title2.weight(.semibold))
            Spacer()
            Button {
                Task { await store.pickAndImportIPA() }
            } label: {
                Label(L10n.string("Import"), systemImage: "square.and.arrow.down")
            }
            Button {
                Task { await store.refreshSources() }
            } label: {
                Label(L10n.string("Refresh"), systemImage: "arrow.clockwise")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

struct BusyOverlay: View {
    var text: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(text.isEmpty ? L10n.string("Working...") : L10n.string(text))
                .font(.callout)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 10)
    }
}

struct LibraryView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $store.selectedAppID) {
                    Section(L10n.string("Imported")) {
                        ForEach(store.library.filter { $0.kind == .imported }) { app in
                            LibraryRow(app: app).tag(app.id as UUID?)
                        }
                    }
                    Section(L10n.string("Signed")) {
                        ForEach(store.library.filter { $0.kind == .signed }) { app in
                            LibraryRow(app: app).tag(app.id as UUID?)
                        }
                    }
                }
            }
            .frame(minWidth: 360)

            VStack(alignment: .leading, spacing: 16) {
                if let app = store.selectedApp {
                    AppDetail(app: app)
                } else {
                    EmptyState(title: L10n.string("No app selected"), systemImage: "app.dashed")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(18)
        }
    }
}

struct LibraryRow: View {
    var app: LibraryApp

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(url: app.iconURL)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).lineLimit(1)
                Text("\(app.bundleIdentifier)  \(app.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

struct AppDetail: View {
    @EnvironmentObject private var store: AppStore
    var app: LibraryApp

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                AppIconView(url: app.iconURL)
                    .frame(width: 74, height: 74)
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name)
                        .font(.title2.weight(.semibold))
                    Text(app.bundleIdentifier)
                        .foregroundStyle(.secondary)
                    Text(L10n.format("Version %@", app.version))
                        .font(.callout)
                }
                Spacer()
            }

            HStack {
                Button {
                    store.pane = .signing
                } label: {
                    Label(L10n.string("Sign"), systemImage: "signature")
                }
                .buttonStyle(.borderedProminent)
                .disabled(app.kind != .imported)

                Button {
                    Task { await store.installSelectedApp() }
                } label: {
                    Label(L10n.string("Install"), systemImage: "iphone.and.arrow.forward")
                }
                .disabled(app.kind != .signed || app.ipaURL == nil)

                Button {
                    store.exportSelectedIPA()
                } label: {
                    Label(L10n.string("Export IPA"), systemImage: "square.and.arrow.up")
                }
                .disabled(app.ipaURL == nil)

                Button {
                    store.revealSelectedApp()
                } label: {
                    Label(L10n.string("Reveal"), systemImage: "finder")
                }

                Button(role: .destructive) {
                    store.deleteSelectedApp()
                } label: {
                    Label(L10n.string("Delete"), systemImage: "trash")
                }
            }

            InfoGrid(items: [
                ("Kind", L10n.string(app.kind.rawValue.capitalized)),
                ("Imported", app.importedAt.formatted(date: .abbreviated, time: .shortened)),
                ("Payload", app.storagePath),
                ("IPA", app.ipaPath ?? L10n.string("Not archived"))
            ])

            LogPanel()
        }
    }
}

struct SourcesView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedRepoID: UUID?
    @State private var searchText = ""

    private var selectedRepo: RepoCache? {
        store.repos.first { $0.id == selectedRepoID } ?? store.repos.first
    }

    private var apps: [ASRepository.App] {
        let allApps = selectedRepo?.repository?.apps ?? []
        guard !searchText.isEmpty else { return allApps }
        return allApps.filter {
            ($0.name ?? "").localizedCaseInsensitiveContains(searchText) ||
            ($0.developer ?? "").localizedCaseInsensitiveContains(searchText) ||
            ($0.id ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    private var packages: [APTPackage] {
        let allPackages = selectedRepo?.aptRepository?.packages ?? []
        guard !searchText.isEmpty else { return allPackages }
        return allPackages.filter {
            $0.packageIdentifier.localizedCaseInsensitiveContains(searchText) ||
            ($0.name ?? "").localizedCaseInsensitiveContains(searchText) ||
            ($0.summary ?? "").localizedCaseInsensitiveContains(searchText) ||
            ($0.description ?? "").localizedCaseInsensitiveContains(searchText) ||
            ($0.section ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Button {
                        store.showAddSource = true
                    } label: {
                        Label(L10n.string("Add"), systemImage: "plus")
                    }
                    Button {
                        Task { await store.refreshSources() }
                    } label: {
                        Label(L10n.string("Refresh"), systemImage: "arrow.clockwise")
                    }
                }
                .padding(10)
                List(selection: $selectedRepoID) {
                    ForEach(store.repos) { cache in
                        SourceRow(cache: cache)
                            .tag(cache.id as UUID?)
                            .contextMenu {
                                Button(role: .destructive) {
                                    store.deleteSource(cache.source)
                                } label: {
                                    Label(L10n.string("Delete"), systemImage: "trash")
                                }
                            }
                    }
                }
            }
            .frame(minWidth: 300)

            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass")
                    TextField(L10n.string("Search apps"), text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .padding(12)

                if let error = selectedRepo?.error {
                    EmptyState(title: error, systemImage: "exclamationmark.triangle")
                } else if selectedRepo?.aptRepository != nil {
                    if packages.isEmpty {
                        EmptyState(title: L10n.string("No packages"), systemImage: "shippingbox")
                    } else {
                        List(packages) { package in
                            APTPackageRow(package: package)
                        }
                    }
                } else if apps.isEmpty {
                    EmptyState(title: L10n.string("No apps"), systemImage: "tray")
                } else {
                    List(apps, id: \.stableID) { app in
                        SourceAppRow(app: app)
                    }
                }
            }
            .frame(minWidth: 520)
        }
        .onAppear {
            selectedRepoID = selectedRepoID ?? store.repos.first?.id
        }
    }
}

struct SourceRow: View {
    var cache: RepoCache

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(cache.repository?.name ?? cache.source.name)
                .font(.headline)
                .lineLimit(1)
            Text(cache.source.url.absoluteString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let error = cache.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else if let count = cache.repository?.apps.count {
                Text("\(count) \(L10n.string("apps"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let count = cache.aptRepository?.packages.count {
                Text("\(count) \(L10n.string("packages"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(L10n.string("Loading"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
    }
}

struct APTPackageRow: View {
    var package: APTPackage

    private var title: String {
        package.name?.nonEmpty ?? package.packageIdentifier
    }

    private var subtitle: String {
        package.summary?.nonEmpty ?? package.description?.lines.first ?? package.packageIdentifier
    }

    private var detail: String {
        [
            package.version.map { L10n.format("Version %@", $0) },
            package.section,
            package.architecture
        ].compactMap { $0?.nonEmpty }.joined(separator: "  ")
    }

    var body: some View {
        HStack(spacing: 12) {
            RemoteIcon(url: package.iconURL)
                .frame(width: 48, height: 48)
                .overlay {
                    if package.iconURL == nil {
                        Image(systemName: "shippingbox")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(package.packageIdentifier)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Text(L10n.string("APT Package"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

struct SourceAppRow: View {
    @EnvironmentObject private var store: AppStore
    var app: ASRepository.App

    var body: some View {
        HStack(spacing: 12) {
            RemoteIcon(url: app.iconURL)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name ?? app.id ?? L10n.string("Unknown"))
                    .font(.headline)
                    .lineLimit(1)
                Text(app.subtitle ?? app.developer ?? app.localizedDescription ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(L10n.format("Version %@", app.bestVersion))  \(app.sizeText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await store.downloadAndImport(app) }
            } label: {
                Label(L10n.string("Download"), systemImage: "arrow.down.circle")
            }
            .disabled(app.bestDownloadURL == nil)
        }
        .padding(.vertical, 6)
    }
}

struct CertificatesView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                // 未配置或校验失败时才出现；配置成功后自动消失，不做常驻绿条。
                if !store.credentialState.canCreateCertificate {
                    CredentialBanner()
                }

                Text(L10n.string("Import Certificate"))
                    .font(.headline)
                SecureField(L10n.string("P12 password"), text: $store.certificatePasswordDraft)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await store.pickCertificateFiles() }
                } label: {
                    Label(L10n.string("Choose .p12"), systemImage: "person.badge.key")
                }
                .buttonStyle(.borderedProminent)

                Divider()

                CreateCertificateSection()

                Divider()

                List(selection: $store.selectedCertID) {
                    ForEach(store.certificates) { cert in
                        CertificateRow(cert: cert)
                            .tag(cert.id as UUID?)
                            .contextMenu {
                                Button {
                                    store.setDefaultCertificate(cert)
                                } label: {
                                    Label(L10n.string("Set Default"), systemImage: "checkmark.seal")
                                }
                                Button(role: .destructive) {
                                    store.deleteCertificate(cert)
                                } label: {
                                    Label(L10n.string("Delete"), systemImage: "trash")
                                }
                            }
                    }
                }
            }
            .padding(18)
            .frame(minWidth: 380)

            if let cert = store.selectedCert {
                CertificateDetailView(cert: cert)
            } else {
                EmptyState(title: L10n.string("No certificate imported"), systemImage: "person.text.rectangle")
            }
        }
        .task {
            await store.refreshPortalStatus()
        }
    }
}

/// 凭据状态横幅。禁用创建按钮时说明原因，不做点了才弹错。
struct CredentialBanner: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isInvalid ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isInvalid ? .red : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string(isInvalid ? "App Store Connect credentials are not working" : "App Store Connect API is not configured"))
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(L10n.string(isInvalid ? "Reconfigure…" : "Set Up…")) {
                store.showASCWizard = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(11)
        .background((isInvalid ? Color.red : Color.orange).opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private var isInvalid: Bool {
        if case .invalid = store.credentialState { return true }
        return false
    }

    private var detail: String {
        if case .invalid(let message) = store.credentialState { return message }
        return L10n.string("Configure it to create certificates and provisioning profiles inside FeatherMac.")
    }
}

/// 功能 B：一键申请开发证书。
struct CreateCertificateSection: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L10n.string("Create Certificate"))
                .font(.headline)

            Picker(L10n.string("Certificate type"), selection: $store.newCertificateType) {
                ForEach(DeveloperCertificateType.allCases) { type in
                    Text(type.title).tag(type)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.string("P12 password")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField(L10n.string("Generated automatically"), text: $store.newCertificatePasswordDraft)
                        .textFieldStyle(.roundedBorder)
                    Button(L10n.string("Generate")) { store.generateNewCertificatePassword() }
                }
            }

            HStack(spacing: 9) {
                Button {
                    Task { await store.createCertificate() }
                } label: {
                    Label(L10n.string("Create Certificate"), systemImage: "plus.seal")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.credentialState.canCreateCertificate || store.isBusy)

                if !store.credentialState.canCreateCertificate {
                    Text(L10n.string("Configure the API first"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct CertificateDetailView: View {
    @EnvironmentObject private var store: AppStore
    var cert: CertificateRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(cert.nickname)
                .font(.title2.weight(.semibold))

            if isExpired {
                Callout(
                    systemImage: "exclamationmark.triangle",
                    text: L10n.format(
                        "This certificate expired on %@. Signing will fail. Create a replacement development certificate.",
                        cert.expiration?.formatted(date: .abbreviated, time: .omitted) ?? ""
                    ),
                    tint: .red
                )
            }

            InfoGrid(items: [
                ("Default", cert.isDefault ? L10n.string("Yes") : L10n.string("No")),
                ("Team", cert.teamName ?? L10n.string("Unknown")),
                ("Expiration", cert.expiration?.formatted(date: .abbreviated, time: .omitted) ?? L10n.string("Unknown")),
                ("Serial", cert.p12SerialNumber ?? L10n.string("Unknown")),
                ("Account status", portalStatusText),
                ("P12", cert.p12Path)
            ])

            HStack {
                if isExpired {
                    Button {
                        Task { await store.renewCertificate(cert) }
                    } label: {
                        Label(L10n.string("Renew Now"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.credentialState.canCreateCertificate || store.isBusy)
                }
                Button {
                    store.setDefaultCertificate(cert)
                } label: {
                    Label(L10n.string("Set Default"), systemImage: "checkmark.seal")
                }
                // 只有确认还在门户里的开发证书才给吊销入口。
                if store.portalStatus(for: cert) == true {
                    Button {
                        Task { await store.revokePortalCertificate(matching: cert) }
                    } label: {
                        Label(L10n.string("Revoke in Portal…"), systemImage: "xmark.seal")
                    }
                    .disabled(store.isBusy)
                }
                Button(role: .destructive) {
                    store.deleteCertificate(cert)
                } label: {
                    Label(L10n.string("Delete"), systemImage: "trash")
                }
            }

            Spacer()
            LogPanel()
        }
        .padding(18)
    }

    private var isExpired: Bool {
        guard let expiration = cert.expiration else { return false }
        return expiration < Date()
    }

    private var portalStatusText: String {
        switch store.portalStatus(for: cert) {
        case true?: L10n.string("Matches your account")
        case false?: L10n.string("No longer in your account")
        case nil: L10n.string("Not verified")
        }
    }
}

/// 创建成功后的一次性展示。密码存在钥匙串里，所以文案告诉用户去哪儿找回，
/// 而不是让人以为错过这一眼就永远拿不到了。
struct CreatedCertificateSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var reveal: CreatedCertificateReveal

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Callout(
                systemImage: "checkmark.seal.fill",
                text: L10n.format(
                    "%@ · serial %@ · valid until %@",
                    reveal.nickname,
                    reveal.serialNumber ?? L10n.string("Unknown"),
                    reveal.expiration?.formatted(date: .abbreviated, time: .omitted) ?? L10n.string("Unknown")
                ),
                tint: .green
            )

            VStack(alignment: .leading, spacing: 7) {
                Text(L10n.string("P12 password")).font(.headline)
                HStack {
                    Text(reveal.password)
                        .font(.system(.title3, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button(L10n.string("Copy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(reveal.password, forType: .string)
                    }
                }
                .padding(10)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                Text(L10n.string("Use this password to export the certificate or open it in other tools. It has been saved to your keychain — look it up in Keychain Access under “FeatherMac” if you need it again."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(L10n.string("Set as Default")) {
                    if let cert = store.certificates.first(where: { $0.id == reveal.certificateID }) {
                        store.setDefaultCertificate(cert)
                    }
                    dismiss()
                }
                Button(L10n.string("Done")) { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

struct CertificateRow: View {
    var cert: CertificateRecord

    var body: some View {
        HStack {
            Image(systemName: cert.isDefault ? "checkmark.seal.fill" : "person.text.rectangle")
                .foregroundStyle(cert.isDefault ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(cert.nickname)
                Text(cert.expiration?.formatted(date: .abbreviated, time: .omitted) ?? L10n.string("Unknown expiration"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct SigningView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Picker(L10n.string("App"), selection: $store.selectedAppID) {
                        Text(L10n.string("Select app")).tag(nil as UUID?)
                        ForEach(store.library.filter { $0.kind == .imported }) { app in
                            Text(app.name).tag(app.id as UUID?)
                        }
                    }
                    Picker(L10n.string("Certificate"), selection: $store.selectedCertID) {
                        Text(L10n.string("None")).tag(nil as UUID?)
                        ForEach(store.certificates) { cert in
                            Text(cert.nickname).tag(cert.id as UUID?)
                        }
                    }
                    Button {
                        Task { await store.signSelectedApp() }
                    } label: {
                        Label(L10n.string("Start Signing"), systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }

                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                    GridRow {
                        Field("App Name", text: $store.options.appName)
                        Field("Bundle ID", text: $store.options.appIdentifier)
                    }
                    GridRow {
                        Field("Version", text: $store.options.appVersion)
                        Picker(L10n.string("Signing Type"), selection: $store.options.signingMode) {
                            ForEach(SigningOptions.SigningMode.allCases) { mode in
                                Text(L10n.string(mode.rawValue)).tag(mode)
                            }
                        }
                    }
                    GridRow {
                        Picker(L10n.string("Appearance"), selection: $store.options.appearance) {
                            ForEach(SigningOptions.Appearance.allCases) { item in
                                Text(L10n.string(item.rawValue)).tag(item)
                            }
                        }
                        Picker(L10n.string("Minimum iOS"), selection: $store.options.minimumOS) {
                            ForEach(SigningOptions.MinimumOS.allCases) { item in
                                Text(L10n.string(item.rawValue)).tag(item)
                            }
                        }
                    }
                }
                .onChange(of: store.options) { _, _ in store.saveAll() }

                OptionSection(title: "Files") {
                    HStack {
                        Text(store.selectedProvisionURL()?.path ?? L10n.string("No provisioning profile"))
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            store.pickProvisioningProfile()
                        } label: {
                            Label(L10n.string("Provisioning Profile"), systemImage: "doc.badge.gearshape")
                        }
                    }
                    HStack {
                        Text(store.options.entitlementsPath.isEmpty ? L10n.string("No entitlements file") : store.options.entitlementsPath)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            store.pickEntitlements()
                        } label: {
                            Label(L10n.string("Entitlements"), systemImage: "doc.badge.gearshape")
                        }
                    }
                    HStack {
                        Text(store.options.iconPath.isEmpty ? L10n.string("No replacement icon") : store.options.iconPath)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            store.pickIcon()
                        } label: {
                            Label(L10n.string("Icon"), systemImage: "photo")
                        }
                    }
                }

                OptionSection(title: "Info.plist Modifications") {
                    Toggle(L10n.string("File sharing"), isOn: $store.options.fileSharing)
                    Toggle(L10n.string("iTunes file sharing"), isOn: $store.options.iTunesFileSharing)
                    Toggle(L10n.string("ProMotion"), isOn: $store.options.proMotion)
                    Toggle(L10n.string("Game Mode"), isOn: $store.options.gameMode)
                    Toggle(L10n.string("iPad full screen"), isOn: $store.options.iPadFullscreen)
                    Toggle(L10n.string("Remove URL schemes"), isOn: $store.options.removeURLScheme)
                    Toggle(L10n.string("Remove provisioning after signing"), isOn: $store.options.removeProvisioning)
                    Toggle(L10n.string("Rename localized app names"), isOn: $store.options.changeLanguageFilesForCustomDisplayName)
                    Toggle(L10n.string("Liquid Glass compatibility patch"), isOn: $store.options.supportLiquidGlass)
                }

                OptionSection(title: "Protection") {
                    HStack {
                        Toggle(L10n.string("PPQ protection"), isOn: $store.options.ppqProtection)
                        Toggle(L10n.string("Dynamic protection"), isOn: $store.options.dynamicProtection)
                        Field("Suffix", text: $store.options.ppqString)
                    }
                }

                OptionSection(title: "Tweaks and Dylibs") {
                    HStack {
                        Picker(L10n.string("Load Path"), selection: $store.options.injectPath) {
                            ForEach(SigningOptions.InjectPath.allCases) { item in
                                Text(item.rawValue).tag(item)
                            }
                        }
                        Picker(L10n.string("Folder"), selection: $store.options.injectFolder) {
                            ForEach(SigningOptions.InjectFolder.allCases) { item in
                                Text(L10n.string(item.rawValue)).tag(item)
                            }
                        }
                        Toggle(L10n.string("Inject extensions"), isOn: $store.options.injectIntoExtensions)
                    }
                    Toggle(L10n.string("Replace Substrate with ElleKit"), isOn: $store.options.replaceSubstrateWithElleKit)
                    HStack {
                        Button {
                            store.pickInjectionFiles()
                        } label: {
                            Label(L10n.string("Add .dylib/.deb"), systemImage: "plus")
                        }
                        Button(role: .destructive) {
                            store.options.injectionFilePaths = []
                            store.saveAll()
                        } label: {
                            Label(L10n.string("Clear"), systemImage: "trash")
                        }
                    }
                    ForEach(store.options.injectionFilePaths, id: \.self) { path in
                        Text(path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                OptionSection(title: "Rules") {
                    TextEditor(text: $store.options.identifierRules)
                        .frame(height: 72)
                        .overlay(alignment: .topLeading) {
                            if store.options.identifierRules.isEmpty {
                                Text(L10n.string("Identifier replacements: old = new"))
                                    .foregroundStyle(.tertiary)
                                    .padding(7)
                            }
                        }
                    TextEditor(text: $store.options.displayNameRules)
                        .frame(height: 72)
                        .overlay(alignment: .topLeading) {
                            if store.options.displayNameRules.isEmpty {
                                Text(L10n.string("Display name replacements: old = new"))
                                    .foregroundStyle(.tertiary)
                                    .padding(7)
                            }
                        }
                    TextEditor(text: $store.options.removeFileRules)
                        .frame(height: 72)
                        .overlay(alignment: .topLeading) {
                            if store.options.removeFileRules.isEmpty {
                                Text(L10n.string("Files to remove, one relative path per line"))
                                    .foregroundStyle(.tertiary)
                                    .padding(7)
                            }
                        }
                    TextEditor(text: $store.options.disinjectLoadCommands)
                        .frame(height: 72)
                        .overlay(alignment: .topLeading) {
                            if store.options.disinjectLoadCommands.isEmpty {
                                Text(L10n.string("Load commands to remove, one per line"))
                                    .foregroundStyle(.tertiary)
                                    .padding(7)
                            }
                        }
                }

                OptionSection(title: "Post Signing") {
                    Toggle(L10n.string("Install after signing"), isOn: $store.options.installAfterSigning)
                    Toggle(L10n.string("Delete imported app after signing"), isOn: $store.options.deleteAfterSigning)
                    Stepper(L10n.format("ZIP compression level %lld", store.options.zipCompressionLevel), value: $store.options.zipCompressionLevel, in: 0...9)
                }
            }
            .padding(18)
        }
    }
}

struct AutomationView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                OptionSection(title: "Workflow") {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                        GridRow {
                            Picker(L10n.string("Imported IPA"), selection: $store.automation.appID) {
                                Text(L10n.string("Select app")).tag(nil as UUID?)
                                ForEach(store.library.filter { $0.kind == .imported }) { app in
                                    Text("\(app.name)  \(app.bundleIdentifier)").tag(app.id as UUID?)
                                }
                            }
                            Picker(L10n.string("Certificate"), selection: $store.automation.certificateID) {
                                Text(L10n.string("None")).tag(nil as UUID?)
                                ForEach(store.certificates) { cert in
                                    Text(cert.nickname).tag(cert.id as UUID?)
                                }
                            }
                        }
                        GridRow {
                            Field("Bundle Prefix", text: $store.appStoreConnect.bundleIdentifierPrefix)
                            Toggle(L10n.string("Install after workflow"), isOn: $store.automation.installAfterSigning)
                        }
                        GridRow {
                            Field("App Name", text: $store.automation.appName)
                        }
                    }
                    .onChange(of: store.automation) { _, _ in store.saveAll() }
                    .onChange(of: store.appStoreConnect) { _, _ in
                        // 凭据改了，之前的校验结论作废。
                        store.invalidateCredentialVerification()
                        store.saveAll()
                    }

                    InfoGrid(items: [
                        ("Suggested Bundle ID", BundleIdentifierGenerator.suggestedIdentifier(
                            app: store.automationApp,
                            certificate: store.automationCertificate,
                            configuredPrefix: store.appStoreConnect.bundleIdentifierPrefix
                        )),
                        ("Last Signed IPA", store.automationLastSignedApp?.ipaPath ?? L10n.string("Not archived"))
                    ])

                    HStack {
                        Button {
                            Task { await store.runAutomationPipeline() }
                        } label: {
                            Label(L10n.string("Run Workflow"), systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.automationApp == nil || store.automationCertificate == nil)

                        Button {
                            Task { await store.installAutomationResult() }
                        } label: {
                            Label(L10n.string("Install Result"), systemImage: "iphone.and.arrow.forward")
                        }
                        .disabled(store.automationLastSignedApp == nil)
                    }

                    WorkflowStepsView()
                }

                OptionSection(title: "Icon Replacement") {
                    HStack {
                        Text(store.automation.iconPath.isEmpty ? L10n.string("Keep original icon") : store.automation.iconPath)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            store.pickAutomationIcon()
                        } label: {
                            Label(L10n.string("Choose Icon"), systemImage: "photo")
                        }
                        Button(role: .destructive) {
                            store.automation.iconPath = ""
                            store.saveAll()
                        } label: {
                            Label(L10n.string("Clear"), systemImage: "trash")
                        }
                    }
                }

                OptionSection(title: "App Store Connect API") {
                    HStack(spacing: 9) {
                        Text(L10n.string("API Keys"))
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                    }
                    // Issuer ID / Key ID 不再是自由输入框：它们属于某一把密钥，
                    // 由向导写入，手改只会让文件名与内容对不上。
                    ASCKeyListSection()
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                        GridRow {
                            Field("Bundle Prefix", text: $store.appStoreConnect.bundleIdentifierPrefix)
                            Toggle(L10n.string("Register connected device"), isOn: $store.appStoreConnect.registerConnectedDevice)
                        }
                    }
                    .onChange(of: store.appStoreConnect) { _, _ in
                        // 凭据改了，之前的校验结论作废。
                        store.invalidateCredentialVerification()
                        store.saveAll()
                    }
                    Text(L10n.string("The API key is used to create Bundle IDs, register the connected device, and download development provisioning profiles."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button {
                            store.exportAppStoreConnectConfig()
                        } label: {
                            Label(L10n.string("Export Config"), systemImage: "square.and.arrow.up")
                        }
                        Button {
                            store.importAppStoreConnectConfig()
                        } label: {
                            Label(L10n.string("Import Config"), systemImage: "square.and.arrow.down")
                        }
                        Button {
                            store.syncAppStoreConnectConfigToICloud()
                        } label: {
                            Label(L10n.string("Sync to iCloud"), systemImage: "icloud.and.arrow.up")
                        }
                        Button {
                            store.restoreAppStoreConnectConfigFromICloud()
                        } label: {
                            Label(L10n.string("Restore from iCloud"), systemImage: "icloud.and.arrow.down")
                        }
                    }
                }

                LogPanel()
            }
            .padding(18)
        }
    }
}

struct WorkflowStepsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AutomationPipeline.Step.allCases) { step in
                HStack(spacing: 6) {
                    Image(systemName: icon(for: step))
                        .foregroundStyle(color(for: step))
                    Text(L10n.string(step.rawValue))
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func icon(for step: AutomationPipeline.Step) -> String {
        if store.automation.activeStep == step {
            return "arrow.triangle.2.circlepath"
        }
        if store.automation.completedSteps.contains(step) {
            return "checkmark.circle.fill"
        }
        return "circle"
    }

    private func color(for step: AutomationPipeline.Step) -> Color {
        if store.automation.activeStep == step {
            return .accentColor
        }
        if store.automation.completedSteps.contains(step) {
            return .green
        }
        return .secondary
    }
}

struct Field: View {
    var title: String
    @Binding var text: String

    init(_ title: String, text: Binding<String>) {
        self.title = title
        self._text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.string(title)).font(.caption).foregroundStyle(.secondary)
            TextField(L10n.string(title), text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

struct OptionSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string(title))
                .font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(12)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("FeatherMac.language") private var language = AppLanguage.system.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker(L10n.string("Language"), selection: $language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.title).tag(language.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 360)

            InfoGrid(items: [
                ("Data", store.storage.root.path),
                ("ideviceinstaller", InstallService.toolPath("ideviceinstaller") ?? L10n.string("Not installed")),
                ("ios-deploy", InstallService.toolPath("ios-deploy") ?? L10n.string("Not installed")),
                ("zip", InstallService.toolPath("zip") ?? L10n.string("Not installed")),
                ("unzip", InstallService.toolPath("unzip") ?? L10n.string("Not installed"))
            ])

            HStack {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([store.storage.root])
                } label: {
                    Label(L10n.string("Reveal Data"), systemImage: "folder")
                }
                Button(role: .destructive) {
                    store.resetAll()
                } label: {
                    Label(L10n.string("Reset FeatherMac"), systemImage: "trash")
                }
            }

            LogPanel()
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans
    case english

    var id: String { rawValue }

    static var current: AppLanguage {
        let value = UserDefaults.standard.string(forKey: "FeatherMac.language") ?? AppLanguage.system.rawValue
        return AppLanguage(rawValue: value) ?? .system
    }

    var title: String {
        switch self {
        case .system: L10n.string("Follow System")
        case .zhHans: "中文"
        case .english: L10n.string("English")
        }
    }

    var localization: String? {
        switch self {
        case .system: nil
        case .zhHans: "zh-hans"
        case .english: "en"
        }
    }

    var locale: Locale {
        switch self {
        case .system: .autoupdatingCurrent
        case .zhHans: Locale(identifier: "zh-Hans")
        case .english: Locale(identifier: "en")
        }
    }
}

struct AddSourceSheet: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("Add Source"))
                .font(.title2.weight(.semibold))
            TextField(L10n.string("https://example.com/source.json"), text: $store.sourceURLDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 480)
            HStack {
                Spacer()
                Button(L10n.string("Cancel")) {
                    store.showAddSource = false
                }
                Button(L10n.string("Add")) {
                    Task { await store.addSource() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }
}

struct InfoGrid: View {
    var items: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            ForEach(items, id: \.0) { item in
                GridRow {
                    Text(L10n.string(item.0))
                        .foregroundStyle(.secondary)
                    Text(item.1)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }
        }
        .font(.callout)
    }
}

struct LogPanel: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("Activity"))
                .font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(store.logs) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(L10n.string(entry.level.rawValue))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(color(for: entry.level))
                                .frame(width: 54, alignment: .leading)
                            Text(L10n.string(entry.message))
                                .font(.caption)
                                .textSelection(.enabled)
                            Spacer()
                        }
                    }
                }
                .padding(10)
            }
            .frame(minHeight: 160)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .info: .secondary
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

struct EmptyState: View {
    var title: String
    var systemImage: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(L10n.string(title))
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AppIconView: View {
    var url: URL?

    var body: some View {
        Group {
            if let url, let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "app")
                    .resizable()
                    .scaledToFit()
                    .padding(8)
                    .foregroundStyle(.secondary)
            }
        }
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct RemoteIcon: View {
    var url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit()
            default:
                Image(systemName: "app").resizable().scaledToFit().padding(8).foregroundStyle(.secondary)
            }
        }
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

final class FeatherStorage: @unchecked Sendable {
    let root: URL
    let importsDirectory: URL
    let signedDirectory: URL
    let certificatesDirectory: URL
    let downloadsDirectory: URL

    private let sourcesFile: URL
    private let libraryFile: URL
    private let certificatesFile: URL
    private let optionsFile: URL
    private let appStoreConnectFile: URL
    private let automationFile: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        root = appSupport.appendingPathComponent("FeatherMac", isDirectory: true)
        importsDirectory = root.appendingPathComponent("Imported", isDirectory: true)
        signedDirectory = root.appendingPathComponent("Signed", isDirectory: true)
        certificatesDirectory = root.appendingPathComponent("Certificates", isDirectory: true)
        downloadsDirectory = root.appendingPathComponent("Downloads", isDirectory: true)
        sourcesFile = root.appendingPathComponent("sources.json")
        libraryFile = root.appendingPathComponent("library.json")
        certificatesFile = root.appendingPathComponent("certificates.json")
        optionsFile = root.appendingPathComponent("options.json")
        appStoreConnectFile = root.appendingPathComponent("appstoreconnect.json")
        automationFile = root.appendingPathComponent("automation.json")
    }

    func prepare() throws {
        for directory in [root, importsDirectory, signedDirectory, certificatesDirectory, downloadsDirectory] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // createDirectory 的 attributes 只作用于新建的目录，已存在的旧目录（早期版本建的 0755）
            // 必须显式收紧，否则同机其他用户可以读到 certificates.json 里的 p12 密码。
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        hardenExistingFiles()
    }

    /// 把历史遗留的 0644 配置文件与 0755 证书目录收紧（一次性迁移，幂等）。
    private func hardenExistingFiles() {
        for file in [sourcesFile, libraryFile, certificatesFile, optionsFile, appStoreConnectFile, automationFile] {
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        // 存 .p8 的目录，旧版本的导入路径建的是 0755。
        let ascKeyDirectory = root.appendingPathComponent("AppStoreConnect", isDirectory: true)
        if FileManager.default.fileExists(atPath: ascKeyDirectory.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ascKeyDirectory.path)
            let keys = (try? FileManager.default.contentsOfDirectory(at: ascKeyDirectory, includingPropertiesForKeys: nil)) ?? []
            for key in keys {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
            }
        }
        // 每张证书一个子目录，旧版本建的是 0755。
        harden(directory: certificatesDirectory)
    }

    /// 递归收紧：目录 0700、文件 0600。
    ///
    /// 目录必须保留执行位——0600 的目录连自己都进不去，证书目录下的 `AutoProfiles`
    /// 被这么设过一次，结果描述文件写不进去，报的还是含糊的 "You don't have permission"。
    private func harden(directory: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        for item in contents {
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            try? FileManager.default.setAttributes(
                [.posixPermissions: isDirectory ? 0o700 : 0o600],
                ofItemAtPath: item.path
            )
            if isDirectory {
                harden(directory: item)
            }
        }
    }

    func reset() throws {
        try FileManager.default.removeItemIfExists(at: root)
        try prepare()
    }

    func loadSources() throws -> [SourceRecord] { try load([SourceRecord].self, from: sourcesFile, default: []) }
    func saveSources(_ value: [SourceRecord]) throws { try save(value, to: sourcesFile) }
    func loadLibrary() throws -> [LibraryApp] { try load([LibraryApp].self, from: libraryFile, default: []) }
    func saveLibrary(_ value: [LibraryApp]) throws { try save(value, to: libraryFile) }
    /// 读出记录后从钥匙串补回密码。取不到就留空，由签名前的检查给出可操作的报错，
    /// 而不是拿空密码去调 openssl 报一句看不懂的话。
    func loadCertificates() throws -> [CertificateRecord] {
        var records = try load([CertificateRecord].self, from: certificatesFile, default: [])
        for index in records.indices {
            records[index].password = (try? KeychainStore.password(for: records[index].id)) ?? ""
        }
        return records
    }

    /// 密码写钥匙串，其余字段写 JSON。
    func saveCertificates(_ value: [CertificateRecord]) throws {
        for record in value where !record.password.isEmpty {
            try KeychainStore.save(password: record.password, for: record.id)
        }
        try save(value, to: certificatesFile)
    }
    func loadOptions() throws -> SigningOptions { try load(SigningOptions.self, from: optionsFile, default: SigningOptions()) }
    func saveOptions(_ value: SigningOptions) throws { try save(value, to: optionsFile) }
    func loadAppStoreConnectSettings() throws -> AppStoreConnectSettings { try load(AppStoreConnectSettings.self, from: appStoreConnectFile, default: AppStoreConnectSettings()) }
    func saveAppStoreConnectSettings(_ value: AppStoreConnectSettings) throws { try save(value, to: appStoreConnectFile) }
    func loadAutomationPipeline() throws -> AutomationPipeline { try load(AutomationPipeline.self, from: automationFile, default: AutomationPipeline()) }
    func saveAutomationPipeline(_ value: AutomationPipeline) throws { try save(value, to: automationFile) }

    func iCloudConfigURL() throws -> URL {
        let directory: URL
        if let ubiquity = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            directory = ubiquity.appendingPathComponent("Documents/FeatherMac", isDirectory: true)
        } else {
            let fallback = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/FeatherMac", isDirectory: true)
            directory = fallback
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("AppStoreConnect.feathermacconfig")
    }

    private func load<T: Decodable>(_ type: T.Type, from url: URL, default defaultValue: T) throws -> T {
        guard FileManager.default.fileExists(atPath: url.path) else { return defaultValue }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
        // 原子写入会用临时文件替换目标，权限随之重置，所以每次写完都要重新收紧。
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

final class SourceService: @unchecked Sendable {
    enum FetchedSource {
        case altSource(ASRepository)
        case apt(APTRepository)
    }

    static let defaultSources: [SourceRecord] = [
        SourceRecord(url: URL(string: "https://cdn.altstore.io/file/altstore/apps.json")!, name: "AltStore"),
        SourceRecord(url: URL(string: "https://sidestore.io/apps.json")!, name: "SideStore"),
        SourceRecord(url: URL(string: "https://raw.githubusercontent.com/claration/Feather/refs/heads/main/app-repo.json")!, name: "Feather"),
        SourceRecord(url: URL(string: "https://ish.app/altstore.json")!, name: "iSH"),
        SourceRecord(url: URL(string: "https://alt.getutm.app")!, name: "UTM")
    ]

    private static let retiredDefaultSourceURLs: Set<String> = [
        "https://raw.githubusercontent.com/SideStore/apps.json/refs/heads/main/apps.json",
        "https://raw.githubusercontent.com/altstoreio/AltStore/refs/heads/master/apps.json",
        "https://apps.altstore.io"
    ]

    static func sanitizedSources(_ existing: [SourceRecord]) -> [SourceRecord] {
        var result: [SourceRecord] = []
        var seen = Set<String>()

        for source in existing where !retiredDefaultSourceURLs.contains(source.url.absoluteString) {
            guard seen.insert(source.url.absoluteString).inserted else { continue }
            result.append(source)
        }

        for source in defaultSources where seen.insert(source.url.absoluteString).inserted {
            result.append(source)
        }

        return result
    }

    func fetchSource(url: URL) async throws -> FetchedSource {
        do {
            return .altSource(try await fetch(url: url))
        } catch {
            do {
                return .apt(try await fetchAPT(url: url))
            } catch {
                throw FeatherError.message(L10n.string("Source is not a supported AltSource or APT repository."))
            }
        }
    }

    func fetch(url: URL) async throws -> ASRepository {
        let data = try await fetchData(url: url)
        return try JSONDecoder.altSource.decode(ASRepository.self, from: data)
    }

    func download(url: URL, to directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw FeatherError.message("HTTP \(http.statusCode) for \(url.absoluteString)")
        }
        let filename = response.suggestedFilename ?? url.lastPathComponent.nonEmpty ?? "download.ipa"
        let destination = directory.appendingPathComponent(filename)
        try FileManager.default.removeItemIfExists(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }

    func fetchAPT(url: URL) async throws -> APTRepository {
        var failures: [String] = []
        for candidate in aptPackageCandidates(for: url) {
            do {
                let data = try await fetchData(url: candidate)
                let packageData = try decompressAPTData(data, from: candidate)
                guard let text = String(data: packageData, encoding: .utf8) else {
                    throw FeatherError.message("APT Packages file is not UTF-8.")
                }
                let baseURL = aptRepositoryBaseURL(sourceURL: url, packageURL: candidate)
                let packages = Self.parsePackages(text, baseURL: baseURL)
                guard !packages.isEmpty else {
                    throw FeatherError.message("APT Packages file did not contain packages.")
                }
                return APTRepository(
                    name: aptRepositoryName(from: url),
                    packages: packages.sorted { ($0.name ?? $0.packageIdentifier) < ($1.name ?? $1.packageIdentifier) }
                )
            } catch {
                failures.append("\(candidate.absoluteString): \(error.localizedDescription)")
            }
        }
        throw FeatherError.message(failures.last ?? "No APT Packages file was found.")
    }

    static func parsePackages(_ text: String, baseURL: URL) -> [APTPackage] {
        var packages: [APTPackage] = []
        var fields: [String: String] = [:]
        var currentField: String?
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")

        func commitPackage() {
            guard let identifier = fields["Package"]?.trimmed.nonEmpty else {
                fields = [:]
                currentField = nil
                return
            }
            let filename = fields["Filename"]?.trimmed.nonEmpty
            let package = APTPackage(
                packageIdentifier: identifier,
                name: fields["Name"]?.trimmed.nonEmpty,
                version: fields["Version"]?.trimmed.nonEmpty,
                section: fields["Section"]?.trimmed.nonEmpty,
                architecture: fields["Architecture"]?.trimmed.nonEmpty,
                maintainer: fields["Maintainer"]?.trimmed.nonEmpty,
                author: fields["Author"]?.trimmed.nonEmpty,
                summary: fields["Description"]?.split(separator: "\n", maxSplits: 1).first.map { String($0).trimmed }.flatMap(\.nonEmpty),
                description: fields["Description"]?.trimmed.nonEmpty,
                filename: filename,
                size: fields["Size"].flatMap { Int64($0.trimmed) },
                depictionURL: fields["Depiction"].flatMap { URL(string: $0.trimmed) },
                iconURL: fields["Icon"].flatMap { URL(string: $0.trimmed) },
                downloadURL: filename.flatMap { packageDownloadURL(filename: $0, baseURL: baseURL) }
            )
            packages.append(package)
            fields = [:]
            currentField = nil
        }

        for line in normalized.components(separatedBy: "\n") + [""] {
            if line.trimmed.isEmpty {
                commitPackage()
                continue
            }
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                guard let currentField else { continue }
                fields[currentField, default: ""] += "\n" + line.trimmed
                continue
            }
            let pieces = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { continue }
            currentField = pieces[0]
            fields[pieces[0]] = pieces[1].trimmed
        }

        return packages
    }

    private func fetchData(url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw FeatherError.message("HTTP \(http.statusCode) for \(url.absoluteString)")
        }
        return data
    }

    private func aptPackageCandidates(for url: URL) -> [URL] {
        let lowercasedPath = url.path.lowercased()
        if lowercasedPath.hasSuffix("/packages") ||
            lowercasedPath.hasSuffix("/packages.gz") ||
            lowercasedPath.hasSuffix("/packages.bz2") {
            return [url]
        }

        return [
            url.appendingPathComponent("Packages"),
            url.appendingPathComponent("Packages.gz"),
            url.appendingPathComponent("Packages.bz2"),
            url.appendingPathComponent("dists/stable/main/binary-iphoneos-arm/Packages"),
            url.appendingPathComponent("dists/stable/main/binary-iphoneos-arm/Packages.gz"),
            url.appendingPathComponent("dists/stable/main/binary-iphoneos-arm/Packages.bz2")
        ]
    }

    private func decompressAPTData(_ data: Data, from url: URL) throws -> Data {
        switch url.pathExtension.lowercased() {
        case "gz":
            return try decompress(data: data, tool: "/usr/bin/gzip")
        case "bz2":
            return try decompress(data: data, tool: "/usr/bin/bzip2")
        default:
            return data
        }
    }

    private func decompress(data: Data, tool: String) throws -> Data {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("FeatherMac-APT-\(UUID().uuidString)")
        try data.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        let output = try ProcessRunner.capture(tool, ["-dc", temp.path])
        return Data(output.utf8)
    }

    private func aptRepositoryName(from url: URL) -> String {
        url.host ?? url.deletingLastPathComponent().lastPathComponent.nonEmpty ?? url.absoluteString
    }

    private func aptRepositoryBaseURL(sourceURL: URL, packageURL: URL) -> URL {
        let lowercasedPath = sourceURL.path.lowercased()
        if lowercasedPath.hasSuffix("/packages") ||
            lowercasedPath.hasSuffix("/packages.gz") ||
            lowercasedPath.hasSuffix("/packages.bz2") {
            return sourceURL.deletingLastPathComponent()
        }
        let packagePath = packageURL.path.lowercased()
        if packagePath.contains("/dists/stable/main/binary-iphoneos-arm/") {
            return packageURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        }
        return sourceURL
    }

    private static func packageDownloadURL(filename: String, baseURL: URL) -> URL? {
        if let absolute = URL(string: filename), absolute.scheme != nil {
            return absolute
        }
        return URL(string: filename, relativeTo: baseURL)?.absoluteURL
    }
}

final class IPAService: @unchecked Sendable {
    private let fileManager = FileManager.default

    func importIPA(url: URL, source: URL?, storage: FeatherStorage) async throws -> LibraryApp {
        let id = UUID()
        let destination = storage.importsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        let payload = destination.appendingPathComponent("Payload", isDirectory: true)
        try fileManager.removeItemIfExists(at: destination)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let archive = destination.appendingPathComponent(url.lastPathComponent)
        try fileManager.copyItem(at: url, to: archive)
        try ProcessRunner.run("/usr/bin/unzip", ["-q", archive.path, "-d", destination.path])
        guard fileManager.fileExists(atPath: payload.path) else {
            throw FeatherError.message("IPA does not contain a Payload folder.")
        }

        let appURL = try findPrimaryApp(in: payload)
        let info = try AppBundleInfo.read(appURL: appURL)
        let icon = try extractIcon(from: appURL, info: info, into: destination)

        return LibraryApp(
            id: id,
            kind: .imported,
            name: info.name,
            bundleIdentifier: info.bundleIdentifier,
            version: info.version,
            sourceURL: source,
            storagePath: destination.path,
            ipaPath: archive.path,
            iconPath: icon?.path,
            importedAt: Date(),
            certificateID: nil
        )
    }

    func sign(app: LibraryApp, certificate: CertificateRecord?, provisionURL: URL?, options: SigningOptions, storage: FeatherStorage, progress: @escaping @Sendable (String) -> Void) async throws -> LibraryApp {
        guard app.kind == .imported else {
            throw FeatherError.message("Only imported apps can be signed.")
        }
        let sourcePayload = app.storageURL.appendingPathComponent("Payload", isDirectory: true)
        guard fileManager.fileExists(atPath: sourcePayload.path) else {
            throw FeatherError.message("Imported Payload folder is missing.")
        }

        let work = fileManager.temporaryDirectory.appendingPathComponent("FeatherMacSign-\(UUID().uuidString)", isDirectory: true)
        let workPayload = work.appendingPathComponent("Payload", isDirectory: true)
        try fileManager.removeItemIfExists(at: work)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        try fileManager.copyItem(at: sourcePayload, to: workPayload)

        defer { try? fileManager.removeItem(at: work) }

        let appURL = try findPrimaryApp(in: workPayload)
        progress("Applying modifications...")
        try modify(appURL: appURL, options: options)

        progress("Injecting tweaks...")
        try injectTweaks(appURL: appURL, options: options)

        progress("Removing load commands...")
        try removeDylibs(appURL: appURL, options: options)

        if options.signingMode == .certificate {
            guard let certificate else {
                throw FeatherError.message("Missing certificate.")
            }
            guard let provisionURL else {
                throw FeatherError.message(L10n.string("Missing provisioning profile."))
            }
            progress("Signing with Zsign...")
            try signWithProfiles(appURL: appURL, certificate: certificate, provisionURL: provisionURL, options: options)
        }

        let id = UUID()
        let destination = storage.signedDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.removeItemIfExists(at: destination)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try fileManager.copyItem(at: workPayload, to: destination.appendingPathComponent("Payload", isDirectory: true))

        progress("Archiving IPA...")
        let ipaURL = storage.signedDirectory.appendingPathComponent("\(safeFilename(app.name))-\(id.uuidString.prefix(8)).ipa")
        try fileManager.removeItemIfExists(at: ipaURL)
        let level = "-\(options.zipCompressionLevel)"
        try ProcessRunner.run("/usr/bin/zip", [level, "-qry", ipaURL.path, "Payload"], cwd: destination)

        let signedAppURL = try findPrimaryApp(in: destination.appendingPathComponent("Payload", isDirectory: true))
        let info = try AppBundleInfo.read(appURL: signedAppURL)
        let icon = try extractIcon(from: signedAppURL, info: info, into: destination)

        return LibraryApp(
            id: id,
            kind: .signed,
            name: info.name,
            bundleIdentifier: info.bundleIdentifier,
            version: info.version,
            sourceURL: app.sourceURL,
            storagePath: destination.path,
            ipaPath: ipaURL.path,
            iconPath: icon?.path,
            importedAt: Date(),
            certificateID: certificate?.id
        )
    }

    private func modify(appURL: URL, options: SigningOptions) throws {
        let infoURL = appURL.appendingPathComponent("Info.plist")
        guard let dict = NSMutableDictionary(contentsOf: infoURL) else {
            throw FeatherError.message("Info.plist not found.")
        }
        let oldIdentifier = dict["CFBundleIdentifier"] as? String ?? ""

        var newIdentifier = options.appIdentifier.trimmed.nonEmpty
        if newIdentifier == nil {
            newIdentifier = oldIdentifier
        }
        if options.ppqProtection || options.dynamicProtection {
            newIdentifier = [newIdentifier, options.ppqString.trimmed.nonEmpty].compactMap { $0 }.joined(separator: ".")
        }
        if let newIdentifier, newIdentifier != oldIdentifier {
            replaceStrings(in: dict, old: oldIdentifier, new: newIdentifier)
            dict["CFBundleIdentifier"] = newIdentifier
            try modifyPluginIdentifiers(in: appURL, old: oldIdentifier, new: newIdentifier)
        }

        let name = options.appName.trimmed.nonEmpty
        if let name {
            dict["CFBundleDisplayName"] = name
            dict["CFBundleName"] = name
            if options.changeLanguageFilesForCustomDisplayName {
                try renameLocalizedNames(appURL: appURL, name: name)
            }
        }

        if let version = options.appVersion.trimmed.nonEmpty {
            dict["CFBundleShortVersionString"] = version
            dict["CFBundleVersion"] = version
        }
        if options.appearance != .default {
            dict["UIUserInterfaceStyle"] = options.appearance.rawValue
        }
        if options.minimumOS != .default {
            dict["MinimumOSVersion"] = options.minimumOS.rawValue
        }
        if options.fileSharing { dict["UISupportsDocumentBrowser"] = true }
        if options.iTunesFileSharing { dict["UIFileSharingEnabled"] = true }
        if options.proMotion { dict["CADisableMinimumFrameDurationOnPhone"] = true }
        if options.gameMode { dict["GCSupportsGameMode"] = true }
        if options.iPadFullscreen { dict["UIRequiresFullScreen"] = true }
        if options.removeURLScheme { dict.removeObject(forKey: "CFBundleURLTypes") }
        dict.removeObject(forKey: "UISupportedDevices")
        if options.supportLiquidGlass {
            dict["DTSDKName"] = "iphoneos26.0"
            dict["DTPlatformVersion"] = "26.0"
        }
        applyRules(options.identifierRules) { old, new in
            replaceStrings(in: dict, old: old, new: new)
        }
        applyRules(options.displayNameRules) { old, new in
            replaceStrings(in: dict, old: old, new: new)
        }
        try dict.write(to: infoURL)

        if let iconPath = options.iconPath.trimmed.nonEmpty {
            try replaceIcon(appURL: appURL, iconURL: URL(fileURLWithPath: iconPath), info: dict)
            try dict.write(to: infoURL)
        }
        for relativePath in options.removeFileRules.lines {
            try fileManager.removeItemIfExists(at: appURL.appendingPathComponent(relativePath))
        }
        try fileManager.removeItemIfExists(at: appURL.appendingPathComponent("Watch", isDirectory: true))
        // App Store 下发的 Watch 占位目录（com.apple.WatchPlaceholder）只有 stub
        // （CFBundleExecutable 指向并不存在的 "Executable" 文件），Zsign 无法对其签名，
        // 会使整个签名流程报错，随 Watch 目录一并剥离。
        try fileManager.removeItemIfExists(at: appURL.appendingPathComponent("com.apple.WatchPlaceholder", isDirectory: true))
        try removeEmbeddedProvisioningProfiles(in: appURL)
    }

    private func injectTweaks(appURL: URL, options: SigningOptions) throws {
        var tweakFiles = options.injectionFilePaths.map { URL(fileURLWithPath: $0) }
        if options.replaceSubstrateWithElleKit, let elleKit = Bundle.module.url(forResource: "ellekit", withExtension: "deb") {
            tweakFiles.append(elleKit)
        }
        guard !tweakFiles.isEmpty else { return }
        let machos = try machoTargets(in: appURL, includeExtensions: options.injectIntoExtensions)
        let frameworkDirectory = appURL.appendingPathComponent("Frameworks", isDirectory: true)
        if options.injectFolder == .frameworks {
            try fileManager.createDirectory(at: frameworkDirectory, withIntermediateDirectories: true)
        }

        for file in tweakFiles {
            let dylibs = try materializeTweak(file, appURL: appURL, frameworkDirectory: frameworkDirectory, options: options)
            for dylib in dylibs {
                let loadPath = loadCommand(for: dylib, appURL: appURL, options: options)
                for macho in machos {
                    _ = Zsign.injectDyLib(appExecutable: macho.path, with: loadPath, weak: true)
                }
            }
        }
    }

    private func materializeTweak(_ file: URL, appURL: URL, frameworkDirectory: URL, options: SigningOptions) throws -> [URL] {
        if file.pathExtension.lowercased() == "dylib" {
            let targetDirectory = options.injectFolder == .frameworks ? frameworkDirectory : appURL
            let target = targetDirectory.appendingPathComponent(file.lastPathComponent)
            try fileManager.removeItemIfExists(at: target)
            try fileManager.copyItem(at: file, to: target)
            return [target]
        }
        if file.pathExtension.lowercased() == "deb" {
            let extraction = fileManager.temporaryDirectory.appendingPathComponent("FeatherMacDeb-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: extraction, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: extraction) }
            try ProcessRunner.run("/usr/bin/ar", ["-x", file.path], cwd: extraction)
            let dataArchive = try fileManager.contentsOfDirectory(at: extraction, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix("data.") }
            guard let dataArchive else { return [] }
            try ProcessRunner.run("/usr/bin/tar", ["-xf", dataArchive.path, "-C", extraction.path])
            let found = try fileManager.recursiveFiles(at: extraction).filter { $0.pathExtension == "dylib" || $0.pathExtension == "framework" }
            var copied: [URL] = []
            for item in found {
                let targetDirectory = options.injectFolder == .frameworks ? frameworkDirectory : appURL
                let target = targetDirectory.appendingPathComponent(item.lastPathComponent)
                try fileManager.removeItemIfExists(at: target)
                try fileManager.copyItem(at: item, to: target)
                copied.append(target)
            }
            return copied
        }
        return []
    }

    private func loadCommand(for dylib: URL, appURL: URL, options: SigningOptions) -> String {
        if options.injectFolder == .frameworks {
            return "\(options.injectPath.rawValue)/Frameworks/\(dylib.lastPathComponent)"
        }
        return "\(options.injectPath.rawValue)/\(dylib.lastPathComponent)"
    }

    private func removeDylibs(appURL: URL, options: SigningOptions) throws {
        let commands = options.disinjectLoadCommands.lines
        guard !commands.isEmpty else { return }
        for macho in try machoTargets(in: appURL, includeExtensions: true) {
            _ = Zsign.removeDylibs(appExecutable: macho.path, using: commands)
        }
    }

    private func signWithProfiles(appURL: URL, certificate: CertificateRecord, provisionURL: URL, options: SigningOptions) throws {
        let profiles = try provisioningProfiles(near: provisionURL)
        let extensionProfiles = try extensionProvisionProfiles(appURL: appURL, profiles: profiles)
        if extensionProfiles.isEmpty {
            try zsign(appURL: appURL, provisionURL: provisionURL, certificate: certificate, options: options)
            return
        }

        try zsign(appURL: appURL, provisionURL: provisionURL, certificate: certificate, options: options)
        for appex in try fileManager.recursiveFiles(at: appURL).filter({ $0.pathExtension == "appex" }) {
            guard let bundleID = Bundle(path: appex.path)?.bundleIdentifier,
                  let profile = extensionProfiles[bundleID] else {
                continue
            }
            try zsign(appURL: appex, provisionURL: profile, certificate: certificate, options: options)
        }
        setenv("ZSIGN_SKIP_NESTED_BUNDLES", "1", 1)
        defer { unsetenv("ZSIGN_SKIP_NESTED_BUNDLES") }
        try zsign(appURL: appURL, provisionURL: provisionURL, certificate: certificate, options: options)
    }

    private func zsign(appURL: URL, provisionURL: URL, certificate: CertificateRecord, options: SigningOptions) throws {
        if !options.removeProvisioning {
            try fileManager.copyItemReplacing(from: provisionURL, to: appURL.appendingPathComponent("embedded.mobileprovision"))
        }
        var zsignError: Error?
        let ok = Zsign.sign(
            appPath: appURL.path,
            provisionPath: provisionURL.path,
            p12Path: certificate.p12URL.path,
            p12Password: certificate.password,
            entitlementsPath: options.entitlementsPath,
            removeProvision: !options.removeProvisioning
        ) { _, error in
            zsignError = error
        }
        if let zsignError {
            throw zsignError
        }
        if !ok {
            throw FeatherError.message("Zsign failed.")
        }
    }

    private func extensionProvisionProfiles(appURL: URL, profiles: [String: URL]) throws -> [String: URL] {
        var matched: [String: URL] = [:]
        for appex in try fileManager.recursiveFiles(at: appURL).filter({ $0.pathExtension == "appex" }) {
            guard let bundleID = Bundle(path: appex.path)?.bundleIdentifier,
                  let profile = profiles[bundleID] else {
                continue
            }
            matched[bundleID] = profile
        }
        return matched
    }

    private func provisioningProfiles(near provisionURL: URL) throws -> [String: URL] {
        let directory = provisionURL.deletingLastPathComponent()
        let candidates = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { ["mobileprovision", "provisionprofile"].contains($0.pathExtension.lowercased()) }
        var profiles: [String: URL] = [:]
        for candidate in candidates {
            guard let bundleID = try profileBundleIdentifier(candidate) else { continue }
            profiles[bundleID] = candidate
        }
        return profiles
    }

    private func profileBundleIdentifier(_ profile: URL) throws -> String? {
        let result = try ProcessRunner.capture("/usr/bin/security", ["cms", "-D", "-i", profile.path])
        guard let data = result.data(using: .utf8),
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let identifier = entitlements["application-identifier"] as? String,
              let dot = identifier.firstIndex(of: ".") else {
            return nil
        }
        return String(identifier[identifier.index(after: dot)...])
    }

    private func machoTargets(in appURL: URL, includeExtensions: Bool) throws -> [URL] {
        var bundles = [appURL]
        if includeExtensions {
            bundles += try fileManager.recursiveFiles(at: appURL).filter { $0.pathExtension == "appex" || $0.pathExtension == "app" }
        }
        return bundles.compactMap { bundle in
            guard let executable = Bundle(path: bundle.path)?.executableURL else { return nil }
            return executable
        }
    }

    private func modifyPluginIdentifiers(in appURL: URL, old: String, new: String) throws {
        let bundles = try fileManager.recursiveFiles(at: appURL).filter { $0.pathExtension == "appex" || $0.pathExtension == "app" }
        for bundle in bundles {
            let infoURL = bundle.appendingPathComponent("Info.plist")
            guard let dict = NSMutableDictionary(contentsOf: infoURL) else { continue }
            replaceStrings(in: dict, old: old, new: new)
            try dict.write(to: infoURL)
        }
    }

    private func removeEmbeddedProvisioningProfiles(in appURL: URL) throws {
        for profile in try fileManager.recursiveFiles(at: appURL).filter({ $0.lastPathComponent == "embedded.mobileprovision" }) {
            try fileManager.removeItemIfExists(at: profile)
        }
    }

    private func renameLocalizedNames(appURL: URL, name: String) throws {
        for lproj in try fileManager.contentsOfDirectory(at: appURL, includingPropertiesForKeys: nil).filter({ $0.pathExtension == "lproj" }) {
            let strings = lproj.appendingPathComponent("InfoPlist.strings")
            guard let dict = NSMutableDictionary(contentsOf: strings) else { continue }
            dict["CFBundleDisplayName"] = name
            dict["CFBundleName"] = name
            dict.write(to: strings, atomically: true)
        }
    }

    private func replaceIcon(appURL: URL, iconURL: URL, info: NSMutableDictionary) throws {
        guard let image = NSImage(contentsOf: iconURL) else {
            throw FeatherError.message("Could not read replacement icon.")
        }
        let iconFiles = [
            ("FRIcon60x60@2x.png", 120),
            ("FRIcon60x60@3x.png", 180),
            ("FRIcon76x76@2x~ipad.png", 152)
        ]
        for iconFile in iconFiles {
            let data = try image.pngData(square: iconFile.1)
            try data.write(to: appURL.appendingPathComponent(iconFile.0))
        }
        info["CFBundleIcons"] = [
            "CFBundlePrimaryIcon": [
                "CFBundleIconFiles": ["FRIcon60x60"],
                "CFBundleIconName": "FRIcon"
            ]
        ]
        info["CFBundleIcons~ipad"] = [
            "CFBundlePrimaryIcon": [
                "CFBundleIconFiles": ["FRIcon60x60", "FRIcon76x76"],
                "CFBundleIconName": "FRIcon"
            ]
        ]
    }

    private func findPrimaryApp(in payload: URL) throws -> URL {
        let apps = try fileManager.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil).filter { $0.pathExtension == "app" }
        guard let app = apps.first else {
            throw FeatherError.message("Payload does not contain an .app bundle.")
        }
        return app
    }

    private func extractIcon(from appURL: URL, info: AppBundleInfo, into directory: URL) throws -> URL? {
        guard let iconName = info.iconName else { return nil }
        let candidates = try fileManager.recursiveFiles(at: appURL).filter { url in
            let name = url.deletingPathExtension().lastPathComponent
            return name == iconName || name.hasPrefix(iconName)
        }
        guard let source = candidates.first(where: { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }) else {
            return nil
        }
        let target = directory.appendingPathComponent("icon.\(source.pathExtension)")
        try fileManager.removeItemIfExists(at: target)
        try fileManager.copyItem(at: source, to: target)
        return target
    }

    private func safeFilename(_ value: String) -> String {
        value.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
    }
}

struct ProvisionMetadata {
    var expiration: Date?
    var teamName: String?
    var teamIdentifier: String?
    var appIdentifierPrefix: String?
    var bundleIdentifier: String?
    var appIDName: String?
}

struct P12Metadata {
    var commonName: String?
    var organization: String?
    var organizationalUnit: String?
    var expiration: Date?
    var serialNumber: String?
}

struct GeneratedCSR {
    var privateKeyPEM: String
    var csrPEM: String
}

enum CertificateService {
    /// 本机生成 RSA 2048 私钥与 CSR。私钥全程不出本机，只有 CSR（含公钥）会上传给苹果。
    static func createCSR(commonName: String) throws -> GeneratedCSR {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeatherMac-CSR-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temp) }

        let keyURL = temp.appendingPathComponent("key.pem")
        let csrURL = temp.appendingPathComponent("csr.pem")
        // subject 里的 / 和 = 会破坏 -subj 语法；苹果签发时也会重写 subject，这里只需一个合法 CN。
        let safeCN = commonName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "=", with: "-")
            .trimmed
            .nonEmpty ?? "FeatherMac"
        _ = try ProcessRunner.capture("/usr/bin/openssl", [
            "req", "-new",
            "-newkey", "rsa:2048",
            "-nodes",
            "-keyout", keyURL.path,
            "-out", csrURL.path,
            "-subj", "/CN=\(safeCN)"
        ])
        return GeneratedCSR(
            privateKeyPEM: try String(contentsOf: keyURL, encoding: .utf8),
            csrPEM: try String(contentsOf: csrURL, encoding: .utf8)
        )
    }

    /// 把苹果签发回来的 DER 证书与本地私钥打包成 p12，返回临时文件（调用方负责删除）。
    ///
    /// 必须显式指定 AES-256-CBC：macOS 自带的是 LibreSSL，`pkcs12 -export` 默认用
    /// pbeWithSHA1And40BitRC2-CBC，而 Zsign 链接的 OpenSSL 3 默认不加载 legacy provider，
    /// 会以 "unsupported algorithm RC2-40-CBC" 直接拒读——那样签名会全线失败。
    static func packageP12(privateKeyPEM: String, certificateDER: Data, password: String) throws -> URL {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeatherMac-P12-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let keyURL = temp.appendingPathComponent("key.pem")
        let derURL = temp.appendingPathComponent("cert.der")
        let pemURL = temp.appendingPathComponent("cert.pem")
        let p12URL = temp.appendingPathComponent("cert.p12")
        try privateKeyPEM.write(to: keyURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        try certificateDER.write(to: derURL)

        _ = try ProcessRunner.capture("/usr/bin/openssl", ["x509", "-inform", "DER", "-in", derURL.path, "-out", pemURL.path])
        _ = try ProcessRunner.capture("/usr/bin/openssl", [
            "pkcs12", "-export",
            "-inkey", keyURL.path,
            "-in", pemURL.path,
            "-out", p12URL.path,
            "-keypbe", "AES-256-CBC",
            "-certpbe", "AES-256-CBC",
            "-macalg", "sha256",
            "-passout", "pass:\(password)"
        ])
        // 私钥与中间产物用完即删，只留 p12 供调用方导入。
        try? FileManager.default.removeItem(at: keyURL)
        try? FileManager.default.removeItem(at: derURL)
        try? FileManager.default.removeItem(at: pemURL)
        return p12URL
    }

    /// 自动生成的 p12 密码：4 组 4 位，避开易混淆字符，便于用户抄写。
    static func generatePassword() -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let groups = (0..<4).map { _ in
            String((0..<4).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
        }
        return groups.joined(separator: "-")
    }

    static func importCertificate(p12: URL, password: String, storage: FeatherStorage) throws -> CertificateRecord {
        let id = UUID()
        let destination = storage.certificatesDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let p12Target = destination.appendingPathComponent("cert.p12")
        try FileManager.default.copyItem(at: p12, to: p12Target)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12Target.path)

        let metadata = try p12Metadata(p12: p12Target, password: password)
        let nickname = metadata.commonName ?? metadata.organization ?? p12.deletingPathExtension().lastPathComponent
        return CertificateRecord(
            id: id,
            nickname: nickname,
            p12Path: p12Target.path,
            provisionPath: nil,
            password: password,
            expiration: metadata.expiration,
            teamName: metadata.organization,
            teamIdentifier: metadata.organizationalUnit,
            appIdentifierPrefix: metadata.organizationalUnit,
            appIDName: nil,
            p12SerialNumber: metadata.serialNumber,
            importedAt: Date(),
            isDefault: false
        )
    }

    static func parseProvision(_ url: URL) -> ProvisionMetadata {
        do {
            let result = try ProcessRunner.capture("/usr/bin/security", ["cms", "-D", "-i", url.path])
            guard let data = result.data(using: .utf8),
                  let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                return ProvisionMetadata()
            }
            let teamIdentifier = (plist["TeamIdentifier"] as? [String])?.first
            let appIdentifierPrefix = (plist["ApplicationIdentifierPrefix"] as? [String])?.first ?? teamIdentifier
            let entitlements = plist["Entitlements"] as? [String: Any]
            let applicationIdentifier = entitlements?["application-identifier"] as? String
            let bundleIdentifier = applicationIdentifier.flatMap { value -> String? in
                guard let prefix = appIdentifierPrefix,
                      value.hasPrefix("\(prefix).") else {
                    return nil
                }
                let suffix = String(value.dropFirst(prefix.count + 1))
                return suffix == "*" ? nil : suffix
            }
            return (
                ProvisionMetadata(
                    expiration: plist["ExpirationDate"] as? Date,
                    teamName: (plist["TeamName"] as? String) ?? teamIdentifier,
                    teamIdentifier: teamIdentifier,
                    appIdentifierPrefix: appIdentifierPrefix,
                    bundleIdentifier: bundleIdentifier,
                    appIDName: plist["AppIDName"] as? String
                )
            )
        } catch {
            return ProvisionMetadata()
        }
    }

    static func developerCertificateSerials(in provision: URL) throws -> Set<String> {
        let result = try ProcessRunner.capture("/usr/bin/security", ["cms", "-D", "-i", provision.path])
        guard let data = result.data(using: .utf8),
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let certificates = plist["DeveloperCertificates"] as? [Data] else {
            return []
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("FeatherMac-ProvisionCerts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        var serials = Set<String>()
        for (index, certData) in certificates.enumerated() {
            let certURL = temp.appendingPathComponent("cert-\(index).cer")
            try certData.write(to: certURL)
            let output = try ProcessRunner.capture("/usr/bin/openssl", ["x509", "-inform", "DER", "-in", certURL.path, "-serial", "-noout"])
            if let serial = output
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "serial=", with: "")
                .replacingOccurrences(of: ":", with: "")
                .uppercased()
                .nonEmpty {
                serials.insert(serial)
            }
        }
        return serials
    }

    static func p12CertificateSerialNumber(p12: URL, password: String) throws -> String? {
        try p12Metadata(p12: p12, password: password).serialNumber
    }

    static func p12Metadata(p12: URL, password: String) throws -> P12Metadata {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("FeatherMac-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let pem = temp.appendingPathComponent("cert.pem")
        _ = try ProcessRunner.capture("/usr/bin/openssl", [
            "pkcs12",
            "-in", p12.path,
            "-clcerts",
            "-nokeys",
            "-passin", "pass:\(password)",
            "-out", pem.path
        ])
        let subject = try ProcessRunner.capture("/usr/bin/openssl", ["x509", "-in", pem.path, "-subject", "-nameopt", "RFC2253", "-noout"])
        let endDate = try ProcessRunner.capture("/usr/bin/openssl", ["x509", "-in", pem.path, "-enddate", "-noout"])
        let serial = try ProcessRunner.capture("/usr/bin/openssl", ["x509", "-in", pem.path, "-serial", "-noout"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "serial=", with: "")
            .replacingOccurrences(of: ":", with: "")
            .uppercased()
        let fields = certificateSubjectFields(subject)
        let expiration = certificateExpirationDate(endDate)
        return P12Metadata(
            commonName: fields["CN"],
            organization: fields["O"],
            organizationalUnit: fields["OU"],
            expiration: expiration,
            serialNumber: serial.nonEmpty
        )
    }

    private static func certificateSubjectFields(_ subject: String) -> [String: String] {
        let raw = subject.replacingOccurrences(of: "subject=", with: "").trimmed
        var result: [String: String] = [:]
        for part in raw.split(separator: ",") {
            let pieces = part.split(separator: "=", maxSplits: 1).map { String($0).trimmed }
            guard pieces.count == 2 else { continue }
            result[pieces[0]] = pieces[1]
        }
        return result
    }

    private static func certificateExpirationDate(_ value: String) -> Date? {
        let raw = value.replacingOccurrences(of: "notAfter=", with: "").trimmed
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM d HH:mm:ss yyyy zzz"
        return formatter.date(from: raw)
    }
}

enum BundleIdentifierGenerator {
    static func suggestedIdentifier(app: LibraryApp?, certificate: CertificateRecord?, configuredPrefix: String) -> String {
        let prefix = configuredPrefix.trimmed.nonEmpty
            ?? reverseDNSPrefix(from: certificate?.teamName ?? certificate?.nickname)
            ?? "com.feathermac"
        let source = app?.name.nonEmpty ?? app?.bundleIdentifier.components(separatedBy: ".").last ?? "app"
        return "\(normalizedPrefix(prefix)).\(safeComponent(source))"
    }

    static func safeComponent(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let lower = folded.lowercased()
        let replaced = lower.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        let trimmed = replaced.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        let component = trimmed.nonEmpty ?? "app"
        if component.first?.isNumber == true {
            return "app-\(component)"
        }
        return component
    }

    private static func normalizedPrefix(_ value: String) -> String {
        let components = value
            .lowercased()
            .split(separator: ".")
            .map { safeComponent(String($0)) }
            .filter { !$0.isEmpty }
        let joined = components.joined(separator: ".")
        return joined.hasPrefix("com.") ? joined : "com.\(joined)"
    }

    private static func reverseDNSPrefix(from name: String?) -> String? {
        guard let name = name?.trimmed.nonEmpty else { return nil }
        let words = name
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        if words.count >= 2 {
            return "com.\(safeComponent(words[1] + words[0]))"
        }
        return "com.\(safeComponent(words[0]))"
    }
}

struct ConnectedDeviceInfo {
    var udid: String
    var name: String
}

struct CreatedProvisioningProfile {
    var id: String
    var name: String
    var data: Data
}

/// v1 只支持开发签名需要的两类。Distribution 涉及发布，风险高，不提供入口。
enum DeveloperCertificateType: String, CaseIterable, Identifiable, Codable {
    case iosDevelopment = "IOS_DEVELOPMENT"
    case development = "DEVELOPMENT"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iosDevelopment: "iOS Development"
        case .development: "Apple Development"
        }
    }

    static var apiFilterValue: String {
        allCases.map(\.rawValue).joined(separator: ",")
    }
}

/// 账号下一张开发证书在门户中的样子。
struct PortalCertificate: Identifiable, Hashable {
    var id: String
    var name: String
    var type: String
    var serialNumber: String?
    var expiration: Date?

    var isExpired: Bool {
        guard let expiration else { return false }
        return expiration < Date()
    }
}

struct CreatedCertificate {
    var portal: PortalCertificate
    var der: Data
}

struct ASCAccountSummary {
    var certificateCount: Int
    /// 苹果的团队 ID（bundleIds 的 seedId），用来让用户确认连对了账号。
    var teamIdentifier: String?
}

final class AppleDeveloperService: @unchecked Sendable {
    private let baseURL = URL(string: "https://api.appstoreconnect.apple.com/v1")!

    /// 功能 A 第 4 步：用填好的三项发一次最小请求，验证 JWT 是否被苹果接受。
    func validateCredentials(settings: AppStoreConnectSettings) async throws -> ASCAccountSummary {
        try validate(settings)
        let client = try AppStoreConnectClient(settings: settings, baseURL: baseURL)
        let certificates = try await client.list(
            path: "certificates",
            filters: ["certificateType": DeveloperCertificateType.apiFilterValue],
            limit: 200
        )
        // 不从证书名里猜团队名：API 建的证书叫 "iOS Development: Created via API"，
        // 按冒号切出来的是 "Created via API"，是段没有意义的字符串。
        // bundleIds 的 seedId 才是真正的团队 ID。取不到就不显示，不编。
        let teamIdentifier = try? await client
            .list(path: "bundleIds", filters: [:], limit: 1)
            .first?
            .seedID
        return ASCAccountSummary(
            certificateCount: certificates.count,
            teamIdentifier: teamIdentifier ?? nil
        )
    }

    func listCertificates(settings: AppStoreConnectSettings) async throws -> [PortalCertificate] {
        try validate(settings)
        let client = try AppStoreConnectClient(settings: settings, baseURL: baseURL)
        let resources = try await client.list(
            path: "certificates",
            filters: ["certificateType": DeveloperCertificateType.apiFilterValue],
            limit: 200
        )
        return resources.map(Self.portalCertificate(from:))
    }

    /// 提交 CSR 换一张开发证书。409（数量达上限）原样抛出，由调用方走吊销重建流程。
    func createCertificate(type: DeveloperCertificateType, csrPEM: String, settings: AppStoreConnectSettings) async throws -> CreatedCertificate {
        try validate(settings)
        let client = try AppStoreConnectClient(settings: settings, baseURL: baseURL)
        let body: [String: Any] = [
            "data": [
                "type": "certificates",
                "attributes": [
                    "certificateType": type.rawValue,
                    "csrContent": csrPEM
                ]
            ]
        ]
        let resource = try await client.create(path: "certificates", body: body)
        guard let content = resource.certificateContent,
              let der = Data(base64Encoded: content, options: [.ignoreUnknownCharacters]) else {
            throw FeatherError.message("Apple did not return certificate content.")
        }
        return CreatedCertificate(portal: Self.portalCertificate(from: resource), der: der)
    }

    func revokeCertificate(id: String, settings: AppStoreConnectSettings) async throws {
        try validate(settings)
        let client = try AppStoreConnectClient(settings: settings, baseURL: baseURL)
        try await client.delete(path: "certificates", id: id)
    }

    private static func portalCertificate(from resource: ASCResource) -> PortalCertificate {
        PortalCertificate(
            id: resource.id,
            name: resource.name ?? resource.displayName ?? "Certificate",
            type: resource.certificateType ?? "",
            serialNumber: resource.serialNumber?.uppercased(),
            expiration: resource.expirationDate
        )
    }

    func createDevelopmentProfile(appName: String, bundleIdentifier: String, certificate: CertificateRecord, settings: AppStoreConnectSettings, progress: (@Sendable (String) -> Void)? = nil) async throws -> CreatedProvisioningProfile {
        try validate(settings)
        let client = try AppStoreConnectClient(settings: settings, baseURL: baseURL)
        // Apple 的 bundleIds/profiles 接口只接受 ASCII 名称，中文应用名（如“微信”）会被
        // HTTP 409 拒绝，这里统一转成 ASCII 安全名称。
        let safeName = AppleDeveloperService.apiSafeName(for: appName, bundleIdentifier: bundleIdentifier)
        let bundleID = try await ensureBundleID(identifier: bundleIdentifier, name: safeName, client: client)
        let device = try connectedDevice()
        let deviceResource = try await ensureDevice(device, settings: settings, client: client)
        let certificateResource = try await matchingCertificate(for: certificate, client: client)
        let profileName = "\(safeName) Development \(bundleIdentifier)"
        // 吊销证书会把绑它的描述文件变成 INVALID，但名字还占着，苹果会以
        // "Multiple profiles found with the name ..." 409 拒绝新建。
        // 这里先清掉同名的旧文件——名字是本应用按固定规则生成的，属于自己的命名空间。
        try await removeProfiles(named: profileName, client: client, progress: progress)
        return try await createProfile(
            name: profileName,
            bundleID: bundleID.id,
            certificateID: certificateResource.id,
            deviceID: deviceResource.id,
            client: client
        )
    }

    private func removeProfiles(named name: String, client: AppStoreConnectClient, progress: (@Sendable (String) -> Void)?) async throws {
        let existing = try await client.list(path: "profiles", filters: ["name": name], limit: 200)
        for profile in existing where profile.name == name {
            try await client.delete(path: "profiles", id: profile.id)
            progress?("Removed stale provisioning profile \(name).")
        }
    }

    static func apiSafeName(for appName: String, bundleIdentifier: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-"))
        let trimmedName = appName.trimmed
        let transliterated = trimmedName.applyingTransform(StringTransform("Any-Latin; Latin-ASCII"), reverse: false) ?? trimmedName
        let filtered = String(transliterated.unicodeScalars.filter { allowed.contains($0) })
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmed
        if !filtered.isEmpty {
            return filtered
        }
        if let component = bundleIdentifier.split(separator: ".").last, !component.isEmpty {
            return String(component)
        }
        return "App"
    }

    private func validate(_ settings: AppStoreConnectSettings) throws {
        if settings.issuerID.trimmed.isEmpty || settings.keyID.trimmed.isEmpty || settings.privateKeyPath.trimmed.isEmpty {
            throw FeatherError.message("Configure App Store Connect Issuer ID, Key ID, and .p8 key first.")
        }
    }

    private func connectedDevice() throws -> ConnectedDeviceInfo {
        guard let ideviceinfo = InstallService.toolPath("ideviceinfo") else {
            throw FeatherError.message("ideviceinfo is missing. Install libimobiledevice first.")
        }
        let udid = try ProcessRunner.capture(ideviceinfo, ["-k", "UniqueDeviceID"]).trimmed
        let name = (try? ProcessRunner.capture(ideviceinfo, ["-k", "DeviceName"]).trimmed).flatMap(\.nonEmpty) ?? "iPhone"
        guard !udid.isEmpty else {
            throw FeatherError.message("No connected iOS device found.")
        }
        return ConnectedDeviceInfo(udid: udid, name: name)
    }

    private func ensureBundleID(identifier: String, name: String, client: AppStoreConnectClient) async throws -> ASCResource {
        if let existing = try await client.list(path: "bundleIds", filters: ["identifier": identifier]).first {
            return existing
        }
        let body: [String: Any] = [
            "data": [
                "type": "bundleIds",
                "attributes": [
                    "identifier": identifier,
                    "name": name,
                    "platform": "IOS"
                ]
            ]
        ]
        do {
            return try await client.create(path: "bundleIds", body: body)
        } catch {
            if let existing = try await client.list(path: "bundleIds", filters: ["identifier": identifier]).first {
                return existing
            }
            throw error
        }
    }

    private func ensureDevice(_ device: ConnectedDeviceInfo, settings: AppStoreConnectSettings, client: AppStoreConnectClient) async throws -> ASCResource {
        if let existing = try await client.list(path: "devices", filters: ["udid": device.udid]).first {
            return existing
        }
        guard settings.registerConnectedDevice else {
            throw FeatherError.message("Connected device is not registered in Apple Developer.")
        }
        let body: [String: Any] = [
            "data": [
                "type": "devices",
                "attributes": [
                    "name": device.name,
                    "platform": "IOS",
                    "udid": device.udid
                ]
            ]
        ]
        return try await client.create(path: "devices", body: body)
    }

    private func matchingCertificate(for certificate: CertificateRecord, client: AppStoreConnectClient) async throws -> ASCResource {
        // Xcode 生成的"Apple Development"证书类型是 DEVELOPMENT，只过滤 IOS_DEVELOPMENT 会误判
        // "无匹配证书"（2026-07-18 故障排查实证）。API 支持逗号多值。
        let certificates = try await client.list(
            path: "certificates",
            filters: ["certificateType": DeveloperCertificateType.apiFilterValue],
            limit: 200
        )
        let wantedSerial = certificate.p12SerialNumber?.uppercased()
        if let wantedSerial,
           let match = certificates.first(where: { $0.serialNumber?.uppercased() == wantedSerial }) {
            return match
        }
        if wantedSerial != nil {
            throw FeatherError.message("No App Store Connect certificate matches the imported p12 serial number.")
        }
        if let match = certificates.first(where: { resource in
            let display = [resource.name, resource.displayName].compactMap { $0?.lowercased() }.joined(separator: " ")
            return display.contains(certificate.nickname.lowercased())
        }) {
            return match
        }
        guard let first = certificates.first else {
            throw FeatherError.message("No iOS development certificate was found in App Store Connect.")
        }
        return first
    }

    private func createProfile(name: String, bundleID: String, certificateID: String, deviceID: String, client: AppStoreConnectClient) async throws -> CreatedProvisioningProfile {
        let body: [String: Any] = [
            "data": [
                "type": "profiles",
                "attributes": [
                    "name": name,
                    "profileType": "IOS_APP_DEVELOPMENT"
                ],
                "relationships": [
                    "bundleId": [
                        "data": ["type": "bundleIds", "id": bundleID]
                    ],
                    "certificates": [
                        "data": [["type": "certificates", "id": certificateID]]
                    ],
                    "devices": [
                        "data": [["type": "devices", "id": deviceID]]
                    ]
                ]
            ]
        ]
        let response = try await client.create(path: "profiles", body: body)
        guard let content = response.profileContent,
              let data = Data(base64Encoded: content) else {
            throw FeatherError.message("Apple did not return provisioning profile content.")
        }
        return CreatedProvisioningProfile(id: response.id, name: response.name ?? name, data: data)
    }
}

struct ASCResource {
    var id: String
    var attributes: [String: Any]

    var name: String? { attributes["name"] as? String }
    var displayName: String? { attributes["displayName"] as? String }
    var serialNumber: String? { (attributes["serialNumber"] as? String)?.replacingOccurrences(of: ":", with: "") }
    var profileContent: String? { attributes["profileContent"] as? String }
    var certificateType: String? { attributes["certificateType"] as? String }
    var seedID: String? { attributes["seedId"] as? String }
    var certificateContent: String? { attributes["certificateContent"] as? String }

    /// ASC 返回的是 ISO8601 字符串（形如 2027-07-18T09:12:33.000+00:00）。
    /// ISO8601DateFormatter 不是 Sendable，不能做静态缓存，按需构造。
    var expirationDate: Date? {
        guard let raw = attributes["expirationDate"] as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}

enum ASCAPIError: LocalizedError {
    case http(status: Int, detail: String)

    var status: Int {
        switch self {
        case .http(let status, _): status
        }
    }

    var detail: String {
        switch self {
        case .http(_, let detail): detail
        }
    }

    var errorDescription: String? {
        switch self {
        case .http(let status, let detail): "Apple API HTTP \(status): \(detail)"
        }
    }
}

final class AppStoreConnectClient: @unchecked Sendable {
    private let settings: AppStoreConnectSettings
    private let baseURL: URL
    private let encoder = JSONEncoder()
    private let session: URLSession

    init(settings: AppStoreConnectSettings, baseURL: URL) throws {
        self.settings = settings
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        self.session = URLSession(configuration: configuration)
        _ = try Self.jwt(settings: settings)
    }

    func list(path: String, filters: [String: String], limit: Int = 20) async throws -> [ASCResource] {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        var queryItems: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
        queryItems.append(contentsOf: filters.map { URLQueryItem(name: "filter[\($0.key)]", value: $0.value) })
        components.queryItems = queryItems
        let json = try await request(url: components.url!, method: "GET")
        return resources(from: json)
    }

    func create(path: String, body: [String: Any]) async throws -> ASCResource {
        let data = try JSONSerialization.data(withJSONObject: body, options: [])
        let json = try await request(url: baseURL.appendingPathComponent(path), method: "POST", body: data)
        guard let resource = resources(from: json).first else {
            throw FeatherError.message("Apple API returned an empty response.")
        }
        return resource
    }

    /// DELETE /v1/<path>/<id>。成功时苹果返回 204 无正文。
    func delete(path: String, id: String) async throws {
        let url = baseURL.appendingPathComponent(path).appendingPathComponent(id)
        _ = try await request(url: url, method: "DELETE", allowEmptyResponse: true)
    }

    private func request(url: URL, method: String, body: Data? = nil, allowEmptyResponse: Bool = false) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(try Self.jwt(settings: settings))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FeatherError.message("Apple API returned a non-HTTP response.")
        }
        if !(200...299).contains(http.statusCode) {
            let detail = Self.appleErrorMessage(from: data) ?? String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            // 带状态码抛出，让调用方能区分 401（凭据错）/403（权限不足）/409（数量达上限）。
            throw ASCAPIError.http(status: http.statusCode, detail: detail)
        }
        if allowEmptyResponse && data.isEmpty {
            return [:]
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FeatherError.message("Apple API returned invalid JSON.")
        }
        return json
    }

    private func resources(from json: [String: Any]) -> [ASCResource] {
        if let array = json["data"] as? [[String: Any]] {
            return array.compactMap(Self.resource(from:))
        }
        if let object = json["data"] as? [String: Any],
           let resource = Self.resource(from: object) {
            return [resource]
        }
        return []
    }

    private static func resource(from object: [String: Any]) -> ASCResource? {
        guard let id = object["id"] as? String else { return nil }
        return ASCResource(id: id, attributes: object["attributes"] as? [String: Any] ?? [:])
    }

    private static func jwt(settings: AppStoreConnectSettings) throws -> String {
        let header: [String: Any] = ["alg": "ES256", "kid": settings.keyID.trimmed, "typ": "JWT"]
        let now = Int(Date().timeIntervalSince1970)
        let payload: [String: Any] = [
            "iss": settings.issuerID.trimmed,
            "iat": now,
            "exp": now + 20 * 60,
            "aud": "appstoreconnect-v1"
        ]
        let headerData = try JSONSerialization.data(withJSONObject: header, options: [])
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [])
        let signingInput = "\(headerData.base64URLEncodedString()).\(payloadData.base64URLEncodedString())"
        let keyPEM = try String(contentsOf: URL(fileURLWithPath: settings.privateKeyPath), encoding: .utf8)
        let key = try P256.Signing.PrivateKey(pemRepresentation: keyPEM)
        let signature = try key.signature(for: Data(signingInput.utf8))
        return "\(signingInput).\(signature.rawRepresentation.base64URLEncodedString())"
    }

    private static func appleErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = json["errors"] as? [[String: Any]] else {
            return nil
        }
        return errors.compactMap { error in
            [error["title"] as? String, error["detail"] as? String]
                .compactMap(\.self)
                .joined(separator: ": ")
                .nonEmpty
        }.joined(separator: "; ")
    }
}

final class InstallService: @unchecked Sendable {
    func install(app: LibraryApp) async throws {
        guard let ipa = app.ipaURL else {
            throw FeatherError.message("No IPA archive available.")
        }
        if let ideviceinstaller = Self.toolPath("ideviceinstaller") {
            try ProcessRunner.run(ideviceinstaller, ["install", ipa.path])
            return
        }
        if let iosDeploy = Self.toolPath("ios-deploy") {
            try ProcessRunner.run(iosDeploy, ["--bundle", ipa.path])
            return
        }
        throw FeatherError.message("Install tools are missing. Install libimobiledevice/ideviceinstaller or export the IPA manually.")
    }

    static func toolPath(_ name: String) -> String? {
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        for path in paths {
            let url = URL(fileURLWithPath: path).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url.path
            }
        }
        return nil
    }
}

struct AppBundleInfo {
    var name: String
    var bundleIdentifier: String
    var version: String
    var iconName: String?

    static func read(appURL: URL) throws -> AppBundleInfo {
        let infoURL = appURL.appendingPathComponent("Info.plist")
        guard let dict = NSDictionary(contentsOf: infoURL) as? [String: Any] else {
            throw FeatherError.message("Could not read Info.plist.")
        }
        let name = (dict["CFBundleDisplayName"] as? String)
            ?? (dict["CFBundleName"] as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
        let identifier = dict["CFBundleIdentifier"] as? String ?? "unknown.bundle"
        let version = (dict["CFBundleShortVersionString"] as? String)
            ?? (dict["CFBundleVersion"] as? String)
            ?? "0"
        let icon = findIconName(in: dict)
        return AppBundleInfo(name: name, bundleIdentifier: identifier, version: version, iconName: icon)
    }

    private static func findIconName(in dict: [String: Any]) -> String? {
        if let icons = dict["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String],
           let last = files.last {
            return last
        }
        if let files = dict["CFBundleIconFiles"] as? [String], let last = files.last {
            return last
        }
        return nil
    }
}

@MainActor
enum FilePicker {
    static func open(types: [UTType]) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func openMultiple(types: [UTType]) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func save(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        return panel.runModal() == .OK ? panel.url : nil
    }
}

@MainActor
enum Confirm {
    /// 破坏性或外发操作的二次确认。默认按钮是"取消"，确认按钮需要用户主动选择。
    static func warn(title: String, message: String, confirmTitle: String, destructive: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string(title)
        alert.informativeText = L10n.string(message)
        let confirmButton = alert.addButton(withTitle: L10n.string(confirmTitle))
        alert.addButton(withTitle: L10n.string("Cancel"))
        if destructive, #available(macOS 11.0, *) {
            confirmButton.hasDestructiveAction = true
        }
        return alert.runModal() == .alertFirstButtonReturn
    }
}

enum ProcessRunner {
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], cwd: URL? = nil) throws -> String {
        try capture(executable, arguments, cwd: cwd)
    }

    static func capture(_ executable: String, _ arguments: [String], cwd: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd {
            process.currentDirectoryURL = cwd
        }
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outputData, encoding: .utf8) ?? ""
        let stderr = String(data: errorData, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw FeatherError.message("\(URL(fileURLWithPath: executable).lastPathComponent) failed: \(stderr.nonEmpty ?? stdout)")
        }
        return stdout
    }
}

enum FeatherError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}

extension ASRepository.App {
    var stableID: String {
        id ?? name ?? downloadURL?.absoluteString ?? UUID().uuidString
    }

    var bestDownloadURL: URL? {
        if let versionURL = versions?.first?.downloadURL {
            return versionURL
        }
        return downloadURL
    }

    var bestVersion: String {
        versions?.first?.version ?? version ?? "Unknown"
    }

    var sizeText: String {
        guard let size else { return "" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

extension JSONDecoder {
    static var altSource: JSONDecoder {
        let decoder = JSONDecoder()
        return decoder
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nonEmpty: String? { isEmpty ? nil : self }
    var lines: [String] {
        split(whereSeparator: \.isNewline)
            .map { String($0).trimmed }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension FileManager {
    func removeItemIfExists(at url: URL) throws {
        if fileExists(atPath: url.path) {
            try removeItem(at: url)
        }
    }

    func copyItemReplacing(from source: URL, to destination: URL) throws {
        try removeItemIfExists(at: destination)
        try copyItem(at: source, to: destination)
    }

    func recursiveFiles(at url: URL) throws -> [URL] {
        guard let enumerator = enumerator(at: url, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }
    }
}

extension NSImage {
    func pngData(square size: Int) throws -> Data {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        let sourceSize = self.size
        let ratio = min(CGFloat(size) / max(sourceSize.width, 1), CGFloat(size) / max(sourceSize.height, 1))
        let drawSize = NSSize(width: sourceSize.width * ratio, height: sourceSize.height * ratio)
        let rect = NSRect(
            x: (CGFloat(size) - drawSize.width) / 2,
            y: (CGFloat(size) - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        draw(in: rect)
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            throw FeatherError.message("Could not render PNG icon.")
        }
        return data
    }
}

func applyRules(_ text: String, _ apply: (String, String) -> Void) {
    for line in text.lines {
        let parts: [String]
        if line.contains("=") {
            parts = line.components(separatedBy: "=")
        } else if line.contains("->") {
            parts = line.components(separatedBy: "->")
        } else {
            continue
        }
        guard parts.count >= 2 else { continue }
        let old = parts[0].trimmed
        let new = parts.dropFirst().joined(separator: "=").trimmed
        guard !old.isEmpty else { continue }
        apply(old, new)
    }
}

func replaceStrings(in object: Any, old: String, new: String) {
    if let dict = object as? NSMutableDictionary {
        for key in dict.allKeys {
            if let string = dict[key] as? String {
                dict[key] = string.replacingOccurrences(of: old, with: new)
            } else if let child = dict[key] as? NSMutableDictionary {
                replaceStrings(in: child, old: old, new: new)
            } else if let child = dict[key] as? NSMutableArray {
                replaceStrings(in: child, old: old, new: new)
            }
        }
    } else if let array = object as? NSMutableArray {
        for index in 0..<array.count {
            if let string = array[index] as? String {
                array[index] = string.replacingOccurrences(of: old, with: new)
            } else {
                replaceStrings(in: array[index], old: old, new: new)
            }
        }
    }
}
