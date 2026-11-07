import Foundation
import AppKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {

    @Published var ipaPath: String = ""
    @Published var ipa: IPAInfo?

    @Published var devices: [DeviceInfo] = []
    @Published var identities: [SigningIdentity] = []
    @Published var profiles: [ProvisioningProfile] = []
    @Published var candidates: [SignCandidate] = []

    @Published var selectedDeviceUDID: String = ""
    @Published var selectedCandidateID: String = ""

    @Published var busy = false
    @Published var launchAfterInstall = false
    @Published var status = "等待操作"
    @Published var logText = ""
    @Published var hint: String?

    // MARK: - 生命周期

    func bootstrap() {
        refreshEnvironment()
    }

    func refreshEnvironment() {
        status = "扫描证书 / 描述文件 / 设备…"
        Task.detached(priority: .userInitiated) {
            let identities = Discovery.identities()
            let profiles = Discovery.profiles()
            let discovered = Discovery.discoverDevices()
            await MainActor.run {
                self.identities = identities
                self.profiles = profiles
                self.devices = discovered.devices
                if !discovered.devices.contains(where: { $0.udid == self.selectedDeviceUDID }) {
                    self.selectedDeviceUDID = discovered.devices.first?.udid ?? ""
                }
                self.recomputeCandidates()
                if discovered.devices.isEmpty {
                    self.hint = discovered.warnings.isEmpty
                        ? "没检测到设备：确认 iPhone 已解锁、已信任此电脑，并开启开发者模式"
                        : discovered.warnings.joined(separator: "\n")
                    self.status = "证书 \(identities.count) 张 · 描述文件 \(profiles.count) 个 · 设备 0 台"
                } else {
                    self.status = "证书 \(identities.count) 张 · 描述文件 \(profiles.count) 个 · 设备 \(discovered.devices.count) 台"
                }
            }
        }
    }

    func refreshDevices() {
        Task.detached(priority: .userInitiated) {
            let discovered = Discovery.discoverDevices()
            let devices = discovered.devices
            await MainActor.run {
                self.devices = devices
                if !devices.contains(where: { $0.udid == self.selectedDeviceUDID }) {
                    self.selectedDeviceUDID = devices.first?.udid ?? ""
                }
                self.recomputeCandidates()
                if devices.isEmpty {
                    self.hint = discovered.warnings.isEmpty
                        ? "没检测到设备：确认 iPhone 已解锁、已信任此电脑，并开启开发者模式"
                        : discovered.warnings.joined(separator: "\n")
                    self.status = "没检测到设备"
                } else {
                    self.status = "设备 \(devices.count) 台已连接"
                }
            }
        }
    }

    // MARK: - 选择 IPA

    func pickIPA() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择一个 .ipa 包"
        if panel.runModal() == .OK, let url = panel.url {
            loadIPA(path: url.path)
        }
    }

    func loadIPA(path: String) {
        ipaPath = path
        do {
            ipa = try Discovery.inspectIPA(path: path)
            status = "已读包: \(ipa?.summary ?? path)"
            hint = nil
        } catch {
            ipa = nil
            hint = error.localizedDescription
            status = "读取 IPA 失败"
        }
        recomputeCandidates()
    }

    // MARK: - 候选账号

    func recomputeCandidates() {
        let list = Discovery.candidates(identities: identities,
                                        profiles: profiles,
                                        bundleID: ipa?.bundleID,
                                        deviceUDID: selectedDeviceUDID.isEmpty ? nil : selectedDeviceUDID)
        candidates = list
        if !list.contains(where: { $0.id == selectedCandidateID }) {
            selectedCandidateID = list.first?.id ?? ""
        }
        if !list.isEmpty {
            hint = nil
        } else if ipa != nil, selectedDeviceUDID.isEmpty {
            hint = "没有可用账号：先连接并选择一台设备"
        } else if ipa != nil, !identities.isEmpty || !profiles.isEmpty {
            hint = "没有可用账号：需要一张证书，且它的描述文件还没过期、包含这台设备的 UDID、AppID 能覆盖 \(ipa?.bundleID ?? "该包")。到 Xcode → Settings → Accounts 里给该设备生成一次描述文件即可。"
        }
    }

    var selectedCandidate: SignCandidate? {
        candidates.first { $0.id == selectedCandidateID }
    }

    var selectedDevice: DeviceInfo? {
        devices.first { $0.udid == selectedDeviceUDID }
    }

    var canRun: Bool {
        !busy && ipa != nil && selectedCandidate != nil && !selectedDeviceUDID.isEmpty
    }

    // MARK: - 动作

    func signAndInstall() {
        guard let ipa, let candidate = selectedCandidate, let device = selectedDevice else { return }
        let base = (ipa.fileName as NSString).deletingPathExtension
        let out = NSTemporaryDirectory() + "\(base)-signed.ipa"
        run(candidate: candidate, ipa: ipa, device: device, output: out, install: true)
    }

    func signOnly() {
        guard let ipa, let candidate = selectedCandidate else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (ipa.fileName as NSString).deletingPathExtension + "-signed.ipa"
        panel.allowedFileTypes = ["ipa"]
        panel.message = "把重签名后的包存到哪"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let device = selectedDevice else { return }
        run(candidate: candidate, ipa: ipa, device: device, output: url.path, install: false)
    }

    private func run(candidate: SignCandidate,
                     ipa: IPAInfo,
                     device: DeviceInfo,
                     output: String,
                     install: Bool) {
        busy = true
        logText = ""
        hint = nil
        let shouldLaunch = launchAfterInstall
        append("===== 开始 =====")
        append("包   : \(ipa.path)")
        append("包 ID: \(ipa.bundleID)")
        append("身份: \(candidate.identity.name)  (\(candidate.identity.sha1))")
        append("文件: \(candidate.profile.name)")
        append("设备: \(device.display)")

        Task.detached(priority: .userInitiated) {
            do {
                let signed = try Signer.sign(
                    SignRequest(ipa: ipa, identity: candidate.identity, profile: candidate.profile, outputPath: output),
                    log: { line in self.append(line) }
                )
                if install {
                    try Installer.install(ipaPath: signed, device: device, log: { line in self.append(line) })
                    if shouldLaunch {
                        Installer.launch(bundleID: ipa.bundleID, device: device, log: { line in self.append(line) })
                    }
                }
                self.append("===== 全部完成 =====")
                await MainActor.run {
                    self.busy = false
                    self.status = install ? "已签名并安装到 \(device.udid.prefix(8))…" : "已导出 \(signed)"
                }
            } catch {
                self.append("❌ \(error.localizedDescription)")
                await MainActor.run {
                    self.busy = false
                    self.hint = error.localizedDescription
                    self.status = "失败"
                }
            }
        }
    }

    // MARK: - 日志

    nonisolated func append(_ line: String) {
        let text = line.trimmingCharacters(in: .newlines)
        Task { @MainActor in
            if self.logText.isEmpty {
                self.logText = text
            } else {
                self.logText += "\n" + text
            }
        }
    }
}
