import Foundation
import Darwin
import ZsignSwift

struct E2EError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

func fail(_ message: String) -> Never {
    fputs("ERROR: \(message)\n", stderr)
    exit(1)
}

func value(after key: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else {
        return nil
    }
    return args[index + 1]
}

func requiredValue(after key: String) -> String {
    guard let value = value(after: key) else {
        fail("Missing \(key)")
    }
    return value
}

func values(after key: String) -> [String] {
    let args = CommandLine.arguments
    return args.indices.compactMap { index in
        guard args[index] == key, args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }
}

func run(_ executable: String, _ arguments: [String], cwd: URL? = nil) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = cwd
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if process.terminationStatus != 0 {
        throw E2EError(message: "\(URL(fileURLWithPath: executable).lastPathComponent) failed: \(error.isEmpty ? output : error)")
    }
    return output
}

func writePlist(_ object: Any, to url: URL) throws {
    let data = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    try data.write(to: url)
}

func firstExecutable(_ names: [String]) -> String? {
    let folders = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    for name in names {
        for folder in folders {
            let path = URL(fileURLWithPath: folder).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
    }
    return nil
}

func readPlist(_ url: URL) throws -> NSMutableDictionary {
    guard let dict = NSMutableDictionary(contentsOf: url) else {
        throw E2EError(message: "Could not read plist at \(url.path)")
    }
    return dict
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

func recursiveFiles(at url: URL) throws -> [URL] {
    guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else {
        return []
    }
    return enumerator.compactMap { $0 as? URL }
}

func profilePlist(_ profile: URL) throws -> NSDictionary {
    let xml = try run("/usr/bin/security", ["cms", "-D", "-i", profile.path])
    guard let data = xml.data(using: .utf8),
          let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? NSDictionary else {
        throw E2EError(message: "Could not decode provisioning profile \(profile.path)")
    }
    return plist
}

func entitlements(from profile: URL, to url: URL) throws {
    let plist = try profilePlist(profile)
    guard let entitlements = plist["Entitlements"] as? NSDictionary else {
        throw E2EError(message: "Provisioning profile \(profile.lastPathComponent) has no entitlements.")
    }
    try writePlist(entitlements, to: url)
}

func bundleID(at bundle: URL) -> String? {
    let info = bundle.appendingPathComponent("Info.plist")
    return NSDictionary(contentsOf: info)?["CFBundleIdentifier"] as? String
}

func depth(_ url: URL) -> Int {
    url.pathComponents.count
}

func createSigningIdentity(p12: URL, password: String, work: URL) throws -> (keychain: URL, identity: String) {
    let keychain = work.appendingPathComponent("codesign-\(UUID().uuidString).keychain-db")
    let keychainPassword = UUID().uuidString
    _ = try run("/usr/bin/security", ["create-keychain", "-p", keychainPassword, keychain.path])
    _ = try run("/usr/bin/security", ["set-keychain-settings", "-lut", "21600", keychain.path])
    _ = try run("/usr/bin/security", ["unlock-keychain", "-p", keychainPassword, keychain.path])
    _ = try run("/usr/bin/security", ["import", p12.path, "-k", keychain.path, "-P", password, "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"])
    _ = try? run("/usr/bin/security", ["set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", keychainPassword, keychain.path])
    let identities = try run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning", keychain.path])
    guard let line = identities.split(separator: "\n").first(where: { $0.contains("\"") }) else {
        throw E2EError(message: "No code signing identity found in \(p12.path)")
    }
    let fields = line.split(separator: " ", omittingEmptySubsequences: true)
    guard fields.count >= 2 else {
        throw E2EError(message: "Could not parse signing identity: \(line)")
    }
    return (keychain, String(fields[1]))
}

func signPath(_ target: URL, identity: String, keychain: URL, entitlements: URL? = nil) throws {
    var args = ["--force", "--sign", identity, "--keychain", keychain.path, "--timestamp=none"]
    if let entitlements {
        args += ["--entitlements", entitlements.path, "--generate-entitlement-der"]
    }
    args.append(target.path)
    _ = try run("/usr/bin/codesign", args)
}

func nativeSign(appURL: URL, mainProfile: URL, extensionProfiles: [String: URL], p12: URL, password: String, work: URL) throws {
    let identity = try createSigningIdentity(p12: p12, password: password, work: work)
    defer { _ = try? run("/usr/bin/security", ["delete-keychain", identity.keychain.path]) }

    let codeObjects = try recursiveFiles(at: appURL).filter { url in
        let ext = url.pathExtension.lowercased()
        return ext == "framework" || ext == "dylib" || ext == "appex"
    }.sorted { depth($0) > depth($1) }

    for object in codeObjects {
        let ext = object.pathExtension.lowercased()
        if ext == "appex" {
            guard let id = bundleID(at: object) else {
                throw E2EError(message: "Missing bundle identifier for \(object.path)")
            }
            guard let profile = extensionProfiles[id] else {
                throw E2EError(message: "Missing --extension-profile for \(id)")
            }
            try FileManager.default.copyItemReplacing(from: profile, to: object.appendingPathComponent("embedded.mobileprovision"))
            let entitlementsURL = work.appendingPathComponent("\(id).entitlements.plist")
            try entitlements(from: profile, to: entitlementsURL)
            try signPath(object, identity: identity.identity, keychain: identity.keychain, entitlements: entitlementsURL)
        } else {
            try signPath(object, identity: identity.identity, keychain: identity.keychain)
        }
    }

    guard let mainID = bundleID(at: appURL) else {
        throw E2EError(message: "Missing main app bundle identifier.")
    }
    try FileManager.default.copyItemReplacing(from: mainProfile, to: appURL.appendingPathComponent("embedded.mobileprovision"))
    let mainEntitlementsURL = work.appendingPathComponent("\(mainID).entitlements.plist")
    try entitlements(from: mainProfile, to: mainEntitlementsURL)
    try signPath(appURL, identity: identity.identity, keychain: identity.keychain, entitlements: mainEntitlementsURL)
}

func zsign(appPath: URL, profile: URL, p12: URL, password: String) throws {
    var callbackError: Error?
    let ok = Zsign.sign(
        appPath: appPath.path,
        provisionPath: profile.path,
        p12Path: p12.path,
        p12Password: password,
        entitlementsPath: "",
        removeProvision: true
    ) { _, error in
        callbackError = error
    }
    if let callbackError {
        throw callbackError
    }
    if !ok {
        throw E2EError(message: "Zsign returned failure for \(appPath.path).")
    }
}

func zsignTopLevelOnly(appPath: URL, profile: URL, p12: URL, password: String) throws {
    setenv("ZSIGN_SKIP_NESTED_BUNDLES", "1", 1)
    defer { unsetenv("ZSIGN_SKIP_NESTED_BUNDLES") }
    try zsign(appPath: appPath, profile: profile, p12: p12, password: password)
}

func zsignBundleSpecific(appURL: URL, mainProfile: URL, extensionProfiles: [String: URL], p12: URL, password: String) throws {
    try zsign(appPath: appURL, profile: mainProfile, p12: p12, password: password)
    let extensions = try recursiveFiles(at: appURL).filter { $0.pathExtension == "appex" }
    for appex in extensions {
        guard let id = bundleID(at: appex) else {
            throw E2EError(message: "Missing bundle identifier for \(appex.path)")
        }
        guard let profile = extensionProfiles[id] else {
            throw E2EError(message: "Missing --extension-profile for \(id)")
        }
        try zsign(appPath: appex, profile: profile, p12: p12, password: password)
    }
    try zsignTopLevelOnly(appPath: appURL, profile: mainProfile, p12: p12, password: password)
}

let ipaPath = requiredValue(after: "--ipa")
let p12Path = requiredValue(after: "--p12")
let password = requiredValue(after: "--password")
let profilePath = requiredValue(after: "--profile")
let bundleID = requiredValue(after: "--bundle-id")
let displayName = value(after: "--name") ?? "FeatherMac Test"
let outputDirectory = URL(fileURLWithPath: value(after: "--out") ?? FileManager.default.currentDirectoryPath)
let extensionProfiles = Dictionary(uniqueKeysWithValues: values(after: "--extension-profile").map { value -> (String, URL) in
    let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
    guard parts.count == 2 else {
        fail("--extension-profile must be formatted as bundle.id=/path/to/profile.mobileprovision")
    }
    return (parts[0], URL(fileURLWithPath: parts[1]))
})

let ipaURL = URL(fileURLWithPath: ipaPath)
let p12URL = URL(fileURLWithPath: p12Path)
let profileURL = URL(fileURLWithPath: profilePath)

do {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let work = outputDirectory.appendingPathComponent("work-\(UUID().uuidString)", isDirectory: true)
    let signedIPA = outputDirectory.appendingPathComponent("Clip-FeatherMac-Signed.ipa")
    defer { try? FileManager.default.removeItem(at: work) }

    try FileManager.default.removeItemIfExists(at: signedIPA)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

    print("Unzipping IPA...")
    _ = try run("/usr/bin/unzip", ["-q", ipaURL.path, "-d", work.path])

    let payload = work.appendingPathComponent("Payload", isDirectory: true)
    let appURL = try FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
        .first { $0.pathExtension == "app" }
        ?? { throw E2EError(message: "Payload does not contain an .app bundle.") }()

    let infoURL = appURL.appendingPathComponent("Info.plist")
    let info = try readPlist(infoURL)
    let oldBundleID = info["CFBundleIdentifier"] as? String ?? ""
    replaceStrings(in: info, old: oldBundleID, new: bundleID)
    info["CFBundleIdentifier"] = bundleID
    info["CFBundleDisplayName"] = displayName
    info["CFBundleName"] = displayName
    info.removeObject(forKey: "UISupportedDevices")
    try info.write(to: infoURL)
    for bundle in try recursiveFiles(at: appURL).filter({ $0.pathExtension == "appex" || $0.pathExtension == "app" }) {
        let pluginInfoURL = bundle.appendingPathComponent("Info.plist")
        guard let pluginInfo = NSMutableDictionary(contentsOf: pluginInfoURL) else { continue }
        replaceStrings(in: pluginInfo, old: oldBundleID, new: bundleID)
        try pluginInfo.write(to: pluginInfoURL)
    }
    for profile in try recursiveFiles(at: appURL).filter({ $0.lastPathComponent == "embedded.mobileprovision" }) {
        try FileManager.default.removeItemIfExists(at: profile)
    }
    print("Changed bundle id: \(oldBundleID) -> \(bundleID)")

    if extensionProfiles.isEmpty {
        print("Signing with Zsign...")
        var callbackError: Error?
        let ok = Zsign.sign(
            appPath: appURL.path,
            provisionPath: profileURL.path,
            p12Path: p12URL.path,
            p12Password: password,
            entitlementsPath: "",
            removeProvision: true
        ) { _, error in
            callbackError = error
        }
        if let callbackError {
            throw callbackError
        }
        if !ok {
            throw E2EError(message: "Zsign returned failure.")
        }
    } else {
        print("Signing with Zsign and bundle-specific provisioning profiles...")
        try zsignBundleSpecific(appURL: appURL, mainProfile: profileURL, extensionProfiles: extensionProfiles, p12: p12URL, password: password)
        _ = try? nativeSign(appURL: appURL, mainProfile: profileURL, extensionProfiles: extensionProfiles, p12: p12URL, password: password, work: work)
    }

    print("Packaging signed IPA...")
    _ = try run("/usr/bin/zip", ["-qry", signedIPA.path, "Payload"], cwd: work)
    print("Signed IPA: \(signedIPA.path)")

    if let ideviceinstaller = firstExecutable(["ideviceinstaller"]) {
        print("Installing with ideviceinstaller...")
        let output = try run(ideviceinstaller, ["install", signedIPA.path])
        print(output)
    } else if let iosDeploy = firstExecutable(["ios-deploy"]) {
        print("Installing with ios-deploy...")
        let output = try run(iosDeploy, ["--bundle", signedIPA.path])
        print(output)
    } else {
        throw E2EError(message: "No install tool found.")
    }

    print("E2E sign/install test completed.")
} catch {
    fail(error.localizedDescription)
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
}
