import SwiftUI
import SwiftData
import UIKit

private enum RecordsScope: String, CaseIterable, Identifiable {
    case all, today, pendingUpload

    var id: String { rawValue }
}

/// Local records are explicitly separated from future factory-authorized platform results.
struct RecordsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CaptureSession.scannedAt, order: .reverse) private var captures: [CaptureSession]
    @Query(sort: \LocalMedia.capturedAt, order: .reverse) private var media: [LocalMedia]
    @Query private var events: [LocalEvent]
    @State private var search = ""
    @State private var scope: RecordsScope = .all
    @State private var scannerPresented = false

    private var baseResults: [CaptureSession] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return captures.filter { item in
            term.isEmpty || [item.codeValue, item.productName ?? "", item.productModel ?? ""]
                .contains { $0.localizedStandardContains(term) }
        }
    }

    private var todayCount: Int {
        baseResults.filter { Calendar.current.isDateInToday($0.scannedAt) }.count
    }

    private var pendingUploadCount: Int {
        baseResults.filter { isPendingUpload($0) }.count
    }

    private var results: [CaptureSession] {
        switch scope {
        case .all: return baseResults
        case .today: return baseResults.filter { Calendar.current.isDateInToday($0.scannedAt) }
        case .pendingUpload: return baseResults.filter { isPendingUpload($0) }
        }
    }

    private var dates: [Date] {
        Array(Set(results.map { Calendar.current.startOfDay(for: $0.scannedAt) })).sorted(by: >)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    CodeCamSearchBar(
                        text: $search,
                        placeholder: "序列号、产品名称、型号",
                        showsScanButton: true,
                        onScan: { scannerPresented = true }
                    )

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            CodeCamFilterChip(title: "全部 \(baseResults.count)", isSelected: scope == .all) { scope = .all }
                            CodeCamFilterChip(title: "今天 \(todayCount)", isSelected: scope == .today) { scope = .today }
                            CodeCamFilterChip(title: "待上传 \(pendingUploadCount)", isSelected: scope == .pendingUpload) { scope = .pendingUpload }
                        }
                    }

                    CodeCamRecordSummaryLine(leading: "按扫码时间排序", trailing: "含照片、视频和备注")

                    if results.isEmpty {
                        ContentUnavailableView(
                            "没有符合条件的记录",
                            systemImage: "clock.arrow.circlepath",
                            description: Text("可改筛选条件，或扫码按序列号查找。")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    } else {
                        ForEach(dates, id: \.self) { day in
                            let dayItems = results.filter { Calendar.current.isDate($0.scannedAt, inSameDayAs: day) }
                            CodeCamDateSectionLabel(title: recordsDateTitle(day))
                            VStack(spacing: 0) {
                                ForEach(Array(dayItems.enumerated()), id: \.element.id) { index, item in
                                    NavigationLink {
                                        ProductCaptureView(captureID: item.id, draftID: item.draftID, isHistory: true)
                                    } label: {
                                        CodeCamScanRow(
                                            serial: item.codeValue,
                                            productName: item.productName,
                                            productModel: item.productModel,
                                            mediaSummary: mediaSummary(for: item.id),
                                            stateTitle: stateTitle(for: item),
                                            timeCaption: WallClock.time(item.scannedAt),
                                            palette: CodeCamScanThumbPalette.forIndex(index),
                                            thumbnail: thumbnail(for: item.id)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    if index < dayItems.count - 1 { CodeCamListDivider() }
                                }
                            }
                            .codeCamListCard()
                        }
                    }

                    Text("仅本机扫码记录。共 \(results.count) 条。")
                        .font(.caption)
                        .foregroundStyle(CodeCamTheme.muted)
                        .padding(.horizontal, 2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .navigationTitle("记录")
            .navigationBarTitleDisplayMode(.large)
            .codeCamPage()
            .sheet(isPresented: $scannerPresented) {
                CodeScannerView { code in
                    search = code.trimmingCharacters(in: .whitespacesAndNewlines)
                    scope = .all
                    scannerPresented = false
                } onCancel: { scannerPresented = false }
            }
            .task {
                EdgeFlowSyncService.healAllMediaPaths(in: modelContext)
            }
        }
    }

    private func thumbnail(for captureID: String?) -> UIImage? {
        guard let captureID else { return nil }
        return media.first(where: { $0.captureID == captureID })?.thumbnailImage
    }

    private func mediaSummary(for captureID: String) -> String? {
        let items = media.filter { $0.captureID == captureID && !$0.isRelatedMedia }
        let photos = items.filter { $0.mediaType == "image" }.count
        let videos = items.filter { $0.mediaType == "video" }.count
        guard photos > 0 || videos > 0 else { return nil }
        var parts: [String] = []
        if photos > 0 { parts.append("\(photos) 照片") }
        if videos > 0 { parts.append("\(videos) 录像") }
        return parts.joined(separator: " · ")
    }

    private func isPendingUpload(_ capture: CaptureSession) -> Bool {
        let relatedEvents = events.filter { $0.captureID == capture.id }
        let relatedMedia = media.filter { $0.captureID == capture.id }
        guard !relatedEvents.isEmpty || !relatedMedia.isEmpty else { return !capture.isCompleted }
        let eventsSynced = relatedEvents.isEmpty || relatedEvents.allSatisfy { $0.syncStateRaw == SyncState.synced.rawValue }
        let mediaSynced = relatedMedia.isEmpty || relatedMedia.allSatisfy { $0.syncState == .synced }
        return !(eventsSynced && mediaSynced)
    }

    private func stateTitle(for capture: CaptureSession) -> String {
        isPendingUpload(capture) ? "待上传" : "已完成"
    }

    private func recordsDateTitle(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        if Calendar.current.isDateInToday(day) {
            formatter.setLocalizedDateFormatFromTemplate("Md")
            return "今天 · \(formatter.string(from: day))"
        }
        if Calendar.current.isDateInYesterday(day) {
            formatter.setLocalizedDateFormatFromTemplate("Md")
            return "昨天 · \(formatter.string(from: day))"
        }
        formatter.setLocalizedDateFormatFromTemplate("yyyyMd")
        return formatter.string(from: day)
    }
}

private struct SerialRecordsView: View {
    let serial: String
    @Query(sort: \CaptureSession.scannedAt, order: .forward) private var captures: [CaptureSession]
    @Query private var drafts: [TaskDraft]
    @Query private var allMedia: [LocalMedia]
    @Query private var allNotes: [CaptureNote]
    @Query private var allRelated: [RelatedScan]
    @State private var expandedCaptureIDs = Set<String>()
    @State private var preview: LocalMedia?

    private var records: [CaptureSession] {
        captures.filter { $0.codeValue == serial }
    }

    private var productName: String? {
        records.compactMap(\.productName).last
    }

    private var productModel: String? {
        records.compactMap(\.productModel).last
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SerialProfileHeader(serial: serial, productName: productName, productModel: productModel)
                    .padding(.bottom, 22)

                Text("扫码时间线")
                    .font(.headline)
                    .padding(.bottom, 14)

                ForEach(Array(records.enumerated()), id: \.element.id) { index, capture in
                    CaptureTimelineNode(
                        capture: capture,
                        taskName: drafts.first { $0.id == capture.draftID }?.title ?? "未知任务",
                        media: allMedia
                            .filter { $0.captureID == capture.id && !$0.isRelatedMedia }
                            .sorted { $0.capturedAt < $1.capturedAt },
                        notes: allNotes
                            .filter { $0.captureID == capture.id }
                            .sorted { $0.createdAt < $1.createdAt },
                        relatedScans: allRelated
                            .filter { $0.parentCaptureID == capture.id }
                            .sorted { $0.createdAt < $1.createdAt },
                        relatedMedia: allMedia.filter { $0.captureID == capture.id && $0.isRelatedMedia },
                        showsConnector: index < records.count - 1,
                        isExpanded: expandedCaptureIDs.contains(capture.id),
                        onToggleMedia: {
                            if expandedCaptureIDs.contains(capture.id) {
                                expandedCaptureIDs.remove(capture.id)
                            } else {
                                expandedCaptureIDs.insert(capture.id)
                            }
                        },
                        onPreview: {
                            MediaFileStore.healStoredPaths(for: $0)
                            preview = $0
                        }
                    )
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 16)
        }
        .navigationTitle(serial)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $preview) { MediaPreviewView(item: $0) }
    }
}

