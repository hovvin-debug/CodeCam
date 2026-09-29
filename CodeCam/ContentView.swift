import SwiftData
import SwiftUI
import UIKit

private enum CaptureRoute: Hashable {
    case taskInfo
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TaskDraft.updatedAt, order: .reverse) private var drafts: [TaskDraft]
    @Query(sort: \CaptureSession.scannedAt, order: .reverse) private var captures: [CaptureSession]
    @Query(sort: \LocalMedia.capturedAt, order: .reverse) private var media: [LocalMedia]
    @Query(sort: \ExecutionList.updatedAt, order: .reverse) private var executionLists: [ExecutionList]
    @Query private var executionItems: [ExecutionItem]
    @Query private var registrations: [DeviceRegistration]
    @Binding var targetExecutionItemID: String?
    var onOpenRecords: () -> Void = {}

    @State private var selectedTaskID: String?
    @State private var capturePath = NavigationPath()
    @State private var scannerPresented = false
    @State private var pendingScannedValue: String?
    @State private var scanDestination: ScannedCode?
    @State private var portalSession: PlatformPortalSession?
    @State private var portalOpening = false
    @State private var alert: AppAlert?

    private var todayExecutionList: ExecutionList? {
        let today = ExecutionListService.todayKey()
        return executionLists.first { $0.workDateKey == today }
    }

    private var todayExecutionItems: [ExecutionItem] {
        guard let todayExecutionList else { return [] }
        return executionItems.filter { $0.listID == todayExecutionList.id }
    }

    private var outstandingCount: Int {
        todayExecutionItems.filter(\.state.isOutstanding).count
    }

    private var completedCount: Int {
        todayExecutionItems.filter { $0.state == .synced || $0.state == .skipped }.count
    }

    private var queuedCount: Int {
        todayExecutionItems.filter { $0.state == .captured }.count
    }

    private var registration: DeviceRegistration? {
        registrations.first { $0.terminalID == InstallationIDStore.value }
    }

    private var isStationOnline: Bool {
        guard let registration else { return false }
        switch registration.state {
        case .online, .registered: return true
        default: return false
        }
    }

    private var todayRecentScans: [TodayScan] {
        Array(
            captures
                .filter { Calendar.current.isDateInToday($0.scannedAt) }
                .prefix(5)
                .compactMap { capture in
                    guard let draft = drafts.first(where: { $0.id == capture.draftID }) else { return nil }
                    return TodayScan(
                        captureID: capture.id,
                        draftID: draft.id,
                        code: capture.codeValue,
                        productName: capture.productName,
                        productModel: capture.productModel,
                        scannedAt: capture.scannedAt,
                        thumbnail: media.first(where: { $0.captureID == capture.id })?.thumbnailImage
                    )
                }
        )
    }

    var body: some View {
        NavigationStack(path: $capturePath) {
            captureList
                .navigationTitle("扫码")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        CodeCamOnlineStatus(title: isStationOnline ? "在线" : "离线", isOnline: isStationOnline)
                    }
                }
                .navigationDestination(for: CaptureRoute.self) { route in
                    switch route {
                    case .taskInfo:
                        StationTaskInfoView()
                    }
                }
                .task {
                    selectPreferredTaskIfNeeded()
                    await refreshTodayListIfNeeded()
                }
                .onChange(of: drafts.count) { _, _ in
                    selectPreferredTaskIfNeeded()
                }
                .onChange(of: selectedTaskID) { _, value in
                    if let value { UserDefaults.standard.set(value, forKey: "codecam.preferred-task-id") }
                }
                .onChange(of: targetExecutionItemID) { _, targetID in
                    guard targetID != nil else { return }
                    selectTargetTaskAndOpenScanner()
                }
                .onAppear {
                    if targetExecutionItemID != nil { selectTargetTaskAndOpenScanner() }
                }
                .sheet(isPresented: $scannerPresented, onDismiss: consumePendingScan) {
                    CodeScannerView { scannedValue in
                        pendingScannedValue = scannedValue
                        scannerPresented = false
                    } onCancel: {
                        pendingScannedValue = nil
                        scannerPresented = false
                    }
                }
                .sheet(item: $portalSession) { session in
                    PlatformPortalBrowserView(session: session)
                }
                .navigationDestination(item: $scanDestination) { scan in
                    ProductCaptureView(captureID: scan.captureID, draftID: scan.draftID, isHistory: scan.isHistory)
                }
                .alert(item: $alert) { alert in
                    Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("知道了")))
                }
                .overlay {
                    if portalOpening {
                        ProgressView("正在验证访问权限…")
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
        }
    }

    private var captureList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let draft = assignedDraft {
                    NavigationLink(value: CaptureRoute.taskInfo) {
                        CodeCamCompactTaskBar(taskTitle: draft.title)
                    }
                    .buttonStyle(.plain)
                } else {
                    ContentUnavailableView(
                        "还不能扫码",
                        systemImage: "barcode.viewfinder",
                        description: Text("先到「任务」点击「添加扫码任务」，扫描客户现有 SN。")
                    )
                    .frame(maxWidth: .infinity)
                    .codeCamCard()
                }

                CodeCamPrimaryButton(
                    title: "扫描产品码",
                    subtitle: "支持扫码、相册识别与手动录入",
                    icon: "barcode.viewfinder"
                ) { scannerPresented = true }
                .disabled(assignedDraft == nil)
                .opacity(assignedDraft == nil ? 0.45 : 1)

                CodeCamOfflineCaptureStatus()

                CodeCamSectionHeader(title: "最近扫码", actionTitle: "全部记录", action: onOpenRecords)
                if todayRecentScans.isEmpty {
                    Text("今天还没有扫码记录")
                        .font(.subheadline).foregroundStyle(CodeCamTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .codeCamCard()
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(todayRecentScans.enumerated()), id: \.element.id) { index, scan in
                            Button {
                                scanDestination = ScannedCode(captureID: scan.captureID, draftID: scan.draftID, isHistory: true)
                            } label: {
                                CodeCamScanRow(
                                    serial: scan.code,
                                    productName: scan.productName,
                                    productModel: scan.productModel,
                                    stateTitle: scanStateTitle(scan),
                                    timeCaption: WallClock.time(scan.scannedAt),
                                    palette: CodeCamScanThumbPalette.forIndex(index),
                                    thumbnail: scan.thumbnail
                                )
                            }
                            .buttonStyle(.plain)
                            if index < todayRecentScans.count - 1 { CodeCamListDivider() }
                        }
                    }
                    .codeCamListCard()
                }
                Text(scanFooter).font(.caption).foregroundStyle(CodeCamTheme.muted)
                    .padding(.horizontal, 2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .codeCamPage()
    }

    private var assignedDraft: TaskDraft? { drafts.first }

    private func scanStateTitle(_ scan: TodayScan) -> String {
        guard let capture = captures.first(where: { $0.id == scan.captureID }) else { return "已扫码" }
        let relatedMedia = media.filter { $0.captureID == capture.id }
        let pending = relatedMedia.contains { $0.syncState != .synced } || !capture.isCompleted
        if pending && capture.isCompleted { return "待上传" }
        if capture.isCompleted { return "已完成" }
        return "已扫码"
    }

    private var scanFooter: String {
        if assignedDraft == nil {
            return "先添加一个 SN 扫码任务。"
        }
        if todayExecutionList == nil {
            return "先到「任务」添加客户现有 SN。"
        }
        if outstandingCount > 0 {
            return "今日还有 \(outstandingCount) 项待扫码，完整清单在「任务」。"
        }
        return "今日任务已完成；可继续添加新的 SN 扫码任务。"
    }

    private func consumePendingScan() {
        guard let scannedValue = pendingScannedValue else { return }
        pendingScannedValue = nil
        handleScannedValue(scannedValue)
    }

    private func handleScannedValue(_ scannedValue: String) {
        do {
            switch try PlatformPortalQRCodeRouter.route(scannedValue: scannedValue, platformBaseURL: EdgeFlowClient.baseURL) {
            case .productCode(let code):
                saveScan(code)
            case .platformPortal(let resource):
                openPlatformPortal(resource)
            case .loginChallenge(let challenge):
                approveLoginChallenge(challenge)
            }
        } catch {
            alert = AppAlert(title: "二维码无法打开", message: error.localizedDescription)
        }
    }

    private func approveLoginChallenge(_ challenge: String) {
        guard !challenge.isEmpty else { return }
        Task { @MainActor in
            do {
                _ = try await QRLoginService.approve(challenge: challenge)
                alert = AppAlert(title: "网页登录已确认", message: "请回到浏览器，管理台会自动完成登录。")
            } catch {
                alert = AppAlert(title: "扫码登录失败", message: error.localizedDescription)
            }
        }
    }

    private func openPlatformPortal(_ resource: PlatformPortalResource) {
        portalOpening = true
        Task { @MainActor in
            defer { portalOpening = false }
            do {
                portalSession = try await PlatformPortalSessionService.create(for: resource, platformBaseURL: EdgeFlowClient.baseURL)
            } catch {
                alert = AppAlert(title: "访问验证失败", message: error.localizedDescription)
            }
        }
    }

    private func saveScan(_ code: String) {
        if let targetID = targetExecutionItemID {
            guard let target = executionItems.first(where: { $0.id == targetID }) else {
                targetExecutionItemID = nil
                alert = AppAlert(title: "任务不可用", message: "指定任务已不在本地清单中，请进入今日任务刷新。")
                return
            }
            guard target.codeValue.compare(code.trimmingCharacters(in: .whitespacesAndNewlines), options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame else {
                alert = AppAlert(title: "产品码不匹配", message: "当前任务仅可扫码：\(target.codeValue)。")
                return
            }
            targetExecutionItemID = nil
        }
        if let list = todayExecutionList {
            let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if let cancelled = todayExecutionItems.first(where: {
                $0.codeValue.uppercased() == normalized && $0.state == .cancelled
            }) {
                alert = AppAlert(title: "该项已取消", message: "\(cancelled.codeValue) 已从今日执行清单取消，不能作为正常任务扫码。")
                return
            }
            if let item = ExecutionListService.item(matching: code, in: list, from: todayExecutionItems) {
                if let captureID = item.captureID,
                   let existing = captures.first(where: { $0.id == captureID }) {
                    scanDestination = ScannedCode(captureID: existing.id, draftID: existing.draftID, isHistory: existing.isCompleted)
                    return
                }
                guard let draft = drafts.first(where: { $0.id == item.draftID }) else {
                    alert = AppAlert(title: "任务不可用", message: "该清单项对应的任务未缓存，请进入今日任务刷新后再试。")
                    return
                }
                selectedTaskID = draft.id
                do {
                    let capture = try TaskDraftService.startCapture(code, for: draft, executionItem: item, in: modelContext)
                    scanDestination = ScannedCode(captureID: capture.id, draftID: draft.id, isHistory: false)
                } catch {
                    alert = AppAlert(title: "产品码无法保存", message: error.localizedDescription)
                }
                return
            }
            alert = AppAlert(title: "无法开始扫码", message: "该 SN 不在当前任务清单内，无法开始扫码。")
            return
        }
        alert = AppAlert(title: "无法开始扫码", message: "今日清单尚未拉取，请先到「任务」刷新后再扫码。")
    }

    private func selectPreferredTaskIfNeeded() {
        guard selectedTaskID == nil, !drafts.isEmpty else { return }
        selectedTaskID = drafts.first?.id
    }

    private func selectTargetTaskAndOpenScanner() {
        guard let targetID = targetExecutionItemID,
              let item = executionItems.first(where: { $0.id == targetID }),
              let draft = drafts.first(where: { $0.id == item.draftID }) else { return }
        selectedTaskID = draft.id
        if let captureID = item.captureID,
           let capture = captures.first(where: { $0.id == captureID }) {
            targetExecutionItemID = nil
            scanDestination = ScannedCode(
                captureID: capture.id,
                draftID: draft.id,
                isHistory: capture.isCompleted
            )
        } else {
            scannerPresented = true
        }
    }

    @MainActor
    private func refreshTodayListIfNeeded() async {
        guard TodayListRefresh.shouldAutoRefresh(list: todayExecutionList, registration: registration) else { return }
        _ = await TodayListRefresh.refresh(in: modelContext, registration: registration, todayList: todayExecutionList)
    }
}

private struct ScannedCode: Identifiable, Hashable {
    let captureID: String
    let draftID: String
    let isHistory: Bool
    var id: String { "\(captureID)-\(isHistory)" }
}

private struct TodayScan: Identifiable {
    let captureID: String
    let draftID: String
    let code: String
    let productName: String?
    let productModel: String?
    let scannedAt: Date
    let thumbnail: UIImage?
    var id: String { captureID }
}
