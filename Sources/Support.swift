import Foundation
import CryptoKit

// MARK: - 路径与工具定位

enum ToolPath {
    /// 先看 $PATH（这样 pyenv / 用户自装的工具也能找到），再回落到常见目录
    static let searchDirs: [String] = {
        var dirs: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs += path.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        }
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted }
    }()

    static func find(_ name: String) -> String? {
        for dir in searchDirs {
            let p = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static func require(_ name: String) throws -> String {
        guard let p = find(name) else { throw ToolError.missing(name) }
        return p
    }
}

enum ToolError: LocalizedError {
    case missing(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missing(let n): return "找不到命令行工具 \(n)，请先安装（brew install libimobiledevice）"
        case .failed(let m): return m
        }
    }
}

// MARK: - 进程执行

struct RunResult {
    let code: Int32
    let out: String
    let err: String

    var ok: Bool { code == 0 }
    var combined: String { (out + err).trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum Shell {
    /// 采集 stdout+stderr 后一次性返回（小输出用）
    static func run(_ exe: String, _ args: [String], cwd: String? = nil) -> RunResult {
        let (code, outData, errData) = runData(exe, args, cwd: cwd)
        return RunResult(code: code,
                         out: String(decoding: outData, as: UTF8.self),
                         err: String(decoding: errData, as: UTF8.self))
    }

    static func runData(_ exe: String, _ args: [String], cwd: String? = nil) -> (Int32, Data, Data) {
        guard FileManager.default.isExecutableFile(atPath: exe) else {
            return (-1, Data(), Data("找不到可执行文件: \(exe)".utf8))
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"].map { $0 + ":" } ?? "") + ToolPath.searchDirs.joined(separator: ":")
        p.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        do {
            try p.run()
        } catch {
            return (-1, Data(), Data("启动失败: \(error.localizedDescription)".utf8))
        }

        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.wait()
        p.waitUntilExit()
        return (p.terminationStatus, outData, errData)
    }

    /// 流式执行（安装进度用），逐块回调输出
    @discardableResult
    static func stream(_ exe: String, _ args: [String], onOutput: @escaping (String) -> Void) throws -> Int32 {
        guard FileManager.default.isExecutableFile(atPath: exe) else {
            throw ToolError.missing((exe as NSString).lastPathComponent)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"].map { $0 + ":" } ?? "") + ToolPath.searchDirs.joined(separator: ":")
        p.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        let handler: (FileHandle) -> Void = { fh in
            let d = fh.availableData
            if d.isEmpty {
                fh.readabilityHandler = nil
                return
            }
            if let s = String(data: d, encoding: .utf8) {
                onOutput(s)
            }
        }
        outPipe.fileHandleForReading.readabilityHandler = handler
        errPipe.fileHandleForReading.readabilityHandler = handler

        try p.run()
        p.waitUntilExit()
        // 收尾输出
        for fh in [outPipe.fileHandleForReading, errPipe.fileHandleForReading] {
            fh.readabilityHandler = nil
            let rest = fh.availableData
            if !rest.isEmpty, let s = String(data: rest, encoding: .utf8) { onOutput(s) }
        }
        return p.terminationStatus
    }
}

// MARK: - 哈希 / Mach-O

enum Hash {
    static func sha1(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha1File(_ path: String) -> String? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return sha1(d)
    }
}

enum MachO {
    private static let magics: Set<[UInt8]> = [
        [0xFE, 0xED, 0xFA, 0xCE],
        [0xCE, 0xFA, 0xED, 0xFE],
        [0xFE, 0xED, 0xFA, 0xCF],
        [0xCF, 0xFA, 0xED, 0xFE],
        [0xCA, 0xFE, 0xBA, 0xBE],
        [0xBE, 0xBA, 0xFE, 0xCA]
    ]

    static func isMachO(_ path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 4), head.count == 4 else { return false }
        return magics.contains([UInt8](head))
    }
}

// MARK: - 杂项

enum Util {
    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    static func dateString(_ date: Date?) -> String {
        guard let date else { return "-" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func fileSize(_ path: String) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    static func tempDir(_ tag: String) throws -> String {
        let dir = NSTemporaryDirectory() + "ipasigner-\(tag)-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    static func writePlist(_ object: Any, to path: String) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path))
    }

    static func readPlist(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }
}