private struct SerialProfileHeader: View {
    let serial: String
    let productName: String?
    let productModel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("序列号", systemImage: "barcode")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(serial)
                .font(.title3.weight(.semibold).monospaced())
                .textSelection(.enabled)

            if productName != nil || productModel != nil {
                Divider().padding(.vertical, 2)
                if let productName {
                    LabeledContent("产品", value: productName)
                }
                if let productModel {
                    LabeledContent("型号", value: productModel)
                }
            } else {
                Text("产品资料尚未获取")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct CaptureTimelineNode: View {
    let capture: CaptureSession
    let taskName: String
    let media: [LocalMedia]
    let notes: [CaptureNote]
    let relatedScans: [RelatedScan]
    let relatedMedia: [LocalMedia]
    let showsConnector: Bool
    let isExpanded: Bool
    let onToggleMedia: () -> Void
    let onPreview: (LocalMedia) -> Void

    private var displayedMedia: [LocalMedia] {
        isExpanded ? media : Array(media.prefix(6))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle()
                    .fill(.tint)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(.background, lineWidth: 3))
                    .padding(.top, 18)
                if showsConnector {
                    Rectangle()
                        .fill(.quaternary)
                        .frame(width: 2, height: 34)
                }
            }
            .frame(width: 16)

            VStack(alignment: .leading, spacing: 12) {
                NavigationLink {
                    ProductCaptureView(captureID: capture.id, draftID: capture.draftID, isHistory: true)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(WallClock.dateTime(capture.scannedAt))
                                .font(.subheadline.weight(.semibold))
                            Label(taskName, systemImage: "checklist")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)

                if media.isEmpty {
                    Text("暂无媒体资源")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 96, maximum: 112), spacing: 9)],
                        alignment: .leading,
                        spacing: 9
                    ) {
                        ForEach(displayedMedia) { item in
                            Button { onPreview(item) } label: {
                                MediaThumbnail(item: item, size: 104)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.mediaType == "video" ? "播放录像" : "查看照片")
                        }
                    }

                    if media.count > 6 {
                        Button(isExpanded ? "收起媒体" : "还有 \(media.count - 6) 项媒体") {
                            onToggleMedia()
                        }
                        .font(.subheadline.weight(.medium))
                    }
                }

                ForEach(notes) { note in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(note.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Label(WallClock.dateTime(note.createdAt), systemImage: "text.bubble")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                ForEach(relatedScans, id: \.id) { related in
                    let items = relatedMedia.filter { $0.relatedScanID == related.id }.sorted { $0.capturedAt < $1.capturedAt }
                    VStack(alignment: .leading, spacing: 8) {
                        Label(related.kind.title, systemImage: "link")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(related.codeValue)
                            .font(.body.monospaced())
                        Text(WallClock.dateTime(related.createdAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !items.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(items) { item in
                                        Button { onPreview(item) } label: {
                                            MediaThumbnail(item: item, size: 72)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(.bottom, showsConnector ? 0 : 8)
    }
}

private struct RecordSummaryRow: View {
    let capture: CaptureSession
    var thumbnail: UIImage?
    var body: some View {
        ProductIdentityRow(
            code: capture.codeValue,
            productName: capture.productName,
            productModel: capture.productModel,
            caption: WallClock.dateTime(capture.scannedAt),
            thumbnail: thumbnail,
            showsThumbnailSlot: true
        )
    }
}

private struct RecordReadOnlyView: View {
    let capture: CaptureSession
    @Query private var drafts: [TaskDraft]
    @Query private var allMedia: [LocalMedia]
    @Query private var allNotes: [CaptureNote]
    @Query private var allRelated: [RelatedScan]
    @Query private var events: [LocalEvent]
    @State private var preview: LocalMedia?
    private var media: [LocalMedia] { allMedia.filter { $0.captureID == capture.id && !$0.isRelatedMedia }.sorted { $0.capturedAt < $1.capturedAt } }
    private var notes: [CaptureNote] { allNotes.filter { $0.captureID == capture.id }.sorted { $0.createdAt > $1.createdAt } }
    private var relatedScans: [RelatedScan] { allRelated.filter { $0.parentCaptureID == capture.id }.sorted { $0.createdAt < $1.createdAt } }
    private var uploaded: Bool {
        let relatedEvents = events.filter { $0.captureID == capture.id }
        let relatedMedia = allMedia.filter { $0.captureID == capture.id }
        return !relatedEvents.isEmpty && relatedEvents.allSatisfy { $0.syncStateRaw == SyncState.synced.rawValue }
            && relatedMedia.allSatisfy { $0.syncState == .synced }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CodeCamDetailHero(
                    tag: uploaded ? "已同步" : "待上传",
                    tagStyle: uploaded ? .mint : .blue,
                    title: capture.codeValue,
                    subtitle: drafts.first { $0.id == capture.draftID }?.title ?? "未知任务"
                )
                CodeCamKeyValueList {
                    CodeCamKeyValueRow(label: "产品", value: capture.productName ?? "尚未获取")
                    CodeCamKeyValueRow(label: "型号", value: capture.productModel ?? "尚未获取")
                    CodeCamKeyValueRow(label: "扫码时间", value: WallClock.dateTime(capture.scannedAt))
                    CodeCamKeyValueRow(label: "上传状态", value: uploaded ? "已上传" : "待上传", valueColor: uploaded ? CodeCamTheme.green : CodeCamTheme.orange)
                }
                CodeCamSectionHeader(
                    title: "媒体",
                    trailing: "照片 \(media.filter { $0.mediaType == "image" }.count) / 录像 \(media.filter { $0.mediaType == "video" }.count)"
                )
                if media.isEmpty {
                    Text("暂无媒体资源").font(.subheadline).foregroundStyle(CodeCamTheme.muted).codeCamCard()
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 8) {
                        ForEach(media) { item in
                            Button {
                                MediaFileStore.healStoredPaths(for: item)
                                preview = item
                            } label: {
                                MediaThumbnail(item: item, size: 76)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !relatedScans.isEmpty {
                    CodeCamSectionHeader(title: "关联码")
                    VStack(spacing: 0) {
                        ForEach(relatedScans, id: \.id) { related in
                            NavigationLink {
                                RelatedScanCaptureView(relatedScanID: related.id)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(related.codeValue).font(.subheadline.monospaced())
                                        Text("\(related.kind.title) · \(WallClock.dateTime(related.createdAt))")
                                            .font(.caption).foregroundStyle(CodeCamTheme.muted)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(CodeCamTheme.muted)
                                }
                                .padding(12)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .codeCamListCard()
                }
                CodeCamSectionHeader(title: "备注")
                if notes.isEmpty {
                    Text("暂无备注").font(.subheadline).foregroundStyle(CodeCamTheme.muted)
                } else {
                    ForEach(notes) { note in
                        CodeCamNoteCard(timeCaption: WallClock.time(note.createdAt), bodyText: note.text)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .navigationTitle("记录详情")
        .navigationBarTitleDisplayMode(.inline)
        .codeCamPage()
        .sheet(item: $preview) { MediaPreviewView(item: $0) }
    }
}
