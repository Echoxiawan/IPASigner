import Foundation

enum Installer {

    /// 优先走 Xcode CoreDevice；旧设备或没有 CoreDevice 标识时回退到 ideviceinstaller。
    static func install(ipaPath: String, device: DeviceInfo, log: @escaping (String) -> Void) throws {
        if let coreDeviceIdentifier = device.coreDeviceIdentifier {
            try installWithCoreDevice(ipaPath: ipaPath,
                                      identifier: coreDeviceIdentifier,
                                      device: device,
                                      log: log)
        } else {
            try installWithLibimobiledevice(ipaPath: ipaPath,
                                            udid: device.udid,
                                            device: device,
                                            log: log)
        }
    }

    private static func installWithCoreDevice(ipaPath: String,
                                              identifier: String,
                                              device: DeviceInfo,
                                              log: @escaping (String) -> Void) throws {
        let xcrun = try ToolPath.require("xcrun")
        let fm = FileManager.default
        let work = try Util.tempDir("coredevice-install")
        defer { try? fm.removeItem(atPath: work) }

        log("⑧ 开始安装 → \(device.display)")
        log("   安装通道: Xcode CoreDevice")

        let unzip = "/usr/bin/unzip"
        let unpack = Shell.run(unzip, ["-q", "-o", ipaPath, "-d", work])
        guard unpack.ok else {
            throw ToolError.failed("CoreDevice 安装前解包失败: \(unpack.combined)")
        }

        let payloadPath = work + "/Payload"
        guard let entries = try? fm.contentsOfDirectory(atPath: payloadPath),
              let appName = entries.first(where: { $0.hasSuffix(".app") }) else {
            throw ToolError.failed("CoreDevice 安装前没找到 Payload/*.app")
        }
        let appPath = payloadPath + "/" + appName
        log("   应用包: \(appName)")

        let code = try Shell.stream(xcrun, ["devicectl", "device", "install", "app",
                                            "--device", identifier,
                                            "--timeout", "180",
                                            appPath]) { chunk in
            logChunk(chunk, log: log)
        }
        guard code == 0 else {
            throw ToolError.failed("安装失败，devicectl 退出码 \(code)")
        }
        log("⑨ 安装完成")
    }

    private static func installWithLibimobiledevice(ipaPath: String,
                                                    udid: String,
                                                    device: DeviceInfo,
                                                    log: @escaping (String) -> Void) throws {
        let tool = try ToolPath.require("ideviceinstaller")
        log("⑧ 开始安装 → \(device.display)")
        log("   安装通道: libimobiledevice")
        var buffer = ""
        let code = try Shell.stream(tool, ["-u", udid, "-i", ipaPath]) { chunk in
            buffer += chunk.replacingOccurrences(of: "\r", with: "\n")
            var lines = buffer.components(separatedBy: "\n")
            buffer = lines.removeLast()   // 最后一段可能不完整，留到下次
            for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                log("   " + line.trimmingCharacters(in: .whitespaces))
            }
        }
        if !buffer.trimmingCharacters(in: .whitespaces).isEmpty {
            log("   " + buffer.trimmingCharacters(in: .whitespaces))
        }
        guard code == 0 else { throw ToolError.failed("安装失败，ideviceinstaller 退出码 \(code)") }
        log("⑨ 安装完成")
    }

    /// 装完顺手拉起来；CoreDevice 直接启动，旧设备继续使用 pymobiledevice3。
    static func launch(bundleID: String, device: DeviceInfo, log: @escaping (String) -> Void) {
        if let identifier = device.coreDeviceIdentifier {
            launchWithCoreDevice(bundleID: bundleID, identifier: identifier, log: log)
        } else {
            launchWithLibimobiledevice(bundleID: bundleID, log: log)
        }
    }

    private static func launchWithCoreDevice(bundleID: String,
                                             identifier: String,
                                             log: @escaping (String) -> Void) {
        guard let xcrun = ToolPath.find("xcrun") else {
            log("（跳过启动：找不到 xcrun）")
            return
        }
        log("⑩ 启动 \(bundleID) …")
        do {
            let code = try Shell.stream(xcrun, ["devicectl", "device", "process", "launch",
                                                "--device", identifier,
                                                bundleID]) { chunk in
                logChunk(chunk, log: log)
            }
            if code != 0 {
                log("   （没拉起来：确认设备已解锁；安装本身已完成，也可手动点图标打开）")
            }
        } catch {
            log("   （启动失败：\(error.localizedDescription)）")
        }
    }

    private static func launchWithLibimobiledevice(bundleID: String,
                                                   log: @escaping (String) -> Void) {
        guard let python = ToolPath.find("python3") else {
            log("（跳过启动：没有 python3）")
            return
        }
        let check = Shell.run(python, ["-c", "import pymobiledevice3"])
        guard check.ok else {
            log("（跳过启动：未安装 pymobiledevice3，可选 pip install pymobiledevice3）")
            return
        }

        // 先确保开发者磁盘镜像挂着，否则 developer 服务连不上
        _ = try? Shell.stream(python, ["-m", "pymobiledevice3", "mounter", "auto-mount"]) { _ in }

        log("⑩ 启动 \(bundleID) …")
        do {
            let code = try Shell.stream(python, ["-m", "pymobiledevice3", "developer", "dvt", "launch", bundleID]) { chunk in
                let text = chunk.replacingOccurrences(of: "\r", with: "\n")
                    .components(separatedBy: "\n")
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    .filter { line in
                        let bad = ["RequestsDependencyWarning", "warnings.warn", "urllib3", "For more information",
                                   "Please file a bug", "A bug.", "Apple removed this service",
                                   "https://", "tunneld must be running", "Possible reasons",
                                   "NSLocalized", "0x1", "Error Domain", "UserInfo"]
                        return !bad.contains(where: { line.contains($0) })
                    }
                    .joined(separator: "\n")
                if !text.isEmpty { log("   " + text) }
            }
            if code != 0 {
                log("   （没拉起来：设备要解锁，开发者磁盘镜像要挂上；反正装好了，点图标手动开一样）")
            }
        } catch {
            log("   （启动失败：\(error.localizedDescription)）")
        }
    }

    private static func logChunk(_ chunk: String, log: @escaping (String) -> Void) {
        let text = chunk.replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        if !text.isEmpty { log("   " + text) }
    }
}
