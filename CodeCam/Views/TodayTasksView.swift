import SwiftData
import SwiftUI

enum TodayListRefresh {
    static func canRefresh(registration: DeviceRegistration?) -> Bool {
        guard let registration else { return false }
        switch registration.state {
        case .registered, .online, .offline: return true
        default: return false
        }
    }

    static func shouldAutoRefresh(list: ExecutionList?, registration: DeviceRegistration?) -> Bool {
        guard let list else { return canRefresh(registration: registration) }
        return Date.now.timeIntervalSince(list.updatedAt) > 5 * 60
    }

    @MainActor
    static func refresh(in context: ModelContext, registration: DeviceRegistration?, todayList: ExecutionList?) async -> AppAlert? {
        guard canRefresh(registration: registration) else {
            if todayList == nil {
                return AppAlert(title: "无法刷新", message: "请先在「我的」中完成设备连接。")
            }
            return nil
        }
        do {
            try await ExecutionListService.refreshToday(in: context)
            return nil
        } catch {
            todayList?.lastRefreshError = error.localizedDescription
            try? context.save()
            return AppAlert(title: "暂时无法刷新清单", message: "已继续使用本地缓存。\n\n\(error.localizedDescription)")
        }
    }
}

/// Tab root: today's workstation task. Employees cannot switch tasks on device.
struct TodayTasksView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TaskDraft.updatedAt, order: .reverse) private var drafts: [TaskDraft]
    @Query(sort: \ExecutionList.updatedAt, order: .reverse) private var executionLists: [ExecutionList]
    @Query private var executionItems: [ExecutionItem]
    @Query private var registrations: [DeviceRegistration]

    @State private var isRefreshing = false
    @State private var alert: AppAlert?
    @State private var scannerPresented = false
    @State private var pendingScannedValue: String?

    let onOpenCapture: (String) -> Void

    private var registration: DeviceRegistration? {
        registrations.first { $0.terminalID == InstallationIDStore.value }
    }

    private var todayList: ExecutionList? {
        executionLists.first { $0.workDateKey == ExecutionListService.todayKey() }
    }

    private var assignedDraft: TaskDraft? { drafts.first }

    private var todayItems: [ExecutionItem] {
        guard let todayList else { return [] }
        return executionItems.filter { $0.listID == todayList.id }
    }

    private var pendingItems: [ExecutionItem] {
        todayItems.filter { $0.state == .pending || $0.state == .inProgress }
    }

    private var outstandingCount: Int { pendingItems.count }
    private var completedCount: Int { todayItems.filter { $0.state == .synced || $0.state == .skipped }.count }
    private var queuedCount: Int { todayItems.filter { $0.state == .captured }.count }
    private var previewItems: [ExecutionItem] { Array(pendingItems.prefix(3)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    CodeCamPrimaryButton(
                        title: "添加扫码任务",
                        subtitle: "扫描客户现有 SN；每个 SN 创建一条任务",
                        icon: "barcode.viewfinder"
                    ) {
                        scannerPresented = true
                    }

                    if todayItems.isEmpty, todayList == nil {
                        ContentUnavailableView(
                            "暂无今日任务",
                            systemImage: "checklist",
                            description: Text(emptyDescription)
                        )
                        .frame(maxWidth: .infinity)
                        .codeCamCard()
                    } else {
                        CodeCamSectionHeader(
                            title: "今日任务",
                            trailing: todayList.map { "平台同步于 \(WallClock.time($0.updatedAt))" }
                        )

                        CodeCamTaskSummaryCard(
                            stationTitle: assignedDraft?.title ?? "当前工位任务",
                            taskLabel: "当前工位任务",
                            pending: outstandingCount,
                            completed: completedCount,
                            uploading: queuedCount,
                            progress: CodeCamProgressMath.fraction(
                                completed: completedCount,
                                total: max(todayItems.count, 1)
                            ),
                            showsChevron: false
                        )

                        CodeCamSectionHeader(title: "任务内容")
                        CodeCamKeyValueList {
                            CodeCamKeyValueRow(label: "执行范围", value: "\(todayItems.count) 个 SN")
                            CodeCamKeyValueRow(label: "待上传", value: "\(queuedCount) 条扫码记录")
                            CodeCamKeyValueRow(label: "扫码规则", value: "扫码后按产品规则执行")
                        }

                        CodeCamSectionHeader(title: "待扫码 SN", trailing: "共 \(outstandingCount) 个")
                        if previewItems.isEmpty {
                            Text("当前没有待扫码序列号")
                                .font(CodeCamTypography.listSecondary)
                                .foregroundStyle(CodeCamTheme.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .codeCamCard()
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(previewItems.enumerated()), id: \.element.id) { index, item in
                                    CodeCamSNListRow(
                                        serial: item.codeValue,
                                        productName: item.productName,
                                        productModel: item.productModel,
                                        badge: .pending
                                    )
                                    if index < previewItems.count - 1 { CodeCamListDivider() }
                                }
                            }
                            .codeCamListCard()
                        }

                        if let list = todayList {
                            NavigationLink {
                                TodayExecutionListScreen(listID: list.id, onOpenCapture: onOpenCapture)
                            } label: {
                                CodeCamWorkEntryRow(
                                    icon: "number",
                                    title: "查看全部 SN 清单",
                                    subtitle: "包含待扫码、待上传与已完成状态",
                                    trailing: "›"
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .navigationTitle("任务")
            .navigationBarTitleDisplayMode(.large)
            .codeCamPage()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await performRefresh() }
                    } label: {
                        if isRefreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(isRefreshing || !TodayListRefresh.canRefresh(registration: registration))
                    .accessibilityLabel("刷新今日清单")
                }
            }
            .task {
                if TodayListRefresh.shouldAutoRefresh(list: todayList, registration: registration) {
                    await performRefresh()
                }
            }
            .sheet(isPresented: $scannerPresented, onDismiss: consumePendingScan) {
                CodeScannerView { value in
                    pendingScannedValue = value
                    scannerPresented = false
                } onCancel: {
                    pendingScannedValue = nil
                    scannerPresented = false
                }
            }
            .alert(item: $alert) { item in
                Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("知道了")))
            }
        }
    }

    private var emptyDescription: String {
        "点击「添加扫码任务」，扫描或输入客户现有 SN。无需订单号或设备在线。"
    }

    private func consumePendingScan() {
        guard let value = pendingScannedValue else { return }
        pendingScannedValue = nil
        do {
            let (item, _) = try TaskDraftService.createScannedTask(value, in: modelContext)
            onOpenCapture(item.id)
        } catch {
            alert = AppAlert(title: "无法添加扫码任务", message: error.localizedDescription)
        }
    }

    @MainActor
    private func performRefresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        if let alert = await TodayListRefresh.refresh(in: modelContext, registration: registration, todayList: todayList) {
            self.alert = alert
        }
    }
}

