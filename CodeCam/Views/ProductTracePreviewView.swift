import SwiftData
import SwiftUI
import UIKit

struct ProductTracePreviewView: View {
    @Query private var allCaptures: [CaptureSession]
    @Query private var allDrafts: [TaskDraft]
    @Query private var allMedia: [LocalMedia]
    @Query private var allNotes: [CaptureNote]
    @Query private var executionItems: [ExecutionItem]

    let captureID: String
    let draftID: String

    @State private var profile = ProductProfile.pending(for: "", message: "正在从平台拉取追溯信息。")
    @State private var shareMessage: String?
    @State private var shareURL: URL?
    @State private var preview: LocalMedia?

    private var capture: CaptureSession? { allCaptures.first { $0.id == captureID } }
    private var draft: TaskDraft? { allDrafts.first { $0.id == draftID } }
    private var media: [LocalMedia] {
        allMedia.filter { $0.captureID == captureID && !$0.isRelatedMedia }.sorted { $0.capturedAt < $1.capturedAt }
    }
    private var notes: [CaptureNote] {
        allNotes.filter { $0.captureID == captureID }.sorted { $0.createdAt > $1.createdAt }
    }
    private var executionItem: ExecutionItem? { executionItems.first { $0.id == capture?.executionItemID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("产品身份")
                        .font(CodeCamTypography.listMeta)
                        .foregroundStyle(CodeCamTheme.muted)
                    Text(profile.productName ?? profile.productReference)
                        .font(CodeCamTypography.hero)
                    Text("\(profile.productModel ?? capture?.productModel ?? "-") · 标准配置")
                        .font(CodeCamTypography.cardSubtitle)
                        .foregroundStyle(CodeCamTheme.muted)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("产品序列号")
                            .font(CodeCamTypography.listMeta)
                            .foregroundStyle(CodeCamTheme.muted)
                        Text(capture?.codeValue ?? profile.serialNumber)
                            .font(CodeCamTypography.scanCode)
                    }
                    .padding(.top, 8)
                }
                .padding(17)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(colors: [CodeCamTheme.syncBannerFill, .white], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(CodeCamTheme.accentBorder, lineWidth: 1)
                }

                CodeCamSectionHeader(title: "当前进度", trailing: progressLabel)
                VStack(alignment: .leading, spacing: 10) {
                    CodeCamProgressLine(progress: 0.45)
                    HStack {
                        Text("已下达").font(CodeCamTypography.listMeta).foregroundStyle(CodeCamTheme.green)
                        Spacer()
                        Text(progressLabel).font(CodeCamTypography.listMeta).foregroundStyle(CodeCamTheme.blue)
                        Spacer()
                        Text("生产完成").font(CodeCamTypography.listMeta).foregroundStyle(CodeCamTheme.muted)
                        Spacer()
                        Text("已发货").font(CodeCamTypography.listMeta).foregroundStyle(CodeCamTheme.muted)
                    }
                    Text("更新于 \(WallClock.dateTime(capture?.scannedAt ?? .now))")
                        .font(CodeCamTypography.listMeta)
                        .foregroundStyle(CodeCamTheme.muted)
                }
                .padding(14)
                .codeCamCard()

                CodeCamSectionHeader(title: "过程记录")
                VStack(alignment: .leading, spacing: 8) {
                    Text("现场扫码记录")
                        .font(CodeCamTypography.listTitle)
                    Text("已完成 · \(WallClock.dateTime(capture?.scannedAt ?? .now))")
                        .font(CodeCamTypography.listMeta)
                        .foregroundStyle(CodeCamTheme.muted)
                    if let note = notes.first {
                        Text(note.text)
                            .font(CodeCamTypography.note)
                            .foregroundStyle(CodeCamTheme.ink)
                    } else {
                        Text("已完成本次现场记录。")
                            .font(CodeCamTypography.note)
                    }
                    if !media.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(media) { item in
                                    Button { preview = item } label: {
                                        MediaThumbnail(item: item, size: 72)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(14)
                .codeCamCard()

                Text("本页仅展示平台授权的追溯信息。")
                    .font(CodeCamTypography.listMeta)
                    .foregroundStyle(CodeCamTheme.muted)
                    .padding(.horizontal, 2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .navigationTitle("产品追溯预览")
        .navigationBarTitleDisplayMode(.inline)
        .codeCamPage()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("分享") { Task { await shareTrace() } }
            }
        }
        .task {
            if let capture {
                profile = await ProductProfileService.fetch(code: capture.codeValue)
            }
        }
        .sheet(item: $preview) { MediaPreviewView(item: $0) }
        .alert("产品追溯", isPresented: Binding(get: { shareMessage != nil }, set: { if !$0 { shareMessage = nil } })) {
            Button("知道了", role: .cancel) { shareMessage = nil }
        } message: {
            Text(shareMessage ?? "")
        }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let shareURL {
                ShareSheet(items: [shareURL])
            }
        }
    }

    private var progressLabel: String {
        let status = profile.status
        if status.isEmpty || status == "待校验" { return executionItem?.state.title ?? "生产中" }
        return status
    }

    @MainActor
    private func shareTrace() async {
        guard let code = capture?.codeValue else { return }
        do {
            let object = try await EdgeFlowClient.post(
                "/api/terminal/v1/trace-shares",
                body: ["codeValue": code, "terminalId": InstallationIDStore.value]
            )
            if let link = object["url"] as? String ?? object["shareUrl"] as? String, let url = URL(string: link) {
                shareURL = url
            } else {
                shareMessage = "授权追溯链接需由平台生成，当前未返回可用链接。"
            }
        } catch {
            shareMessage = "分享时由平台生成授权追溯链接，当前无法获取。请稍后重试。不要使用 SN 作为访问凭证。"
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
