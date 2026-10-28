import Foundation

enum Installer {

    /// 通过 ideviceinstaller 安装到指定 UDID 的设备，进度实时回调
    static func install(ipaPath: String, udid: String, log: @escaping (String) -> Void) throws {
        let tool = try ToolPath.require("ideviceinstaller")
        log("⑧ 开始安装 → 设备 \(udid)")
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

    /// 装完顺手拉起来（依赖 pymobiledevice3，没有就跳过，不影响安装结果）
    static func launch(bundleID: String, log: @escaping (String) -> Void) {
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
}
