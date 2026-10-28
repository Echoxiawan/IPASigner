import Foundation

/// 同一套引擎的命令行入口：构建后可用 `IPASigner.app/Contents/MacOS/IPASigner --list` 之类自测
enum CLIMode {

    static func handleIfNeeded() -> Bool {
        let args = Array(CommandLine.arguments.dropFirst())
        let triggers = ["--cli", "--list", "--sign", "--help-cli"]
        guard args.contains(where: { triggers.contains($0) }) else { return false }
        run(args)
        return true
    }

    private static func value(_ flag: String, _ args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func usage() {
        print("""
        用法:
          --list                                     列出证书 / 描述文件 / 设备
          --sign --ipa <路径> [选项]                  重签名
              --device <UDID>                        目标设备（决定描述文件要不要含 UDID）
              --identity <证书SHA1>                   指定证书
              --profile <描述文件路径>                 指定描述文件
              --out <输出ipa路径>                     默认 <原名>-signed.ipa
              --install                              签完直接装
              --launch                               装完拉起
        """)
    }

    private static func run(_ args: [String]) {
        if args.contains("--help-cli") { usage(); exit(0) }
        if args.contains("--list") { list(); exit(0) }
        if args.contains("--sign"), let path = value("--ipa", args) {
            sign(args, ipaPath: path)
        }
        usage()
        exit(2)
    }

    // MARK: - 列表

    private static func list() {
        let identities = Discovery.identities()
        print("== 签名证书 (\(identities.count)) ==")
        for i in identities {
            print("  \(i.sha1)  \(i.name)  团队 \(i.team.isEmpty ? "-" : i.team)")
        }

        let profiles = Discovery.profiles()
        print("\n== 描述文件 (\(profiles.count)) ==")
        for p in profiles {
            print("  \(p.isExpired ? "已过期" : "有效")  \(p.appID)  \(Util.dateString(p.expiration))  设备 \(p.devices.count)  \(p.name)")
        }

        do {
            let devices = try Discovery.devices()
            print("\n== 连接设备 (\(devices.count)) ==")
            for d in devices {
                print("  \(d.udid)  \(d.display)")
            }
        } catch {
            print("\n== 连接设备 ==\n  \(error.localizedDescription)")
        }
    }

    // MARK: - 签名

    private static func sign(_ args: [String], ipaPath: String) {
        do {
            let ipa = try Discovery.inspectIPA(path: ipaPath)
            print("包: \(ipa.summary)")

            var identities = Discovery.identities()
            var profiles = Discovery.profiles()

            if let sha = value("--identity", args)?.uppercased() {
                identities = identities.filter { $0.sha1 == sha }
            }
            if let profilePath = value("--profile", args) {
                let expanded = Util.expand(profilePath)
                profiles = profiles.filter { $0.path == expanded }
                if profiles.isEmpty, let p = Discovery.parseProfile(path: expanded) {
                    profiles = [p]
                }
            }

            guard let deviceUDID = value("--device", args) else {
                throw ToolError.failed("必须带 --device <UDID>（--list 里能看到）")
            }

            let candidates = Discovery.candidates(identities: identities,
                                                  profiles: profiles,
                                                  bundleID: ipa.bundleID,
                                                  deviceUDID: deviceUDID)
            guard let chosen = candidates.first else {
                throw ToolError.failed("没有匹配的证书 + 描述文件组合（检查是否已过期 / 是否包含设备 \(deviceUDID)）")
            }
            print("选中文档: \(chosen.identity.name) + \(chosen.profile.name)")

            let out = value("--out", args) ?? defaultOutput(ipaPath)
            let request = SignRequest(ipa: ipa, identity: chosen.identity, profile: chosen.profile, outputPath: out)
            let signed = try Signer.sign(request) { print($0) }

            if args.contains("--install") {
                try Installer.install(ipaPath: signed, udid: deviceUDID) { print($0) }
                if args.contains("--launch") {
                    Installer.launch(bundleID: ipa.bundleID) { print($0) }
                }
            }
            print("完成: \(signed)")
            exit(0)
        } catch {
            print("失败: \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func defaultOutput(_ ipaPath: String) -> String {
        let dir = (ipaPath as NSString).deletingLastPathComponent
        let base = ((ipaPath as NSString).lastPathComponent as NSString).deletingPathExtension
        return dir + "/" + base + "-signed.ipa"
    }
}
