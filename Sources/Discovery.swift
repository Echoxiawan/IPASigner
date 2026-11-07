import Foundation

// MARK: - 发现：证书 / 描述文件 / 设备 / IPA

enum Discovery {

    struct DeviceDiscoveryOutcome {
        let devices: [DeviceInfo]
        let warnings: [String]
    }

    // ---------- 证书 ----------

    static func identities() -> [SigningIdentity] {
        let r = Shell.run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"])
        let meta = certificateMeta()
        let regex = try! NSRegularExpression(pattern: "^\\s*\\d+\\)\\s+([0-9A-Fa-f]{40})\\s+\"(.*)\"\\s*$")
        var seen = Set<String>()
        var result: [SigningIdentity] = []
        for rawLine in r.out.split(separator: "\n") {
            let line = String(rawLine)
            guard let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { continue }
            guard let shaRange = Range(m.range(at: 1), in: line),
                  let nameRange = Range(m.range(at: 2), in: line) else { continue }
            var sha = String(line[shaRange]).uppercased()
            var name = String(line[nameRange])
            if name.contains("CSSMERR_TP_CERT_REVOKED") {
                name = name.replacingOccurrences(of: " (CSSMERR_TP_CERT_REVOKED)", with: "")
            }
            if seen.contains(sha) { continue }
            seen.insert(sha)
            let info = meta[sha]
            result.append(SigningIdentity(sha1: sha,
                                          name: name,
                                          team: info?.team ?? "",
                                          commonName: info?.cn ?? name))
        }
        return result
    }

    private struct CertMeta { let team: String; let cn: String }

    private static func certificateMeta() -> [String: CertMeta] {
        guard let openssl = ToolPath.find("openssl") else { return [:] }
        let raw = Shell.runData("/usr/bin/security", ["find-certificate", "-a", "-p"])
        let pem = String(decoding: raw.1, as: UTF8.self)
        let blocks = splitPEM(pem)
        var out: [String: CertMeta] = [:]
        for block in blocks {
            let tmp = NSTemporaryDirectory() + "cert-\(UUID().uuidString).pem"
            guard (try? block.write(toFile: tmp, atomically: true, encoding: .utf8)) != nil else { continue }
            defer { try? FileManager.default.removeItem(atPath: tmp) }
            // 注意：macOS 自带 LibreSSL 加 -nameopt utf8 时 subject 会输出空，别加
            let res = Shell.run(openssl, ["x509", "-in", tmp, "-noout", "-fingerprint", "-sha1", "-subject"])
            var sha = ""
            var subject = ""
            for line in res.out.split(separator: "\n") {
                let s = String(line)
                let lower = s.lowercased()
                if lower.hasPrefix("sha1 fingerprint") || lower.hasPrefix("sha-1 fingerprint") || lower.hasPrefix("sha256 fingerprint") {
                    sha = s.components(separatedBy: "=").last?
                        .replacingOccurrences(of: ":", with: "")
                        .trimmingCharacters(in: .whitespaces).uppercased() ?? ""
                } else if lower.hasPrefix("subject=") {
                    subject = String(s.dropFirst("subject=".count))
                }
            }
            guard sha.count == 40 else { continue }
            out[sha] = CertMeta(team: extractField(subject, "OU"), cn: extractField(subject, "CN"))
        }
        return out
    }

    /// 从 OpenSSL 的 subject 里取字段，兼容两种输出：
    /// LibreSSL: "/UID=../CN=../OU=../O=../C=.."   OpenSSL 3: "UID=.., CN=.., OU=.."
    private static func extractField(_ subject: String, _ key: String) -> String {
        let normalized = subject.replacingOccurrences(of: " = ", with: "=")
        for raw in normalized.split(whereSeparator: { $0 == "/" || $0 == "," }) {
            let token = raw.trimmingCharacters(in: .whitespaces)
            if token.hasPrefix(key + "=") {
                return String(token.dropFirst(key.count + 1))
            }
        }
        return ""
    }

