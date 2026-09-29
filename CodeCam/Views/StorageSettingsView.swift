import SwiftData
import SwiftUI

struct StorageSettingsView: View {
    @Query(sort: \LocalMedia.capturedAt, order: .reverse) private var media: [LocalMedia]
    @Query(sort: \CaptureSession.scannedAt, order: .reverse) private var captures: [CaptureSession]
    private var pendingMediaCount: Int {
        media.filter { $0.syncState != .synced }.count
    }

    private var formattedTotal: String {
        ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .file)
    }

    private var estimatedBytes: Int64 {
        media.reduce(0) { partial, item in
            partial + fileSize(at: item.originalPath) + fileSize(at: item.thumbnailPath)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CodeCamStorageHero(
                    title: "本地采集数据",
                    value: formattedTotal,
                    subtitle: pendingMediaCount > 0 ? "\(pendingMediaCount) 项媒体待上传" : "可用空间充足"
                )

                CodeCamSectionHeader(title: "本地数据")
                CodeCamKeyValueList {
                    CodeCamKeyValueRow(label: "照片与录像", value: formattedTotal)
                    CodeCamKeyValueRow(label: "扫码记录", value: "\(captures.count) 条")
                    CodeCamKeyValueRow(label: "未上传媒体", value: "\(pendingMediaCount) 项")
                }

                CodeCamSectionHeader(title: "存储策略")
                CodeCamKeyValueList {
                    CodeCamKeyValueRow(label: "同步后保留", value: "30 天")
                    CodeCamKeyValueRow(label: "空间不足时", value: "自动清理已同步数据")
                }

                Text("具体保留策略由平台下发；本页仅展示本机占用概况。")
                    .font(.caption)
                    .foregroundStyle(CodeCamTheme.muted)
                    .padding(.horizontal, 2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .navigationTitle("数据与存储")
        .navigationBarTitleDisplayMode(.inline)
        .codeCamPage()
    }

    private func fileSize(at path: String?) -> Int64 {
        guard let path, !path.isEmpty else { return 0 }
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true else { return 0 }
        return Int64(values?.fileSize ?? 0)
    }
}
