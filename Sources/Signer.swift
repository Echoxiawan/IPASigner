import Foundation

struct SignRequest {
    let ipa: IPAInfo
    let identity: SigningIdentity
    let profile: ProvisioningProfile
    let outputPath: String
}

enum Signer {

    /// 完整重签流程：解包 → 由内到外签名 → 嵌入描述文件 → 复签主程序 → 校验 → 打包
    @discardableResult
    static func sign(_ req: SignRequest, log: @escaping (String) -> Void) throws -> String {
        let fm = FileManager.default
        let codesign = try ToolPath.require("codesign")
        let unzip = "/usr/bin/unzip"

        let work = try Util.tempDir("work")
        defer { try? fm.removeItem(atPath: work) }

        // 1. 解包
        log("① 解包 \(req.ipa.fileName) → 临时目录")
        let unzipResult = Shell.run(unzip, ["-q", "-o", req.ipa.path, "-d", work])
        guard unzipResult.ok else { throw ToolError.failed("解包失败: \(unzipResult.combined)") }

        let appPath = work + "/" + req.ipa.appBundleRelativePath
        guard fm.fileExists(atPath: appPath) else {
            throw ToolError.failed("解包后没找到 app 包: \(appPath)")
        }

        // 2. 权限
        let team = req.identity.team.isEmpty ? req.profile.team : req.identity.team
        guard !team.isEmpty else { throw ToolError.failed("无法确定团队 ID（证书 OU 为空）") }
        let entitlements = try buildEntitlements(profile: req.profile, bundleID: req.ipa.bundleID, team: team)
        let entitlementsPath = work + "/entitlements.plist"
        try Util.writePlist(entitlements, to: entitlementsPath)
        log("② 权限: application-identifier = \(entitlements["application-identifier"] as? String ?? "-")，get-task-allow = \(req.profile.getTaskAllow)")

        // 3. 收集可执行文件，由深到浅
        let mainExe = appPath + "/" + req.ipa.executableName
        var targets = signingTargets(appPath: appPath)
        targets.removeAll { $0 == mainExe }
        targets.sort { depth($0) > depth($1) }
        log("③ 需要签名的二进制共 \(targets.count + 1) 个（含主程序）")

        for target in targets {
            let r = Shell.run(codesign, ["--force", "--sign", req.identity.sha1,
                                         "--timestamp=none", "--generate-entitlement-der", target])
            if !r.ok {
                throw ToolError.failed("签名失败 \(relative(target, appPath)): \(r.combined)")
            }
        }
        log("   内层二进制 + 嵌套 framework 全部签完")

        // 4. 嵌入描述文件（必须在主程序签名之前，才会被封进 CodeResources）
        let profileDest = appPath + "/embedded.mobileprovision"
        if fm.fileExists(atPath: profileDest) { try? fm.removeItem(atPath: profileDest) }
        try fm.copyItem(atPath: req.profile.path, toPath: profileDest)
        log("④ 已嵌入描述文件: \(req.profile.name)")

        // 5. 主程序带头签
        let mainSign = Shell.run(codesign, ["--force", "--sign", req.identity.sha1,
                                            "--timestamp=none", "--generate-entitlement-der",
                                            "--entitlements", entitlementsPath, mainExe])
        guard mainSign.ok else { throw ToolError.failed("主程序签名失败: \(mainSign.combined)") }
        log("⑤ 主程序已签名，身份: \(req.identity.name)")

        // 6. 自检
        let verify = Shell.run(codesign, ["--verify", "--deep", "--strict", "--verbose=2", appPath])
        guard verify.ok else { throw ToolError.failed("签名自检失败: \(verify.combined)") }
        log("⑥ 自检通过: valid on disk / satisfies its Designated Requirement")

        // 7. 打包：用 zip 而不是 ditto —— ditto 会带进 ._ 资源分叉文件，设备端会报 CFBundle 创建失败
        let outURL = URL(fileURLWithPath: req.outputPath)
        try? fm.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: req.outputPath) { try? fm.removeItem(atPath: req.outputPath) }
        let zip = try ToolPath.require("zip")
        let pack = Shell.run(zip, ["-qry", req.outputPath, "Payload"], cwd: work)
        guard pack.ok, fm.fileExists(atPath: req.outputPath) else {
            throw ToolError.failed("打包失败: \(pack.combined)")
        }
        log("⑦ 输出: \(req.outputPath)（\(Util.fileSize(req.outputPath))）")
        return req.outputPath
    }

    // MARK: - 权限生成

    static func buildEntitlements(profile: ProvisioningProfile, bundleID: String, team: String) throws -> [String: Any] {
        let appID: String
        if profile.isWildcard {
            appID = "\(team).\(bundleID)"
        } else {
            let expected = "\(team).\(bundleID)"
            guard profile.appID == expected || profile.appID == "*" else {
                throw ToolError.failed("这个描述文件绑定的是 \(profile.appID)，非通配描述文件只能签同 ID 的包")
            }
            appID = expected
        }

        var groups: [String] = []
        for group in profile.keychainGroups {
            if group.contains("*") {
                if !groups.contains(appID) { groups.append(appID) }
            } else {
                if !groups.contains(group) { groups.append(group) }
            }
        }
        if groups.isEmpty { groups = [appID] }

        return [
            "application-identifier": appID,
            "com.apple.developer.team-identifier": team,
            "get-task-allow": profile.getTaskAllow,
            "keychain-access-groups": groups
        ]
    }

    // MARK: - 目标收集

    /// 找出包里所有 Mach-O；framework / appex / bundle 的可执行文件折叠成签整个目录
    static func signingTargets(appPath: String) -> [String] {
        let fm = FileManager.default
        var files: [String] = []
        guard let en = fm.enumerator(atPath: appPath) else { return [] }
        while let rel = en.nextObject() as? String {
            let full = appPath + "/" + rel
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue { continue }
            if MachO.isMachO(full) { files.append(full) }
        }

        var targets = Set<String>()
        for file in files {
            let parent = (file as NSString).deletingLastPathComponent
            let parentName = (parent as NSString).lastPathComponent
            let fileName = (file as NSString).lastPathComponent
            let bundleSuffixes = [".framework", ".appex", ".bundle", ".xpc"]
            if let suffix = bundleSuffixes.first(where: { parentName.hasSuffix($0) }),
               fileName == String(parentName.dropLast(suffix.count)) {
                targets.insert(parent)   // 签目录，不单签里面的可执行文件
            } else {
                targets.insert(file)
            }
        }
        return Array(targets)
    }

    private static func depth(_ path: String) -> Int {
        path.components(separatedBy: "/").count
    }

    private static func relative(_ path: String, _ base: String) -> String {
        path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
    }
}