    private static func splitPEM(_ text: String) -> [String] {
        var blocks: [String] = []
        var current: [String] = []
        var inside = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if s.contains("BEGIN CERTIFICATE") { inside = true; current = [s]; continue }
            if inside {
                current.append(s)
                if s.contains("END CERTIFICATE") {
                    blocks.append(current.joined(separator: "\n") + "\n")
                    inside = false
                    current = []
                }
            }
        }
        return blocks
    }

    // ---------- 描述文件 ----------

    static func profileDirectories() -> [String] {
        var dirs = ["~/Library/Developer/Xcode/UserData/Provisioning Profiles",
                    "~/Library/MobileDevice/Provisioning Profiles"]
        dirs = dirs.map { Util.expand($0) }.filter { FileManager.default.fileExists(atPath: $0) }
        return dirs
    }

    static func profiles() -> [ProvisioningProfile] {
        var result: [ProvisioningProfile] = []
        for dir in profileDirectories() {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.hasSuffix(".mobileprovision") || file.hasSuffix(".provisionprofile") {
                let path = dir + "/" + file
                guard let p = parseProfile(path: path) else { continue }
                result.append(p)
            }
        }
        return result.sorted { $0.expiration ?? .distantPast > $1.expiration ?? .distantPast }
    }

    static func parseProfile(path: String) -> ProvisioningProfile? {
        let raw = Shell.runData("/usr/bin/security", ["cms", "-D", "-i", path])
        guard raw.0 == 0 else { return nil }
        guard let dict = (try? PropertyListSerialization.propertyList(from: raw.1, options: [], format: nil)) as? [String: Any] else { return nil }

        let name = dict["Name"] as? String ?? (path as NSString).lastPathComponent
        let team = (dict["TeamIdentifier"] as? [String])?.first ?? ""
        let expiration = dict["ExpirationDate"] as? Date
        let devices = Set((dict["ProvisionedDevices"] as? [String]) ?? [])
        let entitlements = dict["Entitlements"] as? [String: Any] ?? [:]
        let appID = entitlements["application-identifier"] as? String ?? ""
        let getTaskAllow = entitlements["get-task-allow"] as? Bool ?? false
        let keychainGroups = entitlements["keychain-access-groups"] as? [String] ?? []
        let certData = dict["DeveloperCertificates"] as? [Data] ?? []
        let certSHA1s = Set(certData.map { Hash.sha1($0).uppercased() })

        return ProvisioningProfile(path: path,
                                   name: name,
                                   team: team,
                                   appID: appID,
                                   expiration: expiration,
                                   devices: devices,
                                   certSHA1s: certSHA1s,
                                   getTaskAllow: getTaskAllow,
                                   keychainGroups: keychainGroups)
    }

    // ---------- 设备 ----------

    /// 同时扫描 Xcode CoreDevice 与 libimobiledevice。
    /// iOS 17 之后 Xcode 常通过 CoreDevice 的 USB / 局域网隧道访问设备，
    /// 此时 `idevice_id -l` 可能完全看不到设备，因此不能只依赖它。
    static func discoverDevices() -> DeviceDiscoveryOutcome {
        let core = coreDeviceDevices()
        let usb = libimobiledeviceDevices()
        let devices = merge(devices: core.devices, with: usb.devices)

        var warnings: [String] = []
        if devices.isEmpty {
            if let error = core.error { warnings.append("Xcode CoreDevice: \(error)") }
            if let error = usb.error { warnings.append("libimobiledevice: \(error)") }
        }
        return DeviceDiscoveryOutcome(devices: devices, warnings: warnings)
    }

    private struct CoreDeviceListEnvelope: Decodable {
        let result: CoreDeviceListResult
    }

    private struct CoreDeviceListResult: Decodable {
        let devices: [CoreDeviceRecord]
    }

    private struct CoreDeviceRecord: Decodable {
        let identifier: String
        let connectionProperties: CoreDeviceConnectionProperties?
        let deviceProperties: CoreDeviceProperties?
        let hardwareProperties: CoreDeviceHardwareProperties
    }

    private struct CoreDeviceConnectionProperties: Decodable {
        let pairingState: String?
        let transportType: String?
        let tunnelState: String?
    }

    private struct CoreDeviceProperties: Decodable {
        let name: String?
        let osVersionNumber: String?
        let developerModeStatus: String?
    }

    private struct CoreDeviceHardwareProperties: Decodable {
        let deviceType: String?
        let marketingName: String?
        let platform: String?
        let productType: String?
        let reality: String?
        let udid: String?
    }

    private static func coreDeviceDevices() -> (devices: [DeviceInfo], error: String?) {
        guard let xcrun = ToolPath.find("xcrun") else {
            return ([], "找不到 xcrun，请安装完整 Xcode")
        }

        let outputPath = NSTemporaryDirectory() + "ipasigner-coredevice-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: outputPath) }

        let r = Shell.run(xcrun, ["devicectl", "list", "devices",
                                  "--quiet", "--timeout", "20",
                                  "--json-output", outputPath])
        guard r.ok else {
            return ([], r.combined.isEmpty ? "devicectl 扫描失败" : r.combined)
        }
        guard let data = FileManager.default.contents(atPath: outputPath) else {
            return ([], "devicectl 没有生成设备列表")
        }
        guard let envelope = try? JSONDecoder().decode(CoreDeviceListEnvelope.self, from: data) else {
            return ([], "无法解析 devicectl 设备列表")
        }

        var result: [DeviceInfo] = []
        for record in envelope.result.devices {
            let hardware = record.hardwareProperties
            guard hardware.platform == "iOS",
                  hardware.reality == "physical",
                  let udid = hardware.udid?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !udid.isEmpty else { continue }

            let connectionInfo = record.connectionProperties
            guard connectionInfo?.pairingState == "paired" else { continue }
            guard connectionInfo?.transportType != nil || connectionInfo?.tunnelState == "connected" else {
                continue
            }

            let transport = connectionInfo?.transportType?.lowercased() ?? ""
            let connection: DeviceConnection
            switch transport {
            case "usb": connection = .usb
            case "localnetwork", "network": connection = .localNetwork
            default: connection = .unknown
            }

            let productType = hardware.productType ?? "-"
            let marketingName = hardware.marketingName ?? ""
            result.append(DeviceInfo(udid: udid,
                                     name: record.deviceProperties?.name ?? marketingName,
                                     productType: productType,
                                     modelName: marketingName,
                                     osVersion: record.deviceProperties?.osVersionNumber ?? "-",
                                     connection: connection,
                                     coreDeviceIdentifier: record.identifier))
        }
        return (result, nil)
    }

    private static func libimobiledeviceDevices() -> (devices: [DeviceInfo], error: String?) {
        guard let ideviceID = ToolPath.find("idevice_id") else {
            return ([], "未安装 idevice_id")
        }

        let r = Shell.run(ideviceID, ["-l"])
        guard r.ok else {
            return ([], r.combined.isEmpty ? "idevice_id 扫描失败" : r.combined)
        }

        let ideviceInfo = ToolPath.find("ideviceinfo")
        let udids = r.out.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var result: [DeviceInfo] = []
        for udid in udids {
            let name = ideviceInfo.map {
                Shell.run($0, ["-u", udid, "-k", "DeviceName"]).out
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? ""
            let product = ideviceInfo.map {
                Shell.run($0, ["-u", udid, "-k", "ProductType"]).out
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? ""
            let os = ideviceInfo.map {
                Shell.run($0, ["-u", udid, "-k", "ProductVersion"]).out
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? ""
            result.append(DeviceInfo(udid: udid,
                                     name: name.isEmpty ? "iPhone" : name,
                                     productType: product.isEmpty ? "-" : product,
                                     modelName: "",
                                     osVersion: os.isEmpty ? "-" : os,
                                     connection: .usb,
                                     coreDeviceIdentifier: nil))
        }
        return (result, ideviceInfo == nil ? "未安装 ideviceinfo，设备详情可能不完整" : nil)
    }

    private static func merge(devices coreDevices: [DeviceInfo],
                              with usbDevices: [DeviceInfo]) -> [DeviceInfo] {
        var byUDID: [String: DeviceInfo] = [:]
        for device in coreDevices {
            byUDID[device.udid.uppercased()] = device
        }
        for device in usbDevices {
            let key = device.udid.uppercased()
            guard let existing = byUDID[key] else {
                byUDID[key] = device
                continue
            }
            byUDID[key] = DeviceInfo(udid: existing.udid,
                                     name: existing.name.isEmpty ? device.name : existing.name,
                                     productType: existing.productType == "-" ? device.productType : existing.productType,
                                     modelName: existing.modelName,
                                     osVersion: existing.osVersion == "-" ? device.osVersion : existing.osVersion,
                                     connection: existing.connection == .usb || device.connection == .usb ? .usb : existing.connection,
                                     coreDeviceIdentifier: existing.coreDeviceIdentifier ?? device.coreDeviceIdentifier)
        }
        return byUDID.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // ---------- IPA ----------

    static func inspectIPA(path: String) throws -> IPAInfo {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ToolError.failed("IPA 不存在: \(path)")
        }
        let unzip = "/usr/bin/unzip"
        let listing = Shell.run(unzip, ["-Z1", path])
        guard listing.ok else { throw ToolError.failed("读取 IPA 失败: \(listing.combined)") }
        let entries = listing.out.split(separator: "\n").map(String.init)
        guard let infoEntry = entries.first(where: {
            $0.hasPrefix("Payload/") && $0.hasSuffix(".app/Info.plist")
                && $0.components(separatedBy: "/").count == 3
        }) else {
            throw ToolError.failed("这个 IPA 里没找到 Payload/*.app/Info.plist，不是标准包")
        }

        let raw = Shell.runData(unzip, ["-p", path, infoEntry])
        guard raw.0 == 0,
              let dict = (try? PropertyListSerialization.propertyList(from: raw.1, options: [], format: nil)) as? [String: Any] else {
            throw ToolError.failed("解析 Info.plist 失败")
        }

        let bundleID = dict["CFBundleIdentifier"] as? String ?? ""
        guard !bundleID.isEmpty else { throw ToolError.failed("Info.plist 里没有 CFBundleIdentifier") }

        let appBundle = String(infoEntry.dropLast("/Info.plist".count))
        return IPAInfo(path: path,
                       bundleID: bundleID,
                       shortVersion: dict["CFBundleShortVersionString"] as? String ?? "-",
                       buildVersion: dict["CFBundleVersion"] as? String ?? "-",
                       appName: (dict["CFBundleDisplayName"] as? String) ?? (dict["CFBundleName"] as? String) ?? "App",
                       minimumOS: dict["MinimumOSVersion"] as? String ?? "-",
                       appBundleRelativePath: appBundle,
                       executableName: dict["CFBundleExecutable"] as? String ?? "")
    }

    // ---------- 账号匹配 ----------

    /// 证书 → 描述文件 → 设备 → 包 ID 全部匹配后才算可用账号
    static func candidates(identities: [SigningIdentity],
                           profiles: [ProvisioningProfile],
                           bundleID: String?,
                           deviceUDID: String?) -> [SignCandidate] {
        var result: [SignCandidate] = []
        for identity in identities {
            for profile in profiles {
                if profile.isExpired { continue }
                if !identity.team.isEmpty && profile.team != identity.team { continue }
                if !profile.certSHA1s.contains(identity.sha1.uppercased()) { continue }
                if let bundleID, !bundleID.isEmpty, !profile.appIDMatches(bundleID: bundleID) { continue }
                if let deviceUDID, !deviceUDID.isEmpty, !profile.devices.isEmpty,
                   !profile.devices.contains(where: {
                       $0.caseInsensitiveCompare(deviceUDID) == .orderedSame
                   }) { continue }
                result.append(SignCandidate(identity: identity, profile: profile))
            }
        }
        // 通配描述文件排前面（更好用）
        return result.sorted { a, b in
            if a.profile.isWildcard != b.profile.isWildcard { return a.profile.isWildcard }
            return (a.profile.expiration ?? .distantPast) > (b.profile.expiration ?? .distantPast)
        }
    }
}
