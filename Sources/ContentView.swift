import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        VStack(spacing: 14) {
            header
            ipaCard
            row1
            accountCard
            actionBar
            logView
        }
        .padding(18)
        .frame(minWidth: 940, minHeight: 700)
        .onAppear {
            m.bootstrap()
            if let ipaPath = Snapshot.pendingIPA { m.loadIPA(path: ipaPath) }
            if let path = Snapshot.pendingPath {
                DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) {
                    let ok = Snapshot.captureFrontWindow(to: path)
                    FileHandle.standardError.write((ok ? "snapshot: \(path)\n" : "snapshot failed\n").data(using: .utf8)!)
                    exit(ok ? 0 : 1)
                }
            }
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            logo
            VStack(alignment: .leading, spacing: 3) {
                Text("IPA 签名装机器")
                    .font(.system(size: 20, weight: .semibold))
                Text(m.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if m.busy { ProgressView().controlSize(.small).padding(.trailing, 6) }
            Button("重新扫描") { m.refreshEnvironment() }
                .disabled(m.busy)
        }
    }

    private var logo: some View {
        Group {
            if let url = Bundle.main.url(forResource: "appicon", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 46, height: 46)
            } else {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 30, weight: .light))
                    .frame(width: 46, height: 46)
            }
        }
    }

    // MARK: - IPA

    private var ipaCard: some View {
        card("① 选择 IPA 包") {
            HStack(spacing: 10) {
                Text(m.ipaPath.isEmpty ? "还没选包" : m.ipaPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(m.ipaPath.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("浏览…") { m.pickIPA() }
                    .disabled(m.busy)
            }
            if let ipa = m.ipa {
                Text(ipa.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 设备

    private var row1: some View {
        card("② 选择设备（USB 插着的）") {
            HStack(spacing: 10) {
                Picker("", selection: $m.selectedDeviceUDID) {
                    if m.devices.isEmpty {
                        Text("没有检测到设备").tag("")
                    }
                    ForEach(m.devices) { device in
                        Text(device.display).tag(device.udid)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 560)
                Spacer()
                Button("刷新设备") { m.refreshDevices() }
                    .disabled(m.busy)
            }
            if let d = m.selectedDevice {
                Text("UDID \(d.udid)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 账号

    private var accountCard: some View {
        card("③ 选择签名账号（证书 + 描述文件自动配对）") {
            Picker("", selection: $m.selectedCandidateID) {
                if m.candidates.isEmpty {
                    Text("没有匹配的账号").tag("")
                }
                ForEach(m.candidates) { candidate in
                    Text(candidate.label).tag(candidate.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(m.busy || m.candidates.isEmpty)

            if let c = m.selectedCandidate {
                HStack(spacing: 16) {
                    Label(c.identity.team, systemImage: "person.badge.key")
                    Label(c.profile.isWildcard ? "通配 AppID \(c.profile.appID)" : c.profile.appID,
                          systemImage: "doc.text")
                    Label("到期 \(Util.dateString(c.profile.expiration))", systemImage: "calendar")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let hint = m.hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 按钮

    private var actionBar: some View {
        HStack(spacing: 12) {
            Toggle("装完自动启动（尽力而为，需设备解锁）", isOn: $m.launchAfterInstall)
                .toggleStyle(.checkbox)
                .disabled(m.busy)
            Spacer()
            Button("只签名导出…") { m.signOnly() }
                .controlSize(.large)
                .disabled(!m.canRun)
            Button(m.busy ? "处理中…" : "签名并安装") { m.signAndInstall() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!m.canRun)
        }
    }

    // MARK: - 日志

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(m.logText.isEmpty ? "日志会显示在这里…" : m.logText)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .id("log-end")
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
            .onChange(of: m.logText) { _ in
                proxy.scrollTo("log-end", anchor: .bottom)
            }
        }
    }

    // MARK: - 卡片容器

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.18), lineWidth: 1))
    }
}
