import SwiftData
import SwiftUI

struct ExecutionProgressSummary: View {
    let items: [ExecutionItem]
    var title: String = "今日进度"

    private var capturedCount: Int { items.filter { $0.state == .captured || $0.state == .synced }.count }
    private var outstandingCount: Int { items.filter(\.state.isOutstanding).count }
    private var exceptionCount: Int { items.filter { $0.state == .exception }.count }
    private var queuedCount: Int { items.filter { $0.state == .captured }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text("\(capturedCount) / \(items.count)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(capturedCount), total: Double(max(items.count, 1)))
                .tint(outstandingCount == 0 && exceptionCount == 0 ? .green : .blue)
            HStack(spacing: 0) {
                ProgressMetric(title: "已采集", value: capturedCount, tint: .blue)
                ProgressMetric(title: "待处理", value: outstandingCount, tint: .orange)
                ProgressMetric(title: "异常", value: exceptionCount, tint: .red)
                ProgressMetric(title: "待上传", value: queuedCount, tint: .secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct ProgressMetric: View {
    let title: String
    let value: Int
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(value)").font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(tint)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ExecutionListView: View {
    @Query private var allLists: [ExecutionList]
    @Query private var allItems: [ExecutionItem]
    @Query private var captures: [CaptureSession]
    @Query private var drafts: [TaskDraft]

    let listID: String
    @State private var filter: ExecutionListFilter = .outstanding

    private var list: ExecutionList? { allLists.first { $0.id == listID } }
    private var items: [ExecutionItem] {
        allItems.filter { $0.listID == listID }.sorted { left, right in
            let leftOrder = left.orderSummary ?? ""
            let rightOrder = right.orderSummary ?? ""
            return leftOrder == rightOrder ? left.codeValue < right.codeValue : leftOrder < rightOrder
        }
    }
    private var filteredItems: [ExecutionItem] { items.filter { filter.includes($0.state) } }
    private var orderGroups: [String] {
        Array(Set(filteredItems.map { $0.orderSummary ?? "未分组" })).sorted()
    }

    var body: some View {
        Group {
            if let list {
                List {
                    Section {
                        ExecutionProgressSummary(items: items)
                        Picker("筛选", selection: $filter) {
                            ForEach(ExecutionListFilter.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                    } footer: {
                        Text("\(list.assignmentDescription) · 更新于 \(WallClock.time(list.updatedAt))。到「采集」扫码开始作业。")
                    }

                    if filteredItems.isEmpty {
                        Section {
                            ContentUnavailableView(
                                filter == .outstanding ? "没有待处理项" : "没有对应项",
                                systemImage: filter == .outstanding ? "checkmark.circle" : "line.3.horizontal.decrease.circle",
                                description: Text(filter == .outstanding ? "今日清单已处理完，可到「记录」查看结果。" : "试试其他筛选。")
                            )
                            .listRowBackground(Color.clear)
                        }
                    } else {
                        ForEach(orderGroups, id: \.self) { order in
                            Section(order) {
                                ForEach(filteredItems.filter { ($0.orderSummary ?? "未分组") == order }) { item in
                                    executionRow(item)
                                }
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("执行清单不存在", systemImage: "checklist.unchecked", description: Text("请刷新今日任务，或先在「我的」完成设备连接。"))
            }
        }
    }

    @ViewBuilder
    private func executionRow(_ item: ExecutionItem) -> some View {
        let capture = item.captureID.flatMap { captureID in captures.first { $0.id == captureID } }
        let draft = drafts.first { $0.id == item.draftID }
        Group {
            if let capture, let draft {
                NavigationLink {
                    ProductCaptureView(captureID: capture.id, draftID: draft.id, isHistory: capture.isCompleted)
                } label: {
                    ExecutionItemRow(item: item)
                }
            } else {
                ExecutionItemRow(item: item)
            }
        }
    }
}

private struct ExecutionItemRow: View {
    let item: ExecutionItem

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                ProductIdentityRow(
                    code: item.codeValue,
                    productName: item.productName,
                    productModel: item.productModel
                )
                if let reason = item.exceptionReason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            ExecutionStateBadge(state: item.state)
        }
    }
}

private struct ExecutionStateBadge: View {
    let state: ExecutionItemState
    var body: some View { StatusCapsule(title: state.title, tint: state.tint) }
}

private enum ExecutionListFilter: String, CaseIterable, Identifiable {
    case outstanding
    case completed
    case exception
    case all

    var id: String { rawValue }
    var title: String {
        switch self {
        case .outstanding: "待处理"
        case .completed: "已完成"
        case .exception: "异常"
        case .all: "全部"
        }
    }

    func includes(_ state: ExecutionItemState) -> Bool {
        switch self {
        case .outstanding: state.isOutstanding
        case .completed: state == .captured || state == .synced || state == .skipped
        case .exception: state == .exception || state == .cancelled
        case .all: true
        }
    }
}
