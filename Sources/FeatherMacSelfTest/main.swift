import AltSourceKit
import Foundation

struct CheckFailure: Error, CustomStringConvertible {
    var description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw CheckFailure(description: message)
    }
}

func run(_ name: String, _ body: () throws -> Void) -> Bool {
    do {
        try body()
        print("PASS \(name)")
        return true
    } catch {
        print("FAIL \(name): \(error)")
        return false
    }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
var failures = 0

if !run("AltSource decoding", {
    let json = """
    {
      "name": "Demo Source",
      "identifier": "dev.demo.source",
      "apps": [
        {
          "name": "Demo App",
          "bundleIdentifier": "dev.demo.app",
          "developerName": "Demo",
          "version": "1.0",
          "iconURL": "https://example.com/icon.png",
          "downloadURL": "https://example.com/demo.ipa",
          "size": 1234
        }
      ]
    }
    """
    let repo = try JSONDecoder().decode(ASRepository.self, from: Data(json.utf8))
    try expect(repo.name == "Demo Source", "source name should decode")
    try expect(repo.apps.first?.name == "Demo App", "app name should decode")
    try expect(repo.apps.first?.downloadURL?.absoluteString == "https://example.com/demo.ipa", "download URL should decode")
}) { failures += 1 }

if !run("Chinese localization resources", {
    let strings = root.appendingPathComponent("Sources/FeatherMac/Resources/zh-Hans.lproj/Localizable.strings")
    let text = try String(contentsOf: strings, encoding: .utf8)
    try expect(text.contains("\"Library\" = \"资料库\";"), "Library should be localized")
    try expect(text.contains("\"Start Signing\" = \"开始签名\";"), "Signing action should be localized")
    try expect(text.contains("\"Language\" = \"语言\";"), "Language picker should be localized")
}) { failures += 1 }

if !run("Bundled ElleKit resource", {
    let elleKit = root.appendingPathComponent("Sources/FeatherMac/Resources/ellekit.deb")
    try expect(FileManager.default.fileExists(atPath: elleKit.path), "ellekit.deb should be bundled")
    let size = try elleKit.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    try expect(size > 1000, "ellekit.deb should not be empty")
}) { failures += 1 }

if !run("Required archive tools", {
    try expect(FileManager.default.isExecutableFile(atPath: "/usr/bin/zip"), "zip should exist")
    try expect(FileManager.default.isExecutableFile(atPath: "/usr/bin/unzip"), "unzip should exist")
    try expect(FileManager.default.isExecutableFile(atPath: "/usr/bin/security"), "security should exist")
}) { failures += 1 }

if !run("Device install tools", {
    try expect(
        FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ideviceinstaller")
            || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/ideviceinstaller"),
        "ideviceinstaller should be installed"
    )
    try expect(
        FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ios-deploy")
            || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/ios-deploy"),
        "ios-deploy should be installed"
    )
}) { failures += 1 }

if !run("App bundle Info.plist parsing", {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let app = temp.appendingPathComponent("Demo.app", isDirectory: true)
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    let plist: [String: Any] = [
        "CFBundleDisplayName": "Demo",
        "CFBundleIdentifier": "dev.demo.app",
        "CFBundleShortVersionString": "1.2.3"
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: app.appendingPathComponent("Info.plist"))
    let loaded = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist")) as? [String: Any]
    try expect(loaded?["CFBundleIdentifier"] as? String == "dev.demo.app", "bundle identifier should read back")
}) { failures += 1 }

if failures > 0 {
    print("\n\(failures) self-test(s) failed.")
    exit(1)
}

print("\nAll FeatherMac self-tests passed.")
