import SwiftData
import SwiftUI

struct ExecutionProgressSummary: View {
    let items: [ExecutionItem]
    let onSelect: (ExecutionListFilter) -> Void

    private var completedCount: Int { items.filter { $0.state == .synced || $0.state == .skipped }.count }
    private var queuedCount: Int { items.filter { $0.state == .captured }.count }
    private var pendingCount: Int { items.filter { $0.state == .pending }.count }
    private var exceptionCount: Int { items.filter { $0.state == .exception || $0.state == .cancelled }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("今日执行进度").font(.headline.weight(.semibold))
                Spacer()
                Text("\(completedCount) / \(items.count)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(CodeCamTheme.muted)
            }
            ProgressView(value: Double(completedCount), total: Double(max(items.count, 1)))
                .tint(pendingCount == 0 && exceptionCount == 0 && queuedCount == 0 ? .green : .blue)
            HStack(spacing: 0) {
                metric("待处理", pendingCount, .orange, .outstanding)
                Divider().frame(height: 28)
                metric("进行中", items.filter { $0.state == .inProgress }.count, .blue, .inProgress)
                Divider().frame(height: 28)
                metric("待上传", queuedCount, .secondary, .queued)
                Divider().frame(height: 28)
                metric("异常", exceptionCount, .red, .exception)
            }
        }
        .padding(.vertical, 4)
    }

    private func metric(_ title: String, _ value: Int, _ tint: Color, _ filter: ExecutionListFilter) -> some View {
        Button { onSelect(filter) } label: {
            VStack(spacing: 3) {
                Text("\(value)").font(.subheadline.weight(.bold).monospacedDigit()).foregroundStyle(tint)
                Text(title).font(.caption2).foregroundStyle(CodeCamTheme.muted)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) \(value) 项")
    }
}

