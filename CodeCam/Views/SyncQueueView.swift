import SwiftData
import SwiftUI

struct SyncQueueView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \OutboxItem.createdAt, order: .reverse) private var items: [OutboxItem]
    @Query private var events: [LocalEvent]
    @Query private var captures: [CaptureSession]
    @Query private var drafts: [TaskDraft]
    @Query private var media: [LocalMedia]
    @State private var syncing = false
    @State private var alert: AppAlert?

    private var pendingItems: [OutboxItem] {
        items.filter { $0.state != .synced && $0.state != .abandoned }
    }

    private var abandonedItems: [OutboxItem] {
        items.filter { $0.state == .abandoned }
    }

    private var syncedItems: [OutboxItem] { items.filter { $0.state == .synced } }

    private var canSync: Bool {
        let now = Date.now
        return pendingItems.contains {
            switch $0.state {
            case .queued, .failed:
                return $0.nextRetryAt == nil || $0.nextRetryAt! <= now
            case .needsReview, .uploading, .registering, .conflict:
                return true
            default:
                return false
            }
        }
    }

    var body: some View {
        List {
            Section {
                Text("拍照、录像、备注后会自动尝试同步。失败项仍保存在本机，可重试或放弃。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(syncing ? "正在同步…" : "立即同步") { sync() }
                    .disabled(syncing || !canSync)
            }
            Section("待同步内容（\(pendingItems.count)）") {
                if pendingItems.isEmpty {
                    ContentUnavailableView("暂无待同步内容", systemImage: "checkmark.circle")
                } else {
                    ForEach(pendingItems) { item in
                        queueRow(for: item)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if item.state == .failed || item.state == .needsReview || item.state == .conflict || item.state == .queued {
                                    Button("重试") {
                                        EdgeFlowSyncService.retry(item, in: modelContext)
                                    }
                                    .tint(.blue)
                                    Button("放弃", role: .destructive) {
                                        EdgeFlowSyncService.abandon(item, in: modelContext)
                                    }
                                }
                            }
                    }
                }
            }
            if !abandonedItems.isEmpty {
                Section {
                    DisclosureGroup("已放弃（\(abandonedItems.count)）") {
                        ForEach(abandonedItems) { item in
                            queueRow(for: item)
                                .swipeActions(edge: .trailing) {
                                    Button("重新排队") {
                                        EdgeFlowSyncService.retry(item, in: modelContext)
                                    }
                                    .tint(.blue)
                                }
                        }
                    }
                }
            }
            if !syncedItems.isEmpty {
                Section {
                    DisclosureGroup("已同步内容（\(syncedItems.count)）") {
                        ForEach(syncedItems) { item in
                            queueRow(for: item)
                        }
                    }
                }
            }
        }
        .navigationTitle("同步队列")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            SyncScheduler.schedule(in: modelContext, delayNanoseconds: 500_000_000)
        }
        .alert(item: $alert) { item in
            Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("知道了")))
        }
    }

    private func queueRow(for item: OutboxItem) -> some View {
        let event = events.first { $0.eventID == item.eventID }
        let capture = captures.first { $0.id == event?.captureID }
        let draft = drafts.first { $0.id == event?.draftID }
        let payload = (try? JSONSerialization.jsonObject(with: Data((event?.payloadJSON ?? item.bodyJSON).utf8))) as? [String: String] ?? [:]
        let attachment = media.first { $0.mediaID == payload["mediaId"] }
        let code = event?.codeValue ?? capture?.codeValue ?? payload["code"] ?? "未关联序列号"

        return VStack(alignment: .leading, spacing: 8) {
            Text(code)
                .font(.headline.monospaced())
                .textSelection(.enabled)
            HStack(alignment: .top, spacing: 10) {
                if let attachment { MediaThumbnail(item: attachment, size: 48) }
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Label(contentTitle(for: item.kind), systemImage: contentIcon(for: item.kind))
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        SyncStateBadge(state: item.state)
                    }
                    if let note = payload["note"], !note.isEmpty {
                        Text(note)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if item.kind == "related.scanned", let relatedCode = payload["relatedCode"] {
                        Text(relatedCode)
                            .font(.subheadline.monospaced())
                    }
                    if item.kind == "capture.completed", let count = payload["mediaCount"] {
                        Text("本次采集了 \(count) 项媒体")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let draft {
                        Text(draft.title).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(WallClock.dateTime(event?.occurredAt ?? item.createdAt))
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = item.lastError, !error.isEmpty, item.state != .synced {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    guidanceText(for: item)
                }
            }
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func guidanceText(for item: OutboxItem) -> some View {
        if item.state == .failed, let nextRetryAt = item.nextRetryAt, nextRetryAt > .now {
            Text("将于 \(WallClock.time(nextRetryAt)) 自动重试。也可左滑重试或放弃。")
                .font(.caption).foregroundStyle(.orange)
        } else if item.state == .failed {
            Text("同步未成功。可左滑重试，或放弃本条。")
                .font(.caption).foregroundStyle(.orange)
        } else if item.state == .conflict {
            Text("平台数据存在冲突。可左滑重试或放弃。")
                .font(.caption).foregroundStyle(.red)
        } else if item.state == .needsReview {
            Text("需人工确认。可左滑重试；本地文件缺失时可放弃。")
                .font(.caption).foregroundStyle(.orange)
        } else if item.state == .abandoned {
            Text("已放弃上传到平台，本地记录仍保留。左滑可重新排队。")
                .font(.caption).foregroundStyle(.secondary)
        } else if item.state == .queued {
            Text("等待自动同步，也可点上方立即同步。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func contentTitle(for kind: String) -> String {
        switch kind {
        case "code.scanned": "扫码记录"
        case "media.captured": "照片"
        case "media.recorded": "录像"
        case "related.scanned": "关联扫码"
        case "note.added": "新增备注"
        case "capture.completed": "完成采集"
        case "form.saved": "保存表单"
        case "form.submitted": "提交表单"
        default: "采集记录"
        }
    }

    private func contentIcon(for kind: String) -> String {
        switch kind {
        case "code.scanned": "barcode.viewfinder"
        case "media.captured": "photo"
        case "media.recorded": "video"
        case "related.scanned": "link"
        case "note.added": "text.bubble"
        case "capture.completed": "checkmark.circle"
        default: "doc.text"
        }
    }

    private func sync() {
        syncing = true
        Task {
            defer { syncing = false }
            do {
                let count = try await EdgeFlowSyncService.syncAll(in: modelContext)
                let remaining = try modelContext.fetch(FetchDescriptor<OutboxItem>()).filter {
                    $0.state != .synced && $0.state != .abandoned
                }.count
                alert = AppAlert(
                    title: remaining == 0 ? "同步完成" : "仍有内容待同步",
                    message: "本次成功同步 \(count) 项。" + (remaining == 0 ? "" : "还有 \(remaining) 项未完成，可左滑重试或放弃。")
                )
            } catch {
                alert = AppAlert(title: "暂时无法同步", message: error.localizedDescription)
            }
        }
    }
}
