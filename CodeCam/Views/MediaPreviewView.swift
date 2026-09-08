import QuickLook
import SwiftUI
import UIKit

struct MediaThumbnail: View {
    let item: LocalMedia
    var size: CGFloat = 78

    var body: some View {
        Group {
            if let image = item.thumbnailImage {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: item.mediaType == "video" ? "video" : "photo")
                    .font(.title2).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            if item.mediaType == "video" {
                Image(systemName: "play.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.5), in: Circle())
            }
        }
        .accessibilityHidden(true)
    }
}

struct MediaPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let item: LocalMedia

    private var previewURL: URL? {
        if let original = item.resolvedOriginalURL { return original }
        // Absolute-path records may still have a reachable thumbnail after container moves.
        return item.resolvedThumbnailURL
    }

    var body: some View {
        NavigationStack {
            Group {
                if let previewURL {
                    LocalMediaPreview(url: previewURL)
                } else {
                    ContentUnavailableView(
                        "媒体暂时无法预览",
                        systemImage: "photo.badge.exclamationmark",
                        description: Text("本地原文件不存在。若刚重装或清空过 App，需重新拍照；已同步到平台的内容请在平台查看。")
                    )
                }
            }
            .navigationTitle(item.mediaType == "video" ? "录像预览" : "照片预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear { MediaFileStore.healStoredPaths(for: item) }
        }
    }
}

// 系统预览支持照片缩放与录像播放，直接读取原文件。
private struct LocalMediaPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }
    }
}