/// Read-only task information opened from the scan tab. Does not switch workstation tasks.
struct StationTaskInfoView: View {
    @Query(sort: \TaskDraft.updatedAt, order: .reverse) private var drafts: [TaskDraft]
    @Query(sort: \ExecutionList.updatedAt, order: .reverse) private var executionLists: [ExecutionList]
    @Query private var executionItems: [ExecutionItem]

    private var draft: TaskDraft? { drafts.first }
    private var todayList: ExecutionList? {
        executionLists.first { $0.workDateKey == ExecutionListService.todayKey() }
    }
    private var todayItems: [ExecutionItem] {
        guard let todayList else { return [] }
        return executionItems.filter { $0.listID == todayList.id }
    }
    private var completedCount: Int { todayItems.filter { $0.state == .synced || $0.state == .skipped }.count }
    private var queuedCount: Int { todayItems.filter { $0.state == .captured }.count }
    private var outstandingCount: Int { todayItems.filter(\.state.isOutstanding).count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CodeCamDetailHero(
                    tag: "执行中",
                    tagStyle: .blue,
                    title: draft?.title ?? "当前工位任务",
                    subtitle: "平台下发至当前工位"
                )
                CodeCamKeyValueList {
                    CodeCamKeyValueRow(label: "执行范围", value: "\(todayItems.count) 个 SN，已完成 \(completedCount) 个")
                    CodeCamKeyValueRow(label: "待上传", value: "\(queuedCount) 条扫码记录")
                    CodeCamKeyValueRow(label: "扫码规则", value: "扫码后按产品规则执行")
                }
                CodeCamSectionHeader(title: "执行进度", trailing: "\(completedCount) / \(max(todayItems.count, 1))")
                CodeCamProgressLine(
                    progress: CodeCamProgressMath.fraction(completed: completedCount, total: max(todayItems.count, 1))
                )
                if let list = todayList {
                    NavigationLink {
                        TodayExecutionListScreen(listID: list.id, onOpenCapture: { _ in })
                    } label: {
                        CodeCamWorkEntryRow(
                            icon: "number",
                            title: "SN 清单",
                            subtitle: "待扫码 \(outstandingCount) · 已完成 \(completedCount)",
                            trailing: "›"
                        )
                    }
                    .buttonStyle(.plain)
                }
                CodeCamNoteCard(bodyText: "扫描 SN 后按产品规则完成记录；不在清单内的 SN 不可加入本任务。")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .navigationTitle("任务详情")
        .navigationBarTitleDisplayMode(.inline)
        .codeCamPage()
    }
}

struct TodayExecutionListScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var registrations: [DeviceRegistration]
    @Query(sort: \ExecutionList.updatedAt, order: .reverse) private var executionLists: [ExecutionList]

    @State private var isRefreshing = false
    @State private var alert: AppAlert?

    let listID: String
    let onOpenCapture: (String) -> Void

    private var registration: DeviceRegistration? {
        registrations.first { $0.terminalID == InstallationIDStore.value }
    }

    private var todayList: ExecutionList? {
        executionLists.first { $0.id == listID }
    }

    var body: some View {
        ExecutionListView(listID: listID, onOpenCapture: onOpenCapture)
            .navigationTitle("SN 清单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await performRefresh() }
                    } label: {
                        if isRefreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(isRefreshing || !TodayListRefresh.canRefresh(registration: registration))
                    .accessibilityLabel("刷新今日清单")
                }
            }
            .alert(item: $alert) { item in
                Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("知道了")))
            }
    }

    @MainActor
    private func performRefresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        if let alert = await TodayListRefresh.refresh(in: modelContext, registration: registration, todayList: todayList) {
            self.alert = alert
        }
    }
}
