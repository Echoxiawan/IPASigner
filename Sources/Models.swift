import Foundation

// MARK: - 签名身份（钥匙串里的 Apple Development 证书）

struct SigningIdentity: Identifiable, Hashable {
    let sha1: String        // 大写十六进制，codesign -s 用它
    let name: String        // Apple Development: xxx (XXXX)
    let team: String        // 团队 ID（证书 OU）
    let commonName: String  // 证书 CN

    var id: String { sha1 }

    var shortLabel: String {
        "\(name)"
    }
}

// MARK: - 描述文件

struct ProvisioningProfile: Identifiable {
    let path: String
    let name: String
    let team: String
    let appID: String              // 形如 TEAMID.* 或 TEAMID.com.foo.bar
    let expiration: Date?
    let devices: Set<String>       // 已绑定的设备 UDID
    let certSHA1s: Set<String>     // 内嵌证书指纹
    let getTaskAllow: Bool
    let keychainGroups: [String]

    var id: String { path + "#" + name }

    var isExpired: Bool {
        guard let expiration else { return true }
        return expiration < Date()
    }

    var isWildcard: Bool {
        appID.hasSuffix("*")
    }

    /// 该描述文件能不能用来签这个 bundle id
    func appIDMatches(bundleID: String) -> Bool {
        let expected = "\(team).\(bundleID)"
        if appID == expected { return true }
        if appID == "\(team).*" || appID == "*" { return true }
        if appID.hasSuffix(".*") {
            let prefix = String(appID.dropLast(1)) // 去掉 "*"，保留结尾的点
            return expected.hasPrefix(prefix)
        }
        return false
    }

    var label: String {
        let kind = isWildcard ? "通配" : "指定"
        let flag = isExpired ? "已过期" : "有效至 \(Util.dateString(expiration))"
        return "\(name)（\(kind) · 团队 \(team) · \(flag) · 绑定 \(devices.count) 台设备）"
    }
}

// MARK: - 设备

struct DeviceInfo: Identifiable, Hashable {
    let udid: String
    let name: String
    let productType: String
    let osVersion: String

    var id: String { udid }

    var display: String {
        "\(name)  |  \(productType)  |  iOS \(osVersion)"
    }

    var shortUDID: String {
        udid.count > 12 ? String(udid.prefix(8)) + "…" + String(udid.suffix(4)) : udid
    }
}

// MARK: - IPA

struct IPAInfo {
    let path: String
    let bundleID: String
    let shortVersion: String
    let buildVersion: String
    let appName: String
    let minimumOS: String
    let appBundleRelativePath: String   // Payload/Dopamine.app/Info.plist
    let executableName: String

    var fileName: String { (path as NSString).lastPathComponent }

    var summary: String {
        "\(appName)  \(shortVersion) (\(buildVersion))  ·  \(bundleID)  ·  最低 iOS \(minimumOS)"
    }
}

// MARK: - 账号候选（证书 + 描述文件 + 设备 三者匹配后的结果）

struct SignCandidate: Identifiable, Hashable {
    let identity: SigningIdentity
    let profile: ProvisioningProfile

    var id: String { identity.sha1 + "|" + profile.path }

    var label: String {
        "\(identity.name)   →   \(profile.name)   [\(profile.isWildcard ? "通配" : "指定") · 到期 \(Util.dateString(profile.expiration))]"
    }

    static func == (lhs: SignCandidate, rhs: SignCandidate) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
