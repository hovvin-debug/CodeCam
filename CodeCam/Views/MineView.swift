import SwiftData
import SwiftUI

/// Tab root: account, device pairing, and sync entry.
struct MineView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var registrations: [DeviceRegistration]
    @Query private var sessions: [UserSessionRecord]
    @Query private var outboxItems: [OutboxItem]

    private var registration: DeviceRegistration? {
        registrations.first { $0.terminalID == InstallationIDStore.value }
    }

    private var accountSession: UserSessionRecord? {
        sessions.first { $0.isAuthenticated } ?? sessions.first
    }

    private var pendingSyncCount: Int {
        outboxItems.filter { $0.state != .synced && $0.state != .abandoned }.count
    }

    private var accountName: String {
        guard let session = accountSession, session.isAuthenticated else { return "未登录" }
        return session.displayName.isEmpty ? session.username : session.displayName
    }

    private var roleLine: String {
        if let factory = registration?.factoryName, !factory.isEmpty {
            return "质检工程师 · \(factory)"
        }
        return "账号与设备连接"
    }

    private var platformSubtitle: String {
        guard let registration else { return "未连接" }
        switch registration.state {
        case .registered, .online, .offline: return "已连接"
        case .pairing: return "等待认领"
        default: return "未连接"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 19) {
                    NavigationLink {
                        PlatformConnectionView()
                    } label: {
                        CodeCamProfileHeader(
                            initials: String(accountName.prefix(1)),
                            name: accountName,
                            roleLine: roleLine,
                            statusTitle: accountSession?.isAuthenticated == true ? "工位在线" : "等待登录",
                            isOnline: accountSession?.isAuthenticated == true
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        SyncQueueView()
                    } label: {
                        CodeCamSyncSummaryCard(
                            title: "同步队列",
                            value: pendingSyncCount > 0 ? "\(pendingSyncCount) 项待上传" : "已全部同步",
                            subtitle: pendingSyncCount > 0 ? "自动上传中" : "所有记录均已同步",
                            buttonTitle: "查看",
                            action: {}
                        )
                    }
                    .buttonStyle(.plain)

                    VStack(spacing: 0) {
                        NavigationLink {
                            PlatformConnectionView()
                        } label: {
                            CodeCamSettingsRow(icon: "checkmark.shield", title: "平台连接", subtitle: platformSubtitle)
                        }
                        .buttonStyle(.plain)
                        CodeCamListDivider()
                        NavigationLink {
                            DeviceRegistrationView()
                        } label: {
                            CodeCamSettingsRow(
                                icon: "rectangle.connected.to.line.below",
                                title: "设备注册",
                                subtitle: "工位 ID：\(registration?.serialNumber ?? DeviceIdentity.serialNumber) · \(platformSubtitle)"
                            )
                        }
                        .buttonStyle(.plain)
                        CodeCamListDivider()
                        NavigationLink {
                            StorageSettingsView()
                        } label: {
                            CodeCamSettingsRow(icon: "internaldrive", title: "数据与存储", subtitle: "查看本机缓存占用")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .codeCamListCard()

                    Text("CodeCam \(DeviceIdentity.version) · 数据已加密保护")
                        .font(.caption).foregroundStyle(CodeCamTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.large)
            .codeCamPage()
            .task {
                _ = AccountAuthService.session(in: modelContext)
                _ = DeviceRegistrationService.registration(in: modelContext)
            }
        }
    }
}
