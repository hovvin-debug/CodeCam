import SwiftData
import SwiftUI
import UIKit

struct RelatedScanCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allDrafts: [TaskDraft]
    @Query private var allCaptures: [CaptureSession]
    @Query private var allRelated: [RelatedScan]
    @Query private var allMedia: [LocalMedia]

    let relatedScanID: String
    @State private var captureMode: CaptureMode?
    @State private var previewMedia: LocalMedia?
    @State private var alert: AppAlert?
    @StateObject private var mediaLocation = MediaLocationService()

    private var related: RelatedScan? { allRelated.first { $0.id == relatedScanID } }
    private var capture: CaptureSession? {
        guard let parentID = related?.parentCaptureID else { return nil }
        return allCaptures.first { $0.id == parentID }
    }
    private var draft: TaskDraft? {
        allDrafts.first { $0.id == related?.draftID }
    }
    private var media: [LocalMedia] {
        allMedia.filter { $0.relatedScanID == relatedScanID }.sorted { $0.capturedAt < $1.capturedAt }
    }

    var body: some View {
        Group {
            if let related, let capture {
                content(related: related, capture: capture)
            } else {
                ContentUnavailableView("关联记录不存在", systemImage: "link", description: Text("该关联扫码可能已被清理。"))
            }
        }
        .navigationTitle("关联采集")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if related != nil, capture != nil {
                HStack(spacing: 8) {
                    BottomIconAction(title: "拍照", icon: "camera", disabled: !UIImagePickerController.isSourceTypeAvailable(.camera)) {
                        mediaLocation.prepareForMediaCapture()
                        captureMode = .photo
                    }
                    BottomIconAction(title: "录像", icon: "video", disabled: !UIImagePickerController.isSourceTypeAvailable(.camera)) {
                        mediaLocation.prepareForMediaCapture()
                        captureMode = .video
                    }
                    Button("完成") { dismiss() }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(.tint, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.bar)
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
        .sheet(item: $previewMedia) { MediaPreviewView(item: $0) }
        .alert(item: $alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("知道了")))
        }
    }

    @ViewBuilder
    private func content(related: RelatedScan, capture: CaptureSession) -> some View {
        List {
            Section("关联码") {
                LabeledContent("类型", value: related.kind.title)
                LabeledContent("编码", value: related.codeValue)
                LabeledContent("关联序列号", value: capture.codeValue)
                LabeledContent("扫码时间", value: WallClock.dateTime(related.createdAt))
            }
            Section("照片 \(media.filter { $0.mediaType == "image" }.count) / 录像 \(media.filter { $0.mediaType == "video" }.count)") {
                if media.isEmpty {
                    Text("可拍摄快递面单、外箱或其它现场照片。").foregroundStyle(.secondary)
                } else {
                    ForEach(media) { item in
                        Button {
                            previewMedia = item
                        } label: {
                            HStack {
                                MediaThumbnail(item: item, size: 56)
                                Text(item.mediaType == "video" ? "查看录像" : "查看照片")
                            }
                        }
                    }
                }
            }
        }
    }

    private func savePhoto(_ image: UIImage, location: MediaLocationSnapshot) {
        guard let related, let capture, let draft else { return }
        do { try TaskDraftService.addRelatedPhoto(image, location: location, to: related, capture: capture, draft: draft, in: modelContext) }
        catch { alert = AppAlert(title: "图片未保存", message: error.localizedDescription) }
    }

    private func saveVideo(_ fileURL: URL, location: MediaLocationSnapshot) {
        guard let related, let capture, let draft else { return }
        do { try TaskDraftService.addRelatedVideo(at: fileURL, location: location, to: related, capture: capture, draft: draft, in: modelContext) }
        catch { alert = AppAlert(title: "录像未保存", message: error.localizedDescription) }
    }
}
