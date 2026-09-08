import SwiftUI
import SwiftData
import UIKit

/// Local records are explicitly separated from future factory-authorized platform results.
struct RecordsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CaptureSession.scannedAt, order: .reverse) private var captures: [CaptureSession]
    @Query(sort: \LocalMedia.capturedAt, order: .reverse) private var media: [LocalMedia]
    @State private var search = ""
    @State private var bySerial = false
    @State private var days = 0
    @State private var scannerPresented = false

    private var results: [CaptureSession] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = Calendar.current.startOfDay(for: .now)
        let cutoff = Calendar.current.date(byAdding: .day, value: -(max(days, 1) - 1), to: start) ?? start
        return captures.filter { item in
            (days == 0 || item.scannedAt >= cutoff) &&
            (term.isEmpty || [item.codeValue, item.productName ?? "", item.productModel ?? ""]
                .contains { $0.localizedStandardContains(term) })
        }
    }

    private var serials: [String] {
        var seen = Set<String>()
        return results.compactMap { seen.insert($0.codeValue).inserted ? $0.codeValue : nil }
    }

    private var dates: [Date] {
        Array(Set(results.map { Calendar.current.startOfDay(for: $0.scannedAt) })).sorted(by: >)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("查看方式", selection: $bySerial) {
                        Text("按时间").tag(false)
                        Text("按序列号").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Picker("时间范围", selection: $days) {
                        Text("全部").tag(0)
                        Text("今天").tag(1)
                        Text("近七天").tag(7)
                        Text("近三十天").tag(30)
                    }
                    HStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("序列号、产品名称或型号", text: $search)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.search)
                            if !search.isEmpty {
                                Button {
                                    search = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("清除搜索")
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Button {
                            scannerPresented = true
                        } label: {
                            Image(systemName: "barcode.viewfinder")
                                .font(.title3.weight(.semibold))
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.roundedRectangle(radius: 12))
                        .accessibilityLabel("扫码查询")
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
                    .listRowBackground(Color.clear)
                } footer: {
                    Text("仅本机采集记录。共 \(results.count) 条。")
                }
                if results.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "没有符合条件的记录",
                            systemImage: "clock.arrow.circlepath",
                            description: Text("可改筛选条件，或扫码按序列号查找。")
                        )
                        .listRowBackground(Color.clear)
                    }
                } else if bySerial {
                    Section("序列号") {
                        ForEach(serials, id: \.self) { serial in
                            NavigationLink {
                                SerialRecordsView(serial: serial)
                            } label: {
                                ProductIdentityRow(
                                    code: serial,
                                    productName: results.first { $0.codeValue == serial }?.productName,
                                    productModel: results.first { $0.codeValue == serial }?.productModel,
                                    caption: "\(results.filter { $0.codeValue == serial }.count) 次采集",
                                    thumbnail: thumbnail(for: results.first { $0.codeValue == serial }?.id),
                                    showsThumbnailSlot: true
                                )
                            }
                        }
                    }
                } else {
                    ForEach(dates, id: \.self) { day in
                        Section(day.formatted(date: .abbreviated, time: .omitted)) {
                            ForEach(results.filter { Calendar.current.isDate($0.scannedAt, inSameDayAs: day) }) { item in
                                NavigationLink { RecordReadOnlyView(capture: item) } label: {
                                    RecordSummaryRow(capture: item, thumbnail: thumbnail(for: item.id))
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("记录")
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $scannerPresented) {
                CodeScannerView { code in
                    search = code.trimmingCharacters(in: .whitespacesAndNewlines)
                    days = 0
                    bySerial = true
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
                    RecordReadOnlyView(capture: capture)
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
        List {
            Section("扫码记录") {
                LabeledContent("序列号", value: capture.codeValue)
                LabeledContent("产品", value: capture.productName ?? "尚未获取")
                LabeledContent("型号", value: capture.productModel ?? "尚未获取")
                LabeledContent("任务", value: drafts.first { $0.id == capture.draftID }?.title ?? "未知任务")
                LabeledContent("扫码时间", value: WallClock.dateTime(capture.scannedAt))
                LabeledContent("上传状态", value: uploaded ? "已上传" : "待上传")
            }
            Section("照片 \(media.filter { $0.mediaType == "image" }.count) / 录像 \(media.filter { $0.mediaType == "video" }.count)") {
                if media.isEmpty { Text("暂无媒体资源").foregroundStyle(.secondary) }
                ForEach(media) { item in
                    Button {
                        MediaFileStore.healStoredPaths(for: item)
                        preview = item
                    } label: {
                        HStack {
                            if let image = item.thumbnailImage {
                                Image(uiImage: image).resizable().scaledToFill()
                                    .frame(width: 56, height: 56).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                            } else { Image(systemName: item.mediaType == "video" ? "video" : "photo") }
                            Text(item.mediaType == "video" ? "查看录像" : "查看照片")
                        }
                    }
                }
            }
            Section("关联码") {
                if relatedScans.isEmpty {
                    Text("暂无关联码").foregroundStyle(.secondary)
                } else {
                    ForEach(relatedScans, id: \.id) { related in
                        NavigationLink {
                            RelatedScanCaptureView(relatedScanID: related.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(related.codeValue).font(.body.monospaced())
                                Text("\(related.kind.title) · \(WallClock.dateTime(related.createdAt))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section("内部备注记录") {
                if notes.isEmpty { Text("暂无备注").foregroundStyle(.secondary) }
                ForEach(notes) { note in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(note.text)
                        Label(WallClock.dateTime(note.createdAt), systemImage: "clock")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 5)
                }
            }
        }
        .navigationTitle("记录详情")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $preview) { MediaPreviewView(item: $0) }
    }
}