struct ExecutionListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allLists: [ExecutionList]
    @Query private var allItems: [ExecutionItem]
    @Query private var captures: [CaptureSession]
    @Query private var drafts: [TaskDraft]

    let listID: String
    let onOpenCapture: (String) -> Void
    @State private var filter: ExecutionListFilter = .outstanding
    @State private var snSearch = ""

    private var list: ExecutionList? { allLists.first { $0.id == listID } }
    private var items: [ExecutionItem] {
        allItems.filter { $0.listID == listID }.sorted { left, right in
            if left.state.isOutstanding != right.state.isOutstanding { return left.state.isOutstanding }
            if left.priority.sortOrder != right.priority.sortOrder { return left.priority.sortOrder < right.priority.sortOrder }
            switch (left.dueAt, right.dueAt) {
            case let (leftDue?, rightDue?) where leftDue != rightDue: return leftDue < rightDue
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            let leftOrder = left.orderSummary ?? ""
            let rightOrder = right.orderSummary ?? ""
            return leftOrder == rightOrder ? left.codeValue < right.codeValue : leftOrder < rightOrder
        }
    }
    private var filteredItems: [ExecutionItem] {
        let term = snSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { filter.includes($0) }.filter { item in
            term.isEmpty || item.codeValue.localizedStandardContains(term)
                || (item.productName ?? "").localizedStandardContains(term)
                || (item.productModel ?? "").localizedStandardContains(term)
        }
    }

    private var outstandingSNCount: Int { items.filter { $0.state == .pending || $0.state == .inProgress }.count }
    private var completedSNCount: Int { items.filter { $0.state == .synced || $0.state == .skipped }.count }
    private var orderGroups: [String] { Array(Set(filteredItems.map { $0.orderSummary ?? "未分组" })).sorted() }
    private var priorityItem: ExecutionItem? { items.first { $0.state == .inProgress } ?? items.first { $0.state == .pending } }
    private var queuedCount: Int { items.filter { $0.state == .captured }.count }

    var body: some View {
        Group {
            if let list {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let notice = list.lastChangeNotice, !notice.isEmpty {
                            HStack(spacing: 9) {
                                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                                Text(notice).font(.caption).foregroundStyle(CodeCamTheme.muted)
                                Spacer()
                                Button("知道了") { list.lastChangeNotice = nil; try? modelContext.save() }
                                    .font(.caption.weight(.semibold)).foregroundStyle(CodeCamTheme.blue)
                            }.codeCamCard(padding: 12)
                        }

                        CodeCamSearchBar(text: $snSearch, placeholder: "搜索 SN")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 7) {
                                CodeCamFilterChip(
                                    title: "待扫码 \(outstandingSNCount)",
                                    isSelected: filter == .outstanding
                                ) { filter = .outstanding }
                                CodeCamFilterChip(
                                    title: "待上传 \(queuedCount)",
                                    isSelected: filter == .queued
                                ) { filter = .queued }
                                CodeCamFilterChip(
                                    title: "已完成 \(completedSNCount)",
                                    isSelected: filter == .completed
                                ) { filter = .completed }
                                CodeCamFilterChip(
                                    title: "全部 \(items.count)",
                                    isSelected: filter == .all
                                ) { filter = .all }
                            }
                        }
                        Text("仅可扫码本任务清单内的 SN")
                            .font(CodeCamTypography.listMeta)
                            .foregroundStyle(CodeCamTheme.muted)
                            .padding(.horizontal, 2)

                        if filteredItems.isEmpty {
                            ContentUnavailableView(filter == .outstanding ? "没有待扫码项" : "没有对应项", systemImage: "checkmark.circle", description: Text("试试切换其他筛选条件。"))
                                .frame(maxWidth: .infinity).codeCamCard()
                        } else {
                            VStack(spacing: 0) {
                                ForEach(filteredItems) { item in
                                    snListRow(item)
                                    if item.id != filteredItems.last?.id { CodeCamListDivider() }
                                }
                            }
                            .codeCamListCard()
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
                .codeCamPage()
            } else {
                ContentUnavailableView("执行清单不存在", systemImage: "checklist.unchecked", description: Text("请刷新今日任务，或先在「我的」完成设备连接。"))
            }
        }
    }

    @ViewBuilder
    private func snListRow(_ item: ExecutionItem) -> some View {
        let capture = item.captureID.flatMap { captureID in captures.first { $0.id == captureID } }
        let draft = drafts.first { $0.id == item.draftID }
        let badge = CodeCamSNBadgeKind.from(item.state)
        Group {
            if let capture, let draft {
                NavigationLink {
                    ProductCaptureView(captureID: capture.id, draftID: draft.id, isHistory: capture.isCompleted)
                } label: {
                    CodeCamSNListRow(
                        serial: item.codeValue,
                        productName: item.productName,
                        productModel: item.productModel,
                        badge: badge
                    )
                }
            } else if item.state.isOutstanding {
                Button { onOpenCapture(item.id) } label: {
                    CodeCamSNListRow(
                        serial: item.codeValue,
                        productName: item.productName,
                        productModel: item.productModel,
                        badge: .pending
                    )
                }
            } else {
                CodeCamSNListRow(
                    serial: item.codeValue,
                    productName: item.productName,
                    productModel: item.productModel,
                    badge: badge
                )
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func taskCard(_ item: ExecutionItem) -> some View {
        let capture = item.captureID.flatMap { captureID in captures.first { $0.id == captureID } }
        let draft = drafts.first { $0.id == item.draftID }
        Group {
            if let capture, let draft {
                NavigationLink { ProductCaptureView(captureID: capture.id, draftID: draft.id, isHistory: capture.isCompleted) } label: { taskCardContent(item) }
            } else if item.state != .cancelled {
                NavigationLink { TaskDetailView(itemID: item.id, onOpenCapture: onOpenCapture) } label: { taskCardContent(item) }
            } else { taskCardContent(item) }
        }
        .buttonStyle(.plain)
        .codeCamCard(padding: 13)
    }

    private func taskCardContent(_ item: ExecutionItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                StatusCapsule(title: item.priority.title, tint: item.priority.tint)
                Spacer()
                ExecutionStateBadge(state: item.state)
            }
            Text(item.codeValue).font(.subheadline.monospaced().weight(.semibold))
            Text([item.productName, item.productModel].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundStyle(CodeCamTheme.muted)
            HStack {
                Text(item.requirementSummary.isEmpty ? "扫码后按产品规则执行" : item.requirementSummary).font(.caption).foregroundStyle(CodeCamTheme.muted).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(CodeCamTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func syncStatus(for list: ExecutionList) -> some View {
        let hasError = !(list.lastRefreshError ?? "").isEmpty
        HStack(spacing: 8) {
            Image(systemName: hasError ? "wifi.slash" : "checkmark.icloud")
                .foregroundStyle(hasError ? .orange : .green)
            VStack(alignment: .leading, spacing: 2) {
                Text(hasError ? "当前使用本地缓存" : "今日清单已同步").font(.subheadline.weight(.medium))
                Text(hasError ? (list.lastRefreshError ?? "网络恢复后会自动重试") : "更新于 \(WallClock.time(list.updatedAt)) · 版本 \(list.sourceVersion)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private func priorityCard(_ item: ExecutionItem) -> some View {
        Button { onOpenCapture(item.id) } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label(item.state == .inProgress ? "继续采集" : "待执行", systemImage: item.state == .inProgress ? "play.circle.fill" : "barcode.viewfinder")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    ExecutionStateBadge(state: item.state)
                }
                taskMeta(item)
                ProductIdentityRow(code: item.codeValue, productName: item.productName, productModel: item.productModel)
                Text(item.orderSummary ?? "未关联订单").font(.caption).foregroundStyle(.secondary)
                Text("打开采集页后扫码开始").font(.caption).foregroundStyle(.tint)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func executionRow(_ item: ExecutionItem) -> some View {
        let capture = item.captureID.flatMap { captureID in captures.first { $0.id == captureID } }
        let draft = drafts.first { $0.id == item.draftID }
        if let capture, let draft {
            NavigationLink { ProductCaptureView(captureID: capture.id, draftID: draft.id, isHistory: capture.isCompleted) } label: {
                ExecutionItemRow(item: item, showsCaptureHint: false)
            }
        } else if item.state != .cancelled {
            NavigationLink { TaskDetailView(itemID: item.id, onOpenCapture: onOpenCapture) } label: {
                ExecutionItemRow(item: item, showsCaptureHint: item.state.isOutstanding)
            }
        } else {
            ExecutionItemRow(item: item, showsCaptureHint: false)
        }
    }

    @ViewBuilder
    private func taskMeta(_ item: ExecutionItem) -> some View {
        HStack(spacing: 6) {
            StatusCapsule(title: item.priority.title, tint: item.priority.tint)
            if let dueAt = item.dueAt {
                Label("截止 \(WallClock.dateTime(dueAt))", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if !item.requirementSummary.isEmpty {
            Label(item.requirementSummary, systemImage: "checklist")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ExecutionItemRow: View {
    let item: ExecutionItem
    let showsCaptureHint: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                ProductIdentityRow(code: item.codeValue, productName: item.productName, productModel: item.productModel)
                if let order = item.orderSummary, !order.isEmpty { Text(order).font(.caption).foregroundStyle(.secondary) }
                if let notice = item.changeNotice, !notice.isEmpty {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
                if let reason = item.exceptionReason, !reason.isEmpty {
                    Text(reason).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else if showsCaptureHint {
                    Text("轻点后前往采集页扫码执行").font(.caption).foregroundStyle(.secondary)
                }
                if !item.requirementSummary.isEmpty || item.dueAt != nil {
                    HStack(spacing: 5) {
                        StatusCapsule(title: item.priority.title, tint: item.priority.tint)
                        if !item.requirementSummary.isEmpty { Text(item.requirementSummary).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
            }
            Spacer(minLength: 4)
            ExecutionStateBadge(state: item.state)
        }
    }
}

private struct ExecutionStateBadge: View {
    let state: ExecutionItemState
    var body: some View { StatusCapsule(title: state.title, tint: state.tint) }
}

enum ExecutionListFilter: String, CaseIterable, Identifiable {
    case outstanding, inProgress, queued, changed, completed, exception, all

    var id: String { rawValue }
    var title: String {
        switch self {
        case .outstanding: "待处理"
        case .inProgress: "进行中"
        case .queued: "待上传"
        case .changed: "有变更"
        case .completed: "已完成"
        case .exception: "异常"
        case .all: "全部"
        }
    }

    func includes(_ item: ExecutionItem) -> Bool {
        let state = item.state
        switch self {
        case .outstanding: return state == .pending || state == .inProgress
        case .inProgress: return state == .inProgress
        case .queued: return state == .captured
        case .changed: return !(item.changeNotice ?? "").isEmpty
        case .completed: return state == .synced || state == .skipped
        case .exception: return state == .exception || state == .cancelled
        case .all: return true
        }
    }
}
