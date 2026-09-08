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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        PlatformConnectionView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: accountSession?.isAuthenticated == true ? "person.crop.circle.fill" : "person.crop.circle.badge.plus")
                                .font(.title)
                                .foregroundStyle(accountSession?.isAuthenticated == true ? .blue : .secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(accountName)
                                    .font(.headline)
                                Text(registration?.factoryName ?? "账号与设备连接")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 6) {
                                StatusCapsule(
                                    title: accountSession?.isAuthenticated == true ? "已登录" : "未登录",
                                    tint: accountSession?.isAuthenticated == true ? .green : .secondary
                                )
                                DeviceStateBadge(state: registration?.state ?? .unpaired)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                } header: {
                    Text("账号与设备")
                } footer: {
                    Text("登录并完成认领后，才能拉取「任务」并同步采集数据。")
                }

                Section("同步") {
                    NavigationLink {
                        SyncQueueView()
                    } label: {
                        HStack {
                            Label("同步队列", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            CountBadge(count: pendingSyncCount)
                        }
                    }
                }

                Section("关于") {
                    LabeledContent("设备序列号", value: registration?.serialNumber ?? DeviceIdentity.serialNumber)
                    LabeledContent("应用版本", value: DeviceIdentity.version)
                    LabeledContent("服务地址", value: EdgeFlowClient.baseURL?.absoluteString ?? EdgeFlowClient.defaultBaseURL)
                }
            }
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.large)
            .task {
                _ = AccountAuthService.session(in: modelContext)
                _ = DeviceRegistrationService.registration(in: modelContext)
            }
        }
    }
}
