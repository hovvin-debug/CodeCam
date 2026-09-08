import SwiftData
import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TaskDraft.updatedAt, order: .reverse) private var drafts: [TaskDraft]
    @Query(sort: \CaptureSession.scannedAt, order: .reverse) private var captures: [CaptureSession]
    @Query(sort: \LocalMedia.capturedAt, order: .reverse) private var media: [LocalMedia]
    @Query(sort: \ExecutionList.updatedAt, order: .reverse) private var executionLists: [ExecutionList]
    @Query private var executionItems: [ExecutionItem]

    @State private var selectedTaskID: String?
    @State private var scannerPresented = false
    @State private var scanDestination: ScannedCode?
    @State private var unplannedScannedCode: String?
    @State private var portalSession: PlatformPortalSession?
    @State private var portalOpening = false
    @State private var alert: AppAlert?

    private var activeDraft: TaskDraft? {
        drafts.first { $0.id == selectedTaskID } ?? drafts.first
    }

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
        NavigationStack {
            captureList
                .navigationTitle("采集")
                .navigationBarTitleDisplayMode(.large)
                .task {
                    selectPreferredTaskIfNeeded()
                }
                .onChange(of: drafts.count) { _, _ in
                    selectPreferredTaskIfNeeded()
                }
                .onChange(of: selectedTaskID) { _, value in
                    if let value { UserDefaults.standard.set(value, forKey: "codecam.preferred-task-id") }
                }
                .sheet(isPresented: $scannerPresented) {
                    CodeScannerView { scannedValue in
                        scannerPresented = false
                        handleScannedValue(scannedValue)
                    } onCancel: {
                        scannerPresented = false
                    }
                }
                .sheet(item: $portalSession) { session in
                    PlatformPortalBrowserView(session: session)
                }
                .navigationDestination(item: $scanDestination) { scan in
                    ProductCaptureView(captureID: scan.captureID, draftID: scan.draftID, isHistory: scan.isHistory)
                }
                .alert("不在今日执行清单", isPresented: Binding(
                    get: { unplannedScannedCode != nil },
                    set: { if !$0 { unplannedScannedCode = nil } }
                )) {
                    Button("取消", role: .cancel) { unplannedScannedCode = nil }
                    Button("补充采集") {
                        if let code = unplannedScannedCode { startSupplementalScan(code) }
                        unplannedScannedCode = nil
                    }
                } message: {
                    Text("该 SN 不属于当前今日计划，不会计入今日完成。是否作为补充采集继续？")
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
        List {
            taskTypeSection
            scanSection
            recentSection
        }
    }

    private var scanSection: some View {
        Section {
            Button {
                scannerPresented = true
            } label: {
                Label("扫码采集", systemImage: "barcode.viewfinder")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(activeDraft == nil)
            .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
        } footer: {
            Text(scanFooter)
        }
    }

    @ViewBuilder
    private var taskTypeSection: some View {
        if let draft = activeDraft {
            Section {
                Picker("任务", selection: taskSelection) {
                    ForEach(drafts) { task in
                        Text(task.title).tag(task.id)
                    }
                }
            } header: {
                Text("任务")
            } footer: {
                Text("\(draft.taskType) · 模板 v\(draft.templateVersion)。不在今日清单中的码会按此类型补充采集。")
            }
        } else {
            Section {
                ContentUnavailableView(
                    "还不能采集",
                    systemImage: "barcode.viewfinder",
                    description: Text("先到「我的」登录并连接设备，再到「任务」刷新今日清单。")
                )
                .listRowBackground(Color.clear)
            }
        }
    }

    private var recentSection: some View {
        Section {
            if todayRecentScans.isEmpty {
                Text("今天还没有采集记录")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(todayRecentScans) { scan in
                    Button {
                        scanDestination = ScannedCode(captureID: scan.captureID, draftID: scan.draftID, isHistory: true)
                    } label: {
                        ProductIdentityRow(
                            code: scan.code,
                            productName: scan.productName,
                            productModel: scan.productModel,
                            caption: WallClock.time(scan.scannedAt),
                            thumbnail: scan.thumbnail
                        )
                    }
                }
            }
        } header: {
            Text("今日最近")
        } footer: {
            Text("仅显示今天最近 5 条，完整历史在「记录」。")
        }
    }

    private var taskSelection: Binding<String> {
        Binding(
            get: { selectedTaskID ?? drafts.first?.id ?? "" },
            set: { selectedTaskID = $0 }
        )
    }

    private var scanFooter: String {
        if activeDraft == nil {
            return "连接设备并刷新任务后即可扫码。"
        }
        if todayExecutionList == nil {
            return "今日清单尚未拉取。扫描后将按上方任务类型作为补充采集。"
        }
        if outstandingCount > 0 {
            return "今日还有 \(outstandingCount) 项待处理，完整清单在「任务」。"
        }
        return "今日待办已完成。仍可扫码做补充采集，结果记入「记录」。"
    }

    private func handleScannedValue(_ scannedValue: String) {
        do {
            switch try PlatformPortalQRCodeRouter.route(scannedValue: scannedValue, platformBaseURL: EdgeFlowClient.baseURL) {
            case .productCode(let code):
                saveScan(code)
            case .platformPortal(let resource):
                openPlatformPortal(resource)
            }
        } catch {
            alert = AppAlert(title: "二维码无法打开", message: error.localizedDescription)
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
        if let list = todayExecutionList {
            let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if let cancelled = todayExecutionItems.first(where: {
                $0.codeValue.uppercased() == normalized && $0.state == .cancelled
            }) {
                alert = AppAlert(title: "该项已取消", message: "\(cancelled.codeValue) 已从今日执行清单取消，不能作为正常任务采集。")
                return
            }
            if let item = ExecutionListService.item(matching: code, in: list, from: todayExecutionItems) {
                if let captureID = item.captureID,
                   let existing = captures.first(where: { $0.id == captureID }) {
                    scanDestination = ScannedCode(captureID: existing.id, draftID: existing.draftID, isHistory: existing.isCompleted)
                    return
                }
                guard let draft = drafts.first(where: { $0.id == item.draftID }) else {
                    alert = AppAlert(title: "任务不可用", message: "该清单项对应的任务未缓存，请到「任务」页刷新后再试。")
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
            unplannedScannedCode = code
            return
        }
        startSupplementalScan(code)
    }

    private func startSupplementalScan(_ code: String) {
        guard let draft = activeDraft else { return }
        do {
            let capture = try TaskDraftService.startCapture(code, for: draft, in: modelContext)
            scanDestination = ScannedCode(captureID: capture.id, draftID: draft.id, isHistory: false)
        } catch {
            alert = AppAlert(title: "产品码无法保存", message: error.localizedDescription)
        }
    }

    private func selectPreferredTaskIfNeeded() {
        guard selectedTaskID == nil, !drafts.isEmpty else { return }
        let preferredID = UserDefaults.standard.string(forKey: "codecam.preferred-task-id")
        selectedTaskID = drafts.first(where: { $0.id == preferredID })?.id ?? drafts.first?.id
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
