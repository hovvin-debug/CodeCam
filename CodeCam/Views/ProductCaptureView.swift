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

    var body: some View {
        Group {
            if let capture, let draft {
                captureContent(capture: capture, draft: draft)
            } else {
                ContentUnavailableView("扫码记录不存在", systemImage: "exclamationmark.triangle", description: Text("该记录可能已被清理。"))
            }
        }
        .navigationTitle(isHistory ? "扫码记录" : "产品采集")
        .navigationBarTitleDisplayMode(.inline)
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
                if capture.productName == nil { capture.productName = profile.productName }
                if capture.productModel == nil { capture.productModel = profile.productModel }
                do { try modelContext.save() }
                catch { alert = AppAlert(title: "产品资料未保存", message: error.localizedDescription) }
            }
        }
        .alert(item: $alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("知道了")))
        }
    }

    @ViewBuilder
    private func captureContent(capture: CaptureSession, draft: TaskDraft) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("序列号").font(.subheadline).foregroundStyle(.secondary)
                    Text(profile.serialNumber.isEmpty ? capture.codeValue : profile.serialNumber)
                        .font(.title2.monospaced().weight(.semibold))
                    HStack {
                        Text(profile.status)
                        Spacer()
                        Text(profile.sourceDescription)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))

                GroupBox("产品信息") {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent("产品", value: profile.productReference)
                        LabeledContent("任务", value: draft.title)
                        LabeledContent("扫码时间", value: WallClock.dateTime(capture.scannedAt))
                        if profile.fields.isEmpty {
                            Text("产品字段将在平台校验成功后显示。")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            ForEach(profile.fields) { field in LabeledContent(field.name, value: field.value) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 10) {
                            MediaCountBadge(title: "照片", count: photoCount, icon: "photo")
                            MediaCountBadge(title: "录像", count: videoCount, icon: "video")
                        }
                        if media.isEmpty {
                            Text("暂无媒体资源")
                                .font(.footnote).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 10) {
                                ForEach(media) { item in
                                    Button {
                                        previewMedia = item
                                    } label: {
                                        MediaThumbnail(item: item)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("预览\(item.mediaType == "video" ? "录像" : "照片")，\(WallClock.dateTime(item.capturedAt))")
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                GroupBox("关联码") {
                    if relatedScans.isEmpty {
                        Text("可在「更多」中关联物流快递或其它编码，并继续拍照。")
                            .font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(relatedScans, id: \.id) { related in
                                NavigationLink {
                                    RelatedScanCaptureView(relatedScanID: related.id)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(related.codeValue).font(.body.monospaced())
                                            Text("\(related.kind.title) · \(WallClock.dateTime(related.createdAt))")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        let relatedMedia = allMedia.filter { $0.relatedScanID == related.id }
                                        Text("\(relatedMedia.count)")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                GroupBox("备注记录") {
                    if notes.isEmpty {
                        Text("尚无备注。新增的每条备注都会单独保留记录时间。")
                            .font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(notes) { note in
                                NoteRecordCard(note: note)
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func actionBar(capture: CaptureSession, draft: TaskDraft) -> some View {
        HStack(spacing: 8) {
            if !captureIsReadOnly {
                BottomIconAction(title: "拍照", icon: "camera", disabled: !UIImagePickerController.isSourceTypeAvailable(.camera)) {
                    beginMediaCapture(.photo)
                }
                BottomIconAction(title: "录像", icon: "video", disabled: !UIImagePickerController.isSourceTypeAvailable(.camera)) {
                    beginMediaCapture(.video)
                }
            }
            moreMenu
            if !captureIsReadOnly {
                Button("完成") {
                    if media.isEmpty && notes.isEmpty && relatedScans.isEmpty {
                        emptyCaptureConfirmationPresented = true
                    } else {
                        finishCapture(capture, draft: draft)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(.tint, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white)
                .alert("还没有相应记录，确认结束本次扫码吗？", isPresented: $emptyCaptureConfirmationPresented) {
                    Button("否", role: .cancel) { }
                    Button("是") { finishCapture(capture, draft: draft) }
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var moreMenu: some View {
        Menu {
            Button("关联扫码", systemImage: "link") {
                relatedFlowPresented = true
            }
            Button("备注", systemImage: "text.bubble") {
                remark = ""
                remarksPresented = true
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "ellipsis.circle")
                    .font(.body.weight(.semibold))
                Text("更多")
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(.primary)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        }
        .accessibilityLabel("更多")
    }

    private var noteEditor: some View {
        NavigationStack {
            Form {
                Section("新增备注") { TextEditor(text: $remark).frame(minHeight: 180) }
            }
            .navigationTitle("录入备注")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button("取消") { remarksPresented = false }
                        .buttonStyle(.bordered)
                    Button("保存备注") { saveRemark() }
                        .buttonStyle(.borderedProminent)
                        .disabled(remark.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
    }

    private func attachRelatedScan(_ scannedValue: String, kind: RelatedScanKind) {
        guard let capture, let draft else { return }
        do {
            switch try PlatformPortalQRCodeRouter.route(scannedValue: scannedValue, platformBaseURL: EdgeFlowClient.baseURL) {
            case .productCode(let code):
                let related = try TaskDraftService.addRelatedScan(code, kind: kind, to: capture, draft: draft, in: modelContext)
                relatedDestination = RelatedScanRoute(id: related.id)
            case .platformPortal:
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
        do { try TaskDraftService.addPhoto(image, category: "现场图片", location: location, to: capture, draft: draft, in: modelContext) }
        catch { alert = AppAlert(title: "图片未保存", message: error.localizedDescription) }
    }

    private func saveVideo(_ fileURL: URL, location: MediaLocationSnapshot) {
        guard let capture, let draft else { return }
        do { try TaskDraftService.addVideo(at: fileURL, category: "现场录像", location: location, to: capture, draft: draft, in: modelContext) }
        catch { alert = AppAlert(title: "录像未保存", message: error.localizedDescription) }
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
            alert = AppAlert(title: "无法完成采集", message: error.localizedDescription)
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
