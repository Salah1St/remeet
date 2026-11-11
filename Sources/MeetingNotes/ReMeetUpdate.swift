import Foundation

struct LocalInstallation: Decodable {
    let sourcePath: String
    let appPath: String

    static let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    static let releases = URL(string: "https://github.com/Salah1St/remeet/releases")!

    static func load() -> LocalInstallation? {
        let currentBundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let metadata = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/ReMeet/LocalInstall.json")
        guard let data = try? Data(contentsOf: metadata),
              let install = try? JSONDecoder().decode(Self.self, from: data),
              install.sourcePath.hasPrefix("/"), install.appPath.hasPrefix("/"),
              install.bundle.resolvingSymlinksInPath() == currentBundle else { return nil }
        return install
    }

    private var bundle: URL { URL(fileURLWithPath: appPath, isDirectory: true) }
    private var source: URL { URL(fileURLWithPath: sourcePath, isDirectory: true) }

    func update() async throws -> String {
        let script = source.appending(path: "scripts/install-local.sh")
        let versionFile = source.appending(path: "VERSION")
        guard FileManager.default.isExecutableFile(atPath: script.path),
              let version = try? String(contentsOf: versionFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else {
            throw UpdateError("ไม่พบซอร์ส ReMeet สำหรับอัปเดตที่ \(source.path)")
        }
        guard version.compare(Self.currentVersion, options: .numeric) == .orderedDescending else {
            return "ซอร์สในเครื่องยังไม่มีเวอร์ชันใหม่ ใช้ git pull --ff-only ในโฟลเดอร์ซอร์ส แล้วกดอัปเดตอีกครั้ง"
        }

        let logs = FileManager.default.temporaryDirectory.appending(path: "remeet-update-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: logs.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw UpdateError("สร้างไฟล์บันทึกการอัปเดตไม่ได้")
        }
        let log = try FileHandle(forWritingTo: logs)
        defer { try? log.close(); try? FileManager.default.removeItem(at: logs) }

        let process = Process()
        process.executableURL = script
        process.arguments = ["--app-dir", bundle.deletingLastPathComponent().path]
        process.currentDirectoryURL = source
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        environment.removeValue(forKey: "REMEET_VERSION")
        environment.removeValue(forKey: "REMEET_LOCAL_INSTALL_METADATA")
        process.environment = environment
        process.standardOutput = log
        process.standardError = log

        let result: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        guard result == 0 else {
            let tail = (try? String(contentsOf: logs, encoding: .utf8))?
                .split(whereSeparator: \.isNewline).suffix(5).joined(separator: "\n") ?? ""
            throw UpdateError("อัปเดต ReMeet ไม่สำเร็จ\n\(tail)")
        }
        return "ติดตั้งเวอร์ชัน \(version) แล้ว ปิด ReMeet แล้วเปิดแอปอีกครั้ง"
    }

    private struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
