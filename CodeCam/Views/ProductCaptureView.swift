import SwiftData
import SwiftUI
import UIKit

struct ProductCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allDrafts: [TaskDraft]
    @Query private var allCaptures: [CaptureSession]
    @Query private var allMedia: [LocalMedia]
    @Query private var allNotes: [CaptureNote]
    @Query private var allRelated: [RelatedScan]
    @Query private var allEvents: [LocalEvent]
    @Query private var executionItems: [ExecutionItem]

    let captureID: String
    let draftID: String
    let isHistory: Bool
    @State private var profile = ProductProfile.pending(for: "", message: "正在从平台拉取产品资料。")
    @State private var captureMode: CaptureMode?
    @State private var previewMedia: LocalMedia?
    @State private var remarksPresented = false
    @State private var emptyCaptureConfirmationPresented = false
    @State private var relatedFlowPresented = false
    @State private var relatedDestination: RelatedScanRoute?
    @State private var remark = ""
    @State private var alert: AppAlert?
    @StateObject private var mediaLocation = MediaLocationService()

    private var capture: CaptureSession? { allCaptures.first { $0.id == captureID } }
    private var draft: TaskDraft? { allDrafts.first { $0.id == draftID } }
    private var media: [LocalMedia] {
        allMedia.filter { $0.captureID == captureID && !$0.isRelatedMedia }.sorted { $0.capturedAt < $1.capturedAt }
    }
    private var notes: [CaptureNote] { allNotes.filter { $0.captureID == captureID }.sorted { $0.createdAt > $1.createdAt } }
    private var relatedScans: [RelatedScan] {
        allRelated.filter { $0.parentCaptureID == captureID }.sorted { $0.createdAt < $1.createdAt }
    }
    private var captureIsReadOnly: Bool { isHistory || capture?.isCompleted == true }
    private var photoCount: Int { media.filter { $0.mediaType == "image" }.count }
    private var videoCount: Int { media.filter { $0.mediaType == "video" }.count }
    private var executionItem: ExecutionItem? { executionItems.first { $0.id == capture?.executionItemID } }
    private var timelineEvents: [LocalEvent] {
        allEvents.filter { $0.captureID == captureID }.sorted { $0.occurredAt > $1.occurredAt }
    }

    var body: some View {
        Group {
            if let capture, let draft {
                captureContent(capture: capture, draft: draft)
            } else {
                ContentUnavailableView("扫码记录不存在", systemImage: "exclamationmark.triangle", description: Text("该记录可能已被清理。"))
            }
        }
        .navigationTitle(draft?.title ?? (isHistory ? "扫码记录" : "出厂质检留档"))
        .navigationBarTitleDisplayMode(.inline)
        .codeCamPage()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink("产品追溯") {
                    ProductTracePreviewView(captureID: captureID, draftID: draftID)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let capture, let draft {
                actionBar(capture: capture, draft: draft)
            }
        }
        .sheet(item: $captureMode) { mode in
            CameraCaptureView(mode: mode) { image in
                let location = mediaLocation.snapshot()
                mediaLocation.stop()
                captureMode = nil
                savePhoto(image, location: location)
            } onVideo: { videoURL in
                let location = mediaLocation.snapshot()
                mediaLocation.stop()
                captureMode = nil
                saveVideo(videoURL, location: location)
            } onCancel: {
                mediaLocation.stop()
                captureMode = nil
            }
        }
        .sheet(isPresented: $remarksPresented) { noteEditor }
        .sheet(isPresented: $relatedFlowPresented) {
            RelatedScanFlowView { kind, code in
                relatedFlowPresented = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    attachRelatedScan(code, kind: kind)
                }
            } onCancel: {
                relatedFlowPresented = false
            }
        }
        .navigationDestination(item: $relatedDestination) { route in
            RelatedScanCaptureView(relatedScanID: route.id)
        }
        .sheet(item: $previewMedia) { item in
            MediaPreviewView(item: item)
        }
        .task(id: capture?.codeValue) {
            if let capture {
                profile = await ProductProfileService.fetch(code: capture.codeValue)
                if capture.productName == nil { capture.productName = profile.productName ?? executionItem?.productName }
                if capture.productModel == nil { capture.productModel = profile.productModel ?? executionItem?.productModel }
                do { try modelContext.save() }
                catch { alert = AppAlert(title: "产品资料未保存", message: error.localizedDescription) }
                if !isHistory {
                    presentProfileFetchFeedback()
                }
            }
        }
        .alert(item: $alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("知道了")))
        }
    }

    @ViewBuilder
    private func captureContent(capture: CaptureSession, draft: TaskDraft) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CodeCamDetailHero(
                    tag: profile.status.isEmpty ? "产品码已验证" : profile.status,
                    tagStyle: .mint,
                    title: profile.serialNumber.isEmpty ? capture.codeValue : profile.serialNumber,
                    subtitle: "任务 · \(draft.title)"
                )

                CodeCamSectionHeader(title: "产品信息")
                CodeCamProductInfoCard(
                    productName: profile.productName ?? profile.productReference,
                    rows: productInfoRows(for: capture)
                )

                CodeCamSectionHeader(title: "本次扫码", trailing: "照片 \(photoCount) / 录像 \(videoCount)")
                captureMediaGrid
                mediaStatusLine

                relatedCodeSection

                CodeCamSectionHeader(
                    title: "备注",
                    actionTitle: "添加",
                    action: {
                        remark = ""
                        remarksPresented = true
                    }
                )
                if notes.isEmpty {
                    CodeCamNoteCard(bodyText: "尚无备注。新增的每条备注都会单独保留记录时间。")
                } else {
                    ForEach(notes) { note in
                        CodeCamNoteCard(timeCaption: WallClock.time(note.createdAt), bodyText: note.text)
                    }
                }

                CodeCamSectionHeader(title: "SN 时间线")
                VStack(spacing: 0) {
                    ForEach(Array(timelineEvents.enumerated()), id: \.element.eventID) { index, event in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: timelineIcon(for: event.kind))
                                .foregroundStyle(CodeCamTheme.blue)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(timelineTitle(for: event.kind))
                                    .font(CodeCamTypography.listTitle)
                                Text(WallClock.dateTime(event.occurredAt))
                                    .font(CodeCamTypography.listMeta)
                                    .foregroundStyle(CodeCamTheme.muted)
                            }
                            Spacer()
                        }
                        .padding(12)
                        if index < timelineEvents.count - 1 { CodeCamListDivider() }
                    }
                }
                .codeCamListCard()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .padding(.bottom, 72)
        }
    }

    private func productInfoRows(for capture: CaptureSession) -> [(label: String, value: String)] {
        let spec = profile.fields.first { $0.name.contains("规格") }?.value
            ?? profile.fields.first { $0.name.lowercased() == "spec" }?.value
            ?? "标准配置"
        let remarkValue = profile.fields.first { $0.name.contains("备注") }?.value ?? "-"
        return [
            ("型号", profile.productModel ?? capture.productModel ?? profile.productReference),
            ("规格", spec),
            ("备注", remarkValue)
        ]
    }

    @ViewBuilder
    private var relatedCodeSection: some View {
        if relatedScans.isEmpty {
            Button {
                guard !captureIsReadOnly else { return }
                relatedFlowPresented = true
            } label: {
                HStack {
                    Text("关联码").font(CodeCamTypography.listMeta).foregroundStyle(CodeCamTheme.muted)
                    Spacer()
                    Text(captureIsReadOnly ? "无" : "添加")
                        .font(CodeCamTypography.listTitle)
                    Image(systemName: "chevron.right").foregroundStyle(CodeCamTheme.muted)
                }
                .padding(12)
                .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(CodeCamTheme.line, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .disabled(captureIsReadOnly)
        } else {
            VStack(spacing: 0) {
                ForEach(relatedScans, id: \.id) { related in
                    NavigationLink {
                        RelatedScanCaptureView(relatedScanID: related.id)
                    } label: {
                        HStack {
                            Text("关联码").font(CodeCamTypography.listMeta).foregroundStyle(CodeCamTheme.muted)
                            Text(related.codeValue).font(.subheadline.monospaced())
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
    }

    @ViewBuilder
    private var captureMediaGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(media) { item in
                Button { previewMedia = item } label: {
                    MediaThumbnail(item: item, size: 76)
                }
                .buttonStyle(.plain)
            }
            if !captureIsReadOnly {
                Button { beginMediaCapture(.photo) } label: {
                    Text("＋")
                        .font(.title2)
                        .foregroundStyle(CodeCamTheme.blue)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                        .background(Color(red: 247 / 255, green: 249 / 255, blue: 251 / 255), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(style: StrokeStyle(lineWidth: 1, dash: [4]))
                                .foregroundStyle(Color(red: 182 / 255, green: 195 / 255, blue: 210 / 255))
                        }
                }
                .buttonStyle(.plain)
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            }
        }
    }

    private var mediaStatusLine: some View {
        HStack {
            Text(gpsStatusText)
                .font(.caption)
                .foregroundStyle(CodeCamTheme.green)
            Spacer()
            let pending = media.filter { $0.syncState != .synced }.count
            Text(pending > 0 ? "\(pending) 项媒体待上传" : "媒体已就绪")
                .font(CodeCamTypography.listMeta)
                .foregroundStyle(CodeCamTheme.muted)
        }
        .padding(.horizontal, 2)
    }

    private var gpsStatusText: String {
        if let accuracy = media.compactMap(\.horizontalAccuracy).last {
            return "GPS 已记录 · 精度 \(Int(accuracy.rounded()))m"
        }
        return "GPS 待记录"
    }

    private func presentProfileFetchFeedback() {
        let fromPlatform = profile.sourceDescription.contains("EdgeFlow")
        if fromPlatform { return }
        let hasCache = (profile.productName ?? executionItem?.productName) != nil
            || (profile.productModel ?? executionItem?.productModel) != nil
        if hasCache {
            alert = AppAlert(title: "当前离线", message: "当前离线，已使用本地缓存产品信息。")
        } else {
            alert = AppAlert(title: "产品信息失败", message: "产品信息暂时无法获取，请重试或稍后同步。")
        }
    }

    @ViewBuilder
    private func actionBar(capture: CaptureSession, draft: TaskDraft) -> some View {
        if captureIsReadOnly {
            EmptyView()
        } else {
            CodeCamBottomActionBar(
                secondaryTitles: ["拍照", "录像"],
                primaryTitle: "完成",
                onSecondary: { index in
                    guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
                    beginMediaCapture(index == 0 ? .photo : .video)
                },
                onPrimary: {
                    if media.isEmpty && notes.isEmpty && relatedScans.isEmpty {
                        emptyCaptureConfirmationPresented = true
                    } else {
                        finishCapture(capture, draft: draft)
                    }
                }
            )
            .alert("还没有相应记录，确认结束本次扫码吗？", isPresented: $emptyCaptureConfirmationPresented) {
                Button("否", role: .cancel) { }
                Button("是") { finishCapture(capture, draft: draft) }
            }
        }
    }

    private var noteEditor: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("现场备注")
                    .font(.subheadline)
                    .foregroundStyle(CodeCamTheme.muted)
                TextEditor(text: $remark)
                    .frame(minHeight: 150)
                    .padding(10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(CodeCamTheme.line, lineWidth: 1)
                    }
                Spacer(minLength: 0)
                HStack {
                    Button("取消") { remarksPresented = false }
                        .foregroundStyle(CodeCamTheme.muted)
                    Spacer()
                    Button("保存") { saveRemark() }
                        .fontWeight(.bold)
                        .disabled(remark.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.top, 8)
            }
            .padding()
            .navigationTitle("录入备注")
            .navigationBarTitleDisplayMode(.inline)
            .codeCamPage()
        }
        .presentationDetents([.medium])
    }

    private func attachRelatedScan(_ scannedValue: String, kind: RelatedScanKind) {
        guard let capture, let draft else { return }
        do {
            switch try PlatformPortalQRCodeRouter.route(scannedValue: scannedValue, platformBaseURL: EdgeFlowClient.baseURL) {
            case .productCode(let code):
                let related = try TaskDraftService.addRelatedScan(code, kind: kind, to: capture, draft: draft, in: modelContext)
                relatedDestination = RelatedScanRoute(id: related.id)
            case .platformPortal, .loginChallenge:
                alert = AppAlert(title: "无法关联", message: "请扫描物流单或其它现场编码，而不是平台入口二维码。")
            }
        } catch {
            alert = AppAlert(title: "无法关联扫码", message: error.localizedDescription)
        }
    }

    private func beginMediaCapture(_ mode: CaptureMode) {
        mediaLocation.prepareForMediaCapture()
        captureMode = mode
    }

    private func savePhoto(_ image: UIImage, location: MediaLocationSnapshot) {
        guard let capture, let draft else { return }
        do { try TaskDraftService.addPhoto(image, category: nextEvidenceCategory, location: location, to: capture, draft: draft, in: modelContext) }
        catch { alert = AppAlert(title: "图片未保存", message: error.localizedDescription) }
    }

    private func saveVideo(_ fileURL: URL, location: MediaLocationSnapshot) {
        guard let capture, let draft else { return }
        do { try TaskDraftService.addVideo(at: fileURL, category: nextEvidenceCategory, location: location, to: capture, draft: draft, in: modelContext) }
        catch { alert = AppAlert(title: "录像未保存", message: error.localizedDescription) }
    }

    private var nextEvidenceCategory: String {
        guard let executionItem else { return "现场图片" }
        for requirement in executionItem.requiredEvidence {
            if media.filter({ $0.category == requirement.label }).count < requirement.minimum { return requirement.label }
        }
        return executionItem.requiredEvidence.first?.label ?? "现场图片"
    }

    private func saveRemark() {
        guard let capture, let draft else { return }
        do {
            try TaskDraftService.addNote(remark, to: capture, draft: draft, in: modelContext)
            remarksPresented = false
        } catch {
            alert = AppAlert(title: "备注未保存", message: error.localizedDescription)
        }
    }

    private func finishCapture(_ capture: CaptureSession, draft: TaskDraft) {
        do {
            try TaskDraftService.completeCapture(capture, for: draft, in: modelContext)
            dismiss()
        } catch {
            alert = AppAlert(title: "无法完成扫码", message: error.localizedDescription)
        }
    }

    private func timelineTitle(for kind: String) -> String {
        switch kind {
        case "code.scanned": "已扫描 SN"
        case "media.captured": "已添加照片"
        case "media.recorded": "已添加录像"
        case "note.added": "已添加备注"
        case "related.scanned": "已添加关联码"
        case "capture.completed": "任务已完成"
        default: "记录已更新"
        }
    }

    private func timelineIcon(for kind: String) -> String {
        switch kind {
        case "code.scanned": "barcode.viewfinder"
        case "media.captured": "camera.fill"
        case "media.recorded": "video.fill"
        case "note.added": "text.bubble.fill"
        case "capture.completed": "checkmark.circle.fill"
        default: "circle.fill"
        }
    }
}

private struct MediaCountBadge: View {
    let title: String
    let count: Int
    let icon: String

    var body: some View {
        Label("\(title) \(count)", systemImage: icon)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary, in: Capsule())
    }
}

private struct NoteRecordCard: View {
    let note: CaptureNote

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "text.bubble.fill")
                .font(.subheadline)
                .foregroundStyle(.blue)
                .frame(width: 24, height: 24)
                .background(.blue.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 8) {
                Text(note.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Label(WallClock.dateTime(note.createdAt), systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct BottomIconAction: View {
    let title: String
    let icon: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                Text(title)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? .tertiary : .primary)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .disabled(disabled)
    }
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct RelatedScanRoute: Identifiable, Hashable {
    let id: String
}

private struct RelatedScanFlowView: View {
    let onComplete: (RelatedScanKind, String) -> Void
    let onCancel: () -> Void
    @State private var kind: RelatedScanKind?

    var body: some View {
        if let kind {
            CodeScannerView(
                onScan: { onComplete(kind, $0) },
                onCancel: onCancel,
                title: "扫描关联码",
                lockToCenter: false
            )
        } else {
            NavigationStack {
                List {
                    Section {
                        Button("物流快递") { kind = .logistics }
                        Button("其它") { kind = .other }
                    } footer: {
                        Text("先选择类型，再扫描需要与当前序列号关联的编码。")
                    }
                }
                .navigationTitle("关联扫码")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消", action: onCancel)
                    }
                }
            }
        }
    }
}
