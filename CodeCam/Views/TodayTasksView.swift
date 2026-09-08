import SwiftData
import SwiftUI

/// Tab root: today's execution list from EdgeFlow.
struct TodayTasksView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ExecutionList.updatedAt, order: .reverse) private var executionLists: [ExecutionList]
    @Query private var registrations: [DeviceRegistration]

    @State private var isRefreshing = false
    @State private var alert: AppAlert?

    private var registration: DeviceRegistration? {
        registrations.first { $0.terminalID == InstallationIDStore.value }
    }

    private var todayList: ExecutionList? {
        let today = ExecutionListService.todayKey()
        return executionLists.first { $0.workDateKey == today }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let list = todayList {
                    ExecutionListView(listID: list.id)
                } else {
                    ContentUnavailableView(
                        "暂无今日任务",
                        systemImage: "checklist",
                        description: Text(emptyDescription)
                    )
                }
            }
            .navigationTitle("任务")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        if isRefreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(isRefreshing || !canRefresh)
                    .accessibilityLabel("刷新今日清单")
                }
            }
            .task {
                if todayList == nil || shouldAutoRefresh {
                    await refresh()
                }
            }
            .alert(item: $alert) { item in
                Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("知道了")))
            }
        }
    }

    private var canRefresh: Bool {
        guard let registration else { return false }
        switch registration.state {
        case .registered, .online, .offline: return true
        default: return false
        }
    }

    private var shouldAutoRefresh: Bool {
        guard let list = todayList else { return canRefresh }
        return Date.now.timeIntervalSince(list.updatedAt) > 5 * 60
    }

    private var emptyDescription: String {
        if canRefresh {
            return "下拉或点右上角，从平台拉取今日待办。"
        }
        return "先到「我的」登录账号并连接设备，再回来刷新。"
    }

    private func refresh() async {
        guard canRefresh else {
            if todayList == nil {
                alert = AppAlert(title: "无法刷新", message: "请先在「我的」中完成设备连接。")
            }
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await ExecutionListService.refreshToday(in: modelContext)
        } catch {
            alert = AppAlert(title: "暂时无法刷新清单", message: "已继续使用本地缓存。\n\n\(error.localizedDescription)")
        }
    }
}
