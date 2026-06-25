import AltSourceKit
import AppKit
import CryptoKit
import Darwin
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import ZsignSwift

@main
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
                try writePNG(of: window, to: outputDirectory.appendingPathComponent(filename))
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
                iconPath: nil,
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
                iconPath: nil,
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
        store.appStoreConnect = AppStoreConnectSettings(
            issuerID: "00000000-0000-0000-0000-000000000000",
            keyID: "DEMO123456",
            privateKeyPath: "~/Keys/AuthKey_DEMO123456.p8",
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

    private static func writePNG(of window: NSWindow, to url: URL) throws {
        guard let view = window.contentView else {
            throw NSError(domain: "FeatherMacScreenshots", code: 2, userInfo: [NSLocalizedDescriptionKey: "Window has no content view."])
        }
        let bounds = view.bounds
        let scale = window.backingScaleFactor
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * scale),
            pixelsHigh: Int(bounds.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw NSError(domain: "FeatherMacScreenshots", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not create bitmap representation."])
        }
        representation.size = bounds.size

        guard let context = NSGraphicsContext(bitmapImageRep: representation) else {
            throw NSError(domain: "FeatherMacScreenshots", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not create graphics context."])
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        view.displayIgnoringOpacity(bounds, in: context)
        NSGraphicsContext.restoreGraphicsState()

        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "FeatherMacScreenshots", code: 5, userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG."])
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
    var id = UUID()
    var url: URL
    var name: String
    var identifier: String?
    var iconURL: URL?
    var addedAt = Date()
}

struct RepoCache: Identifiable {
    var id: UUID { source.id }
    var source: SourceRecord
    var repository: ASRepository?
    var error: String?
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
    var provisionPath: String
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
    var provisionURL: URL { URL(fileURLWithPath: provisionPath) }
}

struct AppStoreConnectSettings: Codable, Equatable {
    var issuerID = ""
    var keyID = ""
    var privateKeyPath = ""
    var bundleIdentifierPrefix = ""
    var registerConnectedDevice = true
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
            if sources.isEmpty {
                sources = SourceService.defaultSources
                try storage.saveSources(sources)
            }
            selectedAppID = library.first?.id
            selectedCertID = certificates.first(where: \.isDefault)?.id ?? certificates.first?.id
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
                let repository = try await sourceService.fetch(url: source.url)
                if let index = repos.firstIndex(where: { $0.source.id == source.id }) {
                    repos[index].repository = repository
                    repos[index].error = nil
                }
                if let sourceIndex = sources.firstIndex(where: { $0.id == source.id }) {
                    sources[sourceIndex].name = repository.name ?? source.name
                    sources[sourceIndex].identifier = repository.id
                    sources[sourceIndex].iconURL = repository.currentIconURL
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
            let repo = try await sourceService.fetch(url: url)
            let source = SourceRecord(
                url: url,
                name: repo.name ?? url.host ?? url.absoluteString,
                identifier: repo.id,
                iconURL: repo.currentIconURL
            )
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
        let provision = FilePicker.open(types: [.init(filenameExtension: "mobileprovision")!, .init(filenameExtension: "provisionprofile")!])
        guard let provision else { return }
        await importCertificate(p12: p12, provision: provision, password: certificatePasswordDraft)
    }

    func importCertificate(p12: URL, provision: URL, password: String) async {
        await runBusy("Importing certificate...") {
            let cert = try CertificateService.importCertificate(p12: p12, provision: provision, password: password, storage: self.storage)
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
        await runBusy("Signing \(app.name)...") {
            let signed = try await self.ipaService.sign(app: app, certificate: cert, options: self.options, storage: self.storage) { message in
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

    func pickAutomationIcon() {
        let png = UTType.png
        let jpeg = UTType.jpeg
        if let url = FilePicker.open(types: [png, jpeg]) {
            automation.iconPath = url.path
            saveAll()
        }
    }

    func pickAppStoreConnectKey() {
        guard let p8 = UTType(filenameExtension: "p8"),
              let url = FilePicker.open(types: [p8]) else { return }
        appStoreConnect.privateKeyPath = url.path
        saveAll()
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
                appName: app.name,
                bundleIdentifier: suggestedIdentifier,
                certificate: workingCert,
                settings: configured
            )
            let profileDirectory = workingCert.p12URL.deletingLastPathComponent().appendingPathComponent("AutoProfiles", isDirectory: true)
            try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
            let profileURL = profileDirectory.appendingPathComponent("\(BundleIdentifierGenerator.safeComponent(suggestedIdentifier)).mobileprovision")
            try profile.data.write(to: profileURL, options: .atomic)
            let metadata = CertificateService.parseProvision(profileURL)
            workingCert.provisionPath = profileURL.path
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
        await runBusy("Running workflow...") {
            await MainActor.run {
                self.automation.resetRun()
                self.automation.activeStep = .selectApp
                self.saveAll()
                self.log(.info, "Workflow selected \(app.name).")
            }
            await self.finishAutomationStep(.selectApp)

            await MainActor.run { self.automation.activeStep = .createProfile }
            let configured = await MainActor.run { self.appStoreConnect }
            let bundleID = BundleIdentifierGenerator.suggestedIdentifier(
                app: app,
                certificate: cert,
                configuredPrefix: configured.bundleIdentifierPrefix
            )
            let updatedCert = try await self.createProvisioningProfile(app: app, certificate: cert, bundleIdentifier: bundleID, settings: configured)
            await MainActor.run {
                self.options.appName = app.name
                self.options.appIdentifier = bundleID
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
            let signed = try await self.ipaService.sign(app: app, certificate: updatedCert, options: workflowOptions, storage: self.storage) { message in
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

    private func createProvisioningProfile(app: LibraryApp, certificate: CertificateRecord, bundleIdentifier: String, settings: AppStoreConnectSettings) async throws -> CertificateRecord {
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
                appName: app.name,
                bundleIdentifier: bundleIdentifier,
                certificate: workingCert,
                settings: settings
            )
            try profile.data.write(to: profileURL, options: .atomic)
            profileName = profile.name
        }
        let metadata = CertificateService.parseProvision(profileURL)
        workingCert.provisionPath = profileURL.path
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
        return workingCert
    }

    private func reusableProvisioningProfile(for certificate: CertificateRecord, bundleIdentifier: String) -> URL? {
        let autoProfilesDirectory = certificate.p12URL.deletingLastPathComponent().appendingPathComponent("AutoProfiles", isDirectory: true)
        var candidates = [certificate.provisionURL]
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
        let keyDirectory = storage.root.appendingPathComponent("AppStoreConnect", isDirectory: true)
        try FileManager.default.createDirectory(at: keyDirectory, withIntermediateDirectories: true)
        let keyID = imported.keyID.trimmed.nonEmpty ?? "Imported"
        let keyURL = keyDirectory.appendingPathComponent("AuthKey_\(keyID).p8")
        try imported.privateKeyPEM.write(to: keyURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        appStoreConnect = AppStoreConnectSettings(
            issuerID: imported.issuerID,
            keyID: imported.keyID,
            privateKeyPath: keyURL.path,
            bundleIdentifierPrefix: imported.bundleIdentifierPrefix,
            registerConnectedDevice: imported.registerConnectedDevice
        )
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

    private func runBusy(_ text: String, operation: @escaping () async throws -> Void) async {
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
            } else {
                Text(L10n.string("Loading"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
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
                Text(L10n.string("Import Certificate"))
                    .font(.headline)
                SecureField(L10n.string("P12 password"), text: $store.certificatePasswordDraft)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await store.pickCertificateFiles() }
                } label: {
                    Label(L10n.string("Choose .p12 and .mobileprovision"), systemImage: "person.badge.key")
                }
                .buttonStyle(.borderedProminent)

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
                VStack(alignment: .leading, spacing: 16) {
                    Text(cert.nickname)
                        .font(.title2.weight(.semibold))
                    InfoGrid(items: [
                        ("Default", cert.isDefault ? L10n.string("Yes") : L10n.string("No")),
                        ("Team", cert.teamName ?? L10n.string("Unknown")),
                        ("App ID", cert.appIDName ?? L10n.string("Unknown")),
                        ("Expiration", cert.expiration?.formatted(date: .abbreviated, time: .omitted) ?? L10n.string("Unknown")),
                        ("P12", cert.p12Path),
                        ("Provision", cert.provisionPath)
                    ])
                    HStack {
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
                    Spacer()
                    LogPanel()
                }
                .padding(18)
            } else {
                EmptyState(title: L10n.string("No certificate imported"), systemImage: "person.text.rectangle")
            }
        }
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
                    }
                    .onChange(of: store.automation) { _, _ in store.saveAll() }
                    .onChange(of: store.appStoreConnect) { _, _ in store.saveAll() }

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
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                        GridRow {
                            Field("Issuer ID", text: $store.appStoreConnect.issuerID)
                            Field("Key ID", text: $store.appStoreConnect.keyID)
                        }
                        GridRow {
                            Field("Bundle Prefix", text: $store.appStoreConnect.bundleIdentifierPrefix)
                            Toggle(L10n.string("Register connected device"), isOn: $store.appStoreConnect.registerConnectedDevice)
                        }
                    }
                    .onChange(of: store.appStoreConnect) { _, _ in store.saveAll() }
                    HStack {
                        Text(store.appStoreConnect.privateKeyPath.isEmpty ? L10n.string("No API private key") : store.appStoreConnect.privateKeyPath)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            store.pickAppStoreConnectKey()
                        } label: {
                            Label(L10n.string("Choose .p8"), systemImage: "key")
                        }
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
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
    func loadCertificates() throws -> [CertificateRecord] { try load([CertificateRecord].self, from: certificatesFile, default: []) }
    func saveCertificates(_ value: [CertificateRecord]) throws { try save(value, to: certificatesFile) }
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
    }
}

final class SourceService: @unchecked Sendable {
    static let defaultSources: [SourceRecord] = [
        SourceRecord(url: URL(string: "https://raw.githubusercontent.com/SideStore/apps.json/refs/heads/main/apps.json")!, name: "SideStore"),
        SourceRecord(url: URL(string: "https://raw.githubusercontent.com/altstoreio/AltStore/refs/heads/master/apps.json")!, name: "AltStore"),
        SourceRecord(url: URL(string: "https://raw.githubusercontent.com/claration/Feather/refs/heads/main/app-repo.json")!, name: "Feather")
    ]

    func fetch(url: URL) async throws -> ASRepository {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw FeatherError.message("HTTP \(http.statusCode) for \(url.absoluteString)")
        }
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

    func sign(app: LibraryApp, certificate: CertificateRecord?, options: SigningOptions, storage: FeatherStorage, progress: @escaping @Sendable (String) -> Void) async throws -> LibraryApp {
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
            progress("Signing with Zsign...")
            try signWithProfiles(appURL: appURL, certificate: certificate, options: options)
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

    private func signWithProfiles(appURL: URL, certificate: CertificateRecord, options: SigningOptions) throws {
        let profiles = try provisioningProfiles(near: certificate.provisionURL)
        let extensionProfiles = try extensionProvisionProfiles(appURL: appURL, profiles: profiles)
        if extensionProfiles.isEmpty {
            try zsign(appURL: appURL, provisionURL: certificate.provisionURL, certificate: certificate, options: options)
            return
        }

        try zsign(appURL: appURL, provisionURL: certificate.provisionURL, certificate: certificate, options: options)
        for appex in try fileManager.recursiveFiles(at: appURL).filter({ $0.pathExtension == "appex" }) {
            guard let bundleID = Bundle(path: appex.path)?.bundleIdentifier,
                  let profile = extensionProfiles[bundleID] else {
                continue
            }
            try zsign(appURL: appex, provisionURL: profile, certificate: certificate, options: options)
        }
        setenv("ZSIGN_SKIP_NESTED_BUNDLES", "1", 1)
        defer { unsetenv("ZSIGN_SKIP_NESTED_BUNDLES") }
        try zsign(appURL: appURL, provisionURL: certificate.provisionURL, certificate: certificate, options: options)
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

enum CertificateService {
    static func importCertificate(p12: URL, provision: URL, password: String, storage: FeatherStorage) throws -> CertificateRecord {
        let id = UUID()
        let destination = storage.certificatesDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let p12Target = destination.appendingPathComponent("cert.p12")
        let provisionTarget = destination.appendingPathComponent("profile.mobileprovision")
        try FileManager.default.copyItem(at: p12, to: p12Target)
        try FileManager.default.copyItem(at: provision, to: provisionTarget)
        try copySiblingProvisioningProfiles(of: provision, into: destination)

        let metadata = parseProvision(provisionTarget)
        let serialNumber = try? p12CertificateSerialNumber(p12: p12Target, password: password)
        let nickname = metadata.teamName ?? metadata.appIDName ?? p12.deletingPathExtension().lastPathComponent
        return CertificateRecord(
            id: id,
            nickname: nickname,
            p12Path: p12Target.path,
            provisionPath: provisionTarget.path,
            password: password,
            expiration: metadata.expiration,
            teamName: metadata.teamName,
            teamIdentifier: metadata.teamIdentifier,
            appIdentifierPrefix: metadata.appIdentifierPrefix,
            appIDName: metadata.appIDName,
            p12SerialNumber: serialNumber,
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

    static func p12CertificateSerialNumber(p12: URL, password: String) throws -> String? {
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
        let serial = try ProcessRunner.capture("/usr/bin/openssl", ["x509", "-in", pem.path, "-serial", "-noout"])
        return serial
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "serial=", with: "")
            .replacingOccurrences(of: ":", with: "")
            .uppercased()
            .nonEmpty
    }

    private static func copySiblingProvisioningProfiles(of provision: URL, into destination: URL) throws {
        let sourceDirectory = provision.deletingLastPathComponent()
        let profiles = try FileManager.default.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil)
            .filter { ["mobileprovision", "provisionprofile"].contains($0.pathExtension.lowercased()) }
        for profile in profiles where profile.standardizedFileURL != provision.standardizedFileURL {
            let target = destination.appendingPathComponent(profile.lastPathComponent)
            try FileManager.default.copyItemReplacing(from: profile, to: target)
        }
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

final class AppleDeveloperService: @unchecked Sendable {
    private let baseURL = URL(string: "https://api.appstoreconnect.apple.com/v1")!

    func createDevelopmentProfile(appName: String, bundleIdentifier: String, certificate: CertificateRecord, settings: AppStoreConnectSettings) async throws -> CreatedProvisioningProfile {
        try validate(settings)
        let client = try AppStoreConnectClient(settings: settings, baseURL: baseURL)
        let bundleID = try await ensureBundleID(identifier: bundleIdentifier, name: appName, client: client)
        let device = try connectedDevice()
        let deviceResource = try await ensureDevice(device, settings: settings, client: client)
        let certificateResource = try await matchingCertificate(for: certificate, client: client)
        let profileName = "\(appName) Development \(bundleIdentifier)"
        return try await createProfile(
            name: profileName,
            bundleID: bundleID.id,
            certificateID: certificateResource.id,
            deviceID: deviceResource.id,
            client: client
        )
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
        let certificates = try await client.list(path: "certificates", filters: ["certificateType": "IOS_DEVELOPMENT"], limit: 200)
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

    private func request(url: URL, method: String, body: Data? = nil) async throws -> [String: Any] {
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
            throw FeatherError.message("Apple API HTTP \(http.statusCode): \(detail)")
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
