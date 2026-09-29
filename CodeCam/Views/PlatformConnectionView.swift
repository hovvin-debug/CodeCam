import Foundation
import SwiftData
import SwiftUI
import UIKit

/// Combined account login + device pairing screen.
struct PlatformConnectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var sessions: [UserSessionRecord]
    @Query private var registrations: [DeviceRegistration]

    @State private var authMode: AuthMode = .register
    @State private var username = ""
    @State private var displayName = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var working = false
    @State private var workingMessage = "正在连接平台…"
    @State private var alert: AppAlert?
    @State private var serverHost = PlatformEndpoint.defaultHost
    @State private var serverPort = String(PlatformEndpoint.defaultPort)
    @State private var usesHTTPS = false
    @State private var serverDirty = false

    private var session: UserSessionRecord? {
        sessions.first { $0.isAuthenticated } ?? sessions.first
    }

    private var registration: DeviceRegistration? {
        registrations.first { $0.terminalID == InstallationIDStore.value }
    }

    private var isWaitingForClaim: Bool {
        registration?.state == .pairing && !(registration?.verificationCode ?? "").isEmpty
    }

    private var isConnecting: Bool {
        registration?.state == .claimed
    }

    private var isConnected: Bool {
        registration?.state == .registered || registration?.state == .online
    }

    private var isAlreadyRegistered: Bool {
        switch registration?.state {
        case .registered, .online, .offline: true
        default: false
        }
    }

    private var needsReconnect: Bool {
        registration?.state == .failed || registration?.state == .revoked
    }

    var body: some View {
        Form {
            platformServerSection
            accountSections
            deviceSections
        }
        .navigationTitle("平台连接")
        .navigationBarTitleDisplayMode(.inline)
        .codeCamPage()
        .overlay {
            if working {
                ProgressView(workingMessage)
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .task {
            _ = AccountAuthService.session(in: modelContext)
            _ = DeviceRegistrationService.registration(in: modelContext)
            loadServerSettings()
        }
        .task(id: pairingTaskID) {
            await pollWhileWaiting()
        }
        .alert(item: $alert) { item in
            Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("知道了")))
        }
    }

    private var canEditServer: Bool {
        switch registration?.state {
        case .pairing, .claimed, .registered, .online, .offline: false
        default: true
        }
    }

    @ViewBuilder
    private var platformServerSection: some View {
        Section {
            if canEditServer {
                TextField("服务器地址", text: $serverHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onChange(of: serverHost) { _, _ in serverDirty = true }
                TextField("端口", text: $serverPort)
                    .keyboardType(.numberPad)
                    .onChange(of: serverPort) { _, _ in serverDirty = true }
                Toggle("使用 HTTPS", isOn: $usesHTTPS)
                    .onChange(of: usesHTTPS) { _, _ in serverDirty = true }
                if serverDirty {
                    Button("保存服务器设置") {
                        saveServerSettings()
                    }
                }
            } else {
                LabeledContent("服务器", value: serverHost)
                LabeledContent("端口", value: serverPort)
                LabeledContent("协议", value: usesHTTPS ? "HTTPS" : "HTTP")
            }
            LabeledContent("当前地址", value: previewServerURL)
        } header: {
            Text("开放平台")
        } footer: {
            if canEditServer {
                Text("填写局域网 EdgeFlow 服务器的 IP 或域名与端口，保存后再登录账号并认领设备。")
            } else {
                Text("设备已连接或正在认领中，暂不能修改服务器。如需更换平台，请先断开设备连接或重置配对。")
            }
        }
    }

    private var previewServerURL: String {
        let scheme = usesHTTPS ? "https" : "http"
        let host = serverHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = serverPort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !port.isEmpty else { return EdgeFlowClient.defaultBaseURL }
        return "\(scheme)://\(host):\(port)"
    }

    private func loadServerSettings() {
        let endpoint = PlatformEndpoint.current()
        serverHost = endpoint.host
        serverPort = String(endpoint.port)
        usesHTTPS = endpoint.usesHTTPS
        serverDirty = false
    }

    private func saveServerSettings() {
        do {
            _ = try PlatformEndpoint.save(host: serverHost, portText: serverPort, usesHTTPS: usesHTTPS)
            serverDirty = false
            alert = AppAlert(title: "已保存", message: "平台地址已更新为 \(previewServerURL)")
        } catch {
            alert = AppAlert(title: "无法保存", message: error.localizedDescription)
        }
    }

    @ViewBuilder
    private var accountSections: some View {
        if let session, session.isAuthenticated {
            Section("平台账号") {
                LabeledContent("显示名称", value: session.displayName.isEmpty ? session.username : session.displayName)
                LabeledContent("用户名", value: session.username)
                LabeledContent("账号角色", value: session.platformOperator ? "平台运营" : "现场员工")
            }
            Section {
                Button("退出登录", role: .destructive) {
                    AccountAuthService.logout(in: modelContext)
                    password = ""
                    confirmPassword = ""
                }
            }
        } else {
            Section("平台账号") {
                Picker("方式", selection: $authMode) {
                    Text("注册").tag(AuthMode.register)
                    Text("登录").tag(AuthMode.login)
                }
                .pickerStyle(.segmented)

                TextField("用户名", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                if authMode == .register {
                    TextField("显示名称", text: $displayName)
                        .textContentType(.name)
                }
                SecureField("密码", text: $password)
                    .textContentType(authMode == .register ? .newPassword : .password)
                if authMode == .register {
                    SecureField("确认密码", text: $confirmPassword)
                        .textContentType(.newPassword)
                }
                Button(authMode == .register ? "注册并登录" : "登录") {
                    submitAccount()
                }
                .disabled(working)
            }
        }
    }

    @ViewBuilder
    private var deviceSections: some View {
        Section("设备连接") {
            LabeledContent("设备序列号", value: registration?.serialNumber ?? DeviceIdentity.serialNumber)
            HStack {
                Text("连接状态")
                Spacer()
                DeviceStateBadge(state: registration?.state ?? .unpaired)
            }
            if let factory = registration?.factoryName, !factory.isEmpty {
                LabeledContent("归属工厂", value: factory)
            }
            if let error = registration?.lastError, !error.isEmpty, !isConnected {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }

        if isWaitingForClaim, let registration, let code = registration.verificationCode {
            Section("工厂认领验证码") {
                Text(code)
                    .font(.largeTitle.monospaced().weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundStyle(isExpired(registration) ? .secondary : .primary)

                PairingCountdownView(expiresAt: registration.pairingExpiresAt)

                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(isExpired(registration)
                         ? "验证码已过期，仍在确认工厂是否已认领…"
                         : "等待工厂认领中，认领成功后会自动完成连接")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text("请让平台管理员在工厂控制台录入此验证码。无需返回此页手动确认。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("复制验证码") {
                    UIPasteboard.general.string = code
                }

                Button {
                    runDevice(message: "正在刷新验证码…") { registration in
                        try await DeviceRegistrationService.refreshVerificationCode(registration, in: modelContext)
                    }
                } label: {
                    Label(isExpired(registration) ? "刷新验证码" : "重新生成验证码", systemImage: "arrow.clockwise")
                }
            }
        }

        if isConnecting {
            Section("正在连接") {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("工厂已认领，正在完成本机登记…")
                        .font(.subheadline)
                }
                Text("请稍候，一般几秒内会自动变为已连接。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        Section {
            if isAlreadyRegistered {
                if registration?.state == .offline {
                    Text(registration?.lastError ?? "与平台暂时失去连接，可手动重试上报。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Button("立即上报状态") {
                    runDevice(message: "正在上报状态…") { registration in
                        try await DeviceRegistrationService.sendHeartbeat(registration, in: modelContext)
                    }
                }
            } else if needsReconnect {
                Text(registration?.lastError ?? "连接异常。可重试上报，或重新生成验证码。")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Button("重试连接") {
                    runDevice(message: "正在重试连接…") { registration in
                        try await DeviceRegistrationService.sendHeartbeat(registration, in: modelContext)
                    }
                }
                Button("重新生成验证码") {
                    runDevice(message: "正在生成验证码…") { registration in
                        try await DeviceRegistrationService.beginPairing(registration, in: modelContext)
                    }
                }
            } else if !isWaitingForClaim && !isConnecting {
                Button("生成工厂认领验证码") {
                    runDevice(message: "正在生成验证码…") { registration in
                        try await DeviceRegistrationService.beginPairing(registration, in: modelContext)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var pairingTaskID: String {
        "\(registration?.state.rawValue ?? "none")|\(registration?.verificationCode ?? "")|\(registration?.pairingID ?? "")"
    }

    private func isExpired(_ registration: DeviceRegistration?) -> Bool {
        guard let expiresAt = registration?.pairingExpiresAt else { return false }
        return expiresAt <= .now
    }

    private func submitAccount() {
        if serverDirty {
            alert = AppAlert(title: "请先保存服务器设置", message: "修改了服务器或端口后，请先点「保存服务器设置」。")
            return
        }
        if authMode == .register {
            guard password == confirmPassword else {
                alert = AppAlert(title: "无法注册", message: "两次输入的密码不一致。")
                return
            }
        }

        workingMessage = authMode == .register ? "正在注册…" : "正在登录…"
        working = true
        Task {
            defer { working = false }
            do {
                if authMode == .register {
                    try await AccountAuthService.register(
                        username: username,
                        password: password,
                        displayName: displayName,
                        in: modelContext
                    )
                    alert = AppAlert(title: "注册成功", message: "账号已创建。接下来可生成设备认领验证码。")
                } else {
                    try await AccountAuthService.login(username: username, password: password, in: modelContext)
                }
                password = ""
                confirmPassword = ""
            } catch {
                alert = AppAlert(
                    title: authMode == .register ? "无法注册" : "无法登录",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func pollWhileWaiting() async {
        guard let registration else { return }
        if registration.state == .claimed {
            do {
                _ = try await DeviceRegistrationService.finishConnection(registration, in: modelContext)
            } catch {
                DeviceRegistrationService.recordError(error, for: registration, in: modelContext)
            }
            return
        }

        guard registration.state == .pairing, !(registration.verificationCode ?? "").isEmpty else { return }

        while !Task.isCancelled {
            let current = DeviceRegistrationService.registration(in: modelContext)
            guard current.state == .pairing || current.state == .claimed else { return }
            do {
                let connected = try await DeviceRegistrationService.pollAndAdvance(current, in: modelContext)
                if connected { return }
            } catch {
                current.lastError = error.localizedDescription
                current.updatedAt = .now
                try? modelContext.save()
            }

            let latest = DeviceRegistrationService.registration(in: modelContext)
            if latest.state == .registered || latest.state == .online { return }
            if latest.state != .pairing && latest.state != .claimed { return }

            try? await Task.sleep(nanoseconds: 2_500_000_000)
        }
    }

    private func runDevice(message: String, _ action: @escaping (DeviceRegistration) async throws -> Void) {
        guard let registration else { return }
        if serverDirty {
            alert = AppAlert(title: "请先保存服务器设置", message: "修改了服务器或端口后，请先点「保存服务器设置」。")
            return
        }
        workingMessage = message
        working = true
        Task {
            defer { working = false }
            do {
                try await action(registration)
            } catch {
                DeviceRegistrationService.recordError(error, for: registration, in: modelContext)
                alert = AppAlert(title: "无法完成设备连接", message: error.localizedDescription)
            }
        }
    }
}

private enum AuthMode {
    case register
    case login
}
