import SwiftUI
import AVFoundation

private struct AssignmentDraft: Codable {
    let id: UUID
    let userID: UUID
    let organizationID: UUID
    let serial: String?
    let serials: [String]?
    let note: String
    let assigneeIDs: [UUID]?
    let assigneeID: UUID?
    var codes: [String] { serials ?? serial.map { [$0] } ?? [] }
    var recipients: [UUID] { assigneeIDs ?? assigneeID.map { [$0] } ?? [] }
}

struct TasksView: View {
    @EnvironmentObject private var store: RecordStore
    @EnvironmentObject private var cloud: CloudService
    @State private var tasks: [RemoteTask] = []
    @State private var nextOffset: Int?
    @State private var loading = false
    @State private var error: String?
    @State private var path: [UUID] = []
    @State private var assigning = false
    @State private var showingHistory = false
    @State private var summary: TaskSummary?
    @State private var cancelTarget: RemoteTask?
    @AppStorage("codecam.pendingAssignment") private var pendingAssignment = ""

    private var activeSpace: CloudSpace? {
        guard let id = cloud.session?.spaceID else { return nil }
        return cloud.spaces.first { $0.id == id }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if cloud.session == nil {
                    ContentUnavailableView("请先登录", systemImage: "person.crop.circle", description: Text("在「我的」连接 CamFlow 后查看分配的任务。"))
                } else if activeSpace?.kind != "organization" {
                    ContentUnavailableView("请选择组织空间", systemImage: "person.3", description: Text("任务属于组织。在「我的」切换组织后查看。"))
                } else {
                    if activeSpace?.role == "owner" {
                        Section {
                            Button("连续扫码分配任务", systemImage: "barcode.viewfinder") { assigning = true }
                                .font(.headline)
                            if currentDraft != nil { Text("有一项分配尚未收到服务端确认，可继续重试。 ").font(.caption).foregroundStyle(.orange) }
                        }
                    }
                    Section("任务统计") {
                        if let summary {
                            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                                GridRow {
                                    metric("今日分配", value: summary.todayAssigned, symbol: "tray.and.arrow.down.fill", tint: .blue)
                                    metric("今日完成", value: summary.todayCompleted, symbol: "checkmark.circle.fill", tint: .green)
                                }
                                GridRow {
                                    metric("待执行", value: summary.pending, symbol: "clock.fill", tint: .orange)
                                    metric("本机未同步", value: localUnsyncedCount, symbol: "icloud.and.arrow.up", tint: localUnsyncedCount > 0 ? .red : .secondary)
                                }
                            }
                            Text("未同步数量只统计这台 CodeCam 上已完成、尚未上传的记录。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if loading { ProgressView("正在读取统计…") }
                        else { Text("暂时无法读取任务统计").foregroundStyle(.secondary) }
                    }
                    Section {
                        Picker("任务范围", selection: $showingHistory) {
                            Text("进行中").tag(false)
                            Text("历史").tag(true)
                        }.pickerStyle(.segmented)
                    }
                    if showingHistory {
                        let finished = tasks.filter { $0.status != "open" }
                        Section("已完成与已撤销 · \(finished.count)") {
                            ForEach(finished) { task in taskRow(task) }
                            if finished.isEmpty && !loading { Text("当前已加载的任务中暂无历史记录").foregroundStyle(.secondary) }
                        }
                    } else {
                        let mine = tasks.filter { $0.status == "open" && $0.assigneeID == cloud.session?.userID }
                        Section("我的待执行 · \(mine.count)") {
                            ForEach(mine) { task in taskRow(task) }
                            if mine.isEmpty && !loading { Text("目前没有分配给我的待执行任务").foregroundStyle(.secondary) }
                        }
                        if activeSpace?.role == "owner" {
                            let assigned = tasks.filter { $0.status == "open" && $0.assigneeID != cloud.session?.userID }
                            Section("我分配的 · \(assigned.count)") {
                                ForEach(assigned) { task in taskRow(task) }
                                if assigned.isEmpty && !loading { Text("目前没有分配给其他成员的待执行任务").foregroundStyle(.secondary) }
                            }
                        }
                    }
                    if loading { ProgressView("正在读取任务…") }
                    if nextOffset != nil {
                        Button("加载更多任务") { Task { await load(more: true) } }.disabled(loading)
                    }
                }
            }
            .navigationTitle("任务")
            .navigationDestination(for: UUID.self) { RecordDetail(id: $0) }
            .toolbar { Button("刷新", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(loading) }
            .sheet(isPresented: $assigning) {
                if let org = activeSpace?.organizationID {
                    AssignmentView(organizationID: org, pendingAssignment: $pendingAssignment) { Task { await load() } }
                        .environmentObject(cloud)
                }
            }
            .alert("撤销这项任务？", isPresented: Binding(get: { cancelTarget != nil }, set: { if !$0 { cancelTarget = nil } })) {
                Button("撤销任务", role: .destructive) {
                    if let task = cancelTarget { Task { await cancel(task) } }
                    cancelTarget = nil
                }
                Button("返回", role: .cancel) { cancelTarget = nil }
            } message: {
                Text("任务尚未完成时可撤销。已开始上传记录的任务不能撤销。")
            }
            .refreshable { await load() }
            .onAppear { Task { await prepareAndLoad() } }
            .onChange(of: cloud.session?.spaceID) { _, _ in
                tasks = []; nextOffset = nil; summary = nil; showingHistory = false
                Task { await prepareAndLoad() }
            }
            .errorAlert($error)
        }
    }

    private var currentDraft: AssignmentDraft? {
        guard let data = pendingAssignment.data(using: .utf8),
              let draft = try? JSONDecoder().decode(AssignmentDraft.self, from: data),
              draft.userID == cloud.session?.userID,
              draft.organizationID == activeSpace?.organizationID else { return nil }
        return draft
    }

    private var localUnsyncedCount: Int {
        guard let spaceID = activeSpace?.id else { return 0 }
        return store.records.filter { $0.spaceID == spaceID && $0.submittedAt != nil && $0.syncedAt == nil }.count
    }
    private func metric(_ title: String, value: Int, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text("\(value)").font(.title2.bold()).foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func taskRow(_ task: RemoteTask) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(task.serial).font(.headline)
                Spacer()
                Text(task.status == "completed" ? "已完成" : task.status == "cancelled" ? "已撤销" : "待采集")
                    .font(.caption).foregroundStyle(task.status == "completed" ? .green : task.status == "cancelled" ? .secondary : .orange)
            }
            if !task.note.isEmpty { Text(task.note).font(.subheadline) }
            Text("分配给 \(task.assigneeUsername) · \(task.createdAt.prefix(16).replacingOccurrences(of: "T", with: " "))")
                .font(.caption).foregroundStyle(.secondary)
            if task.status == "cancelled" {
                ForEach(store.records.filter { $0.taskID == task.id && $0.syncedAt == nil }) { record in
                    Button("解除本机记录的任务关联") {
                        do {
                            try store.clearTask(record.id, taskID: task.id)
                            if record.submittedAt != nil { Task { await cloud.sync(store: store, recordID: record.id) } }
                        } catch { self.error = error.localizedDescription }
                    }
                }
            } else if task.status == "completed" {
                if let recordID = task.recordID {
                    if let local = store.record(recordID) {
                        NavigationLink("查看完成记录") { RecordDetail(id: local.id) }
                    } else {
                        NavigationLink("查看完成记录") { TaskRemoteRecordView(id: recordID, spaceID: task.spaceID) }
                    }
                }
            } else if task.assigneeID == cloud.session?.userID {
                if let local = store.records.first(where: { $0.taskID == task.id && $0.spaceID == task.spaceID && $0.submittedAt != nil }) {
                    NavigationLink("查看本机记录") { RecordDetail(id: local.id) }
                    if local.submittedAt != nil && local.syncedAt == nil {
                        Button(cloud.syncing ? "正在同步…" : "同步此任务记录") {
                            Task { await cloud.sync(store: store, recordID: local.id); await load() }
                        }.disabled(cloud.syncing)
                    }
                } else {
                    Label("请直接扫描实物，系统会自动匹配此任务", systemImage: "viewfinder")
                        .font(.caption).foregroundStyle(.blue)
                }
            }
            if task.status == "open" && activeSpace?.role == "owner" {
                Button("撤销错误分配", role: .destructive) { cancelTarget = task }
            }
        }
        .padding(.vertical, 6)
    }

    private func cancel(_ task: RemoteTask) async {
        guard let org = activeSpace?.organizationID else { return }
        do {
            let result = try await cloud.cancelTask(task, organizationID: org)
            guard result.status == "cancelled" else { throw CloudError(message: "服务端尚未确认撤销") }
            await load()
        } catch { self.error = error.localizedDescription }
    }

    private func prepareAndLoad() async {
        if cloud.session != nil && cloud.spaces.isEmpty {
            do { try await cloud.refreshSpaces() } catch { self.error = error.localizedDescription }
        }
        await load()
    }

    private func load(more: Bool = false) async {
        guard !loading else { return }
        guard let session=cloud.session, activeSpace?.kind == "organization" else {
            tasks = []; nextOffset = nil; return
        }
        loading = true
        defer { loading = false }
        do {
            let page = try await cloud.tasks(offset: more ? nextOffset ?? 0 : 0)
            let latestSummary = try await cloud.taskSummary(timezone: TimeZone.current.identifier)
            guard cloud.session?.token == session.token && cloud.session?.spaceID == session.spaceID else { return }
            var seen = Set<UUID>()
            tasks = (more ? tasks + page.tasks : page.tasks).filter { seen.insert($0.id).inserted }
            nextOffset = page.nextOffset
            summary = latestSummary
        } catch { self.error = error.localizedDescription }
    }
}

private struct AssignmentView: View {
    @EnvironmentObject private var cloud: CloudService
    @Environment(\.dismiss) private var dismiss
    let organizationID: UUID
    @Binding var pendingAssignment: String
    let onSuccess: () -> Void
    @State private var members: [OrganizationMember] = []
    @State private var serial = ""
    @State private var serials: [String] = []
    @State private var note = ""
    @State private var selectedMembers: Set<UUID> = []
    @State private var scanning = false
    @State private var sending = false
    @State private var error: String?
    @State private var success: String?
    @State private var step = 0
    @State private var lastResult: TaskBulkReply?

    private var draft: AssignmentDraft? {
        guard let data = pendingAssignment.data(using: .utf8),
              let value = try? JSONDecoder().decode(AssignmentDraft.self, from: data),
              value.userID == cloud.session?.userID, value.organizationID == organizationID else { return nil }
        return value
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(step == 0 ? "1 扫码清单  →  2 选择成员  →  3 核对提交" :
                         step == 1 ? "1 扫码清单  →  2 选择成员  →  3 核对提交" :
                         step == 2 ? "核对序列号与成员后，一次提交到 CamFlow" : "本次分配已收到 CamFlow 确认")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if step == 0 {
                Section("序列号清单 · \(serials.count) 个") {
                    TextField("扫描或输入序列号", text: $serial)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(draft != nil)
                    Button("加入清单", systemImage: "plus.circle") { addSerial(serial) }
                        .disabled(draft != nil || serial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("连续扫码", systemImage: "barcode.viewfinder") {
                        Task { @MainActor in
                            if await AVCaptureDevice.requestAccess(for: .video) { scanning = true }
                            else { error = "请允许相机访问，或手工输入序列号。" }
                        }
                    }.disabled(draft != nil)
                    ForEach(serials, id: \.self) { code in
                        HStack {
                            Text(code).font(.body.monospaced())
                            Spacer()
                            if draft == nil {
                                Button("移除", systemImage: "xmark.circle") { serials.removeAll { $0 == code } }
                                    .labelStyle(.iconOnly)
                            }
                        }
                    }
                }
                }
                if step == 1 {
                Section("分配给") {
                    if members.isEmpty { ProgressView("读取组织成员…") }
                    else {
                        Button(selectedMembers.count == members.count ? "取消全选" : "选择全部成员（含管理员）") {
                            selectedMembers = selectedMembers.count == members.count ? [] : Set(members.map(\.id))
                        }.disabled(draft != nil)
                        ForEach(members) { member in
                            Button {
                                if selectedMembers.contains(member.id) { selectedMembers.remove(member.id) }
                                else { selectedMembers.insert(member.id) }
                            } label: {
                                HStack {
                                    Text(member.username).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: selectedMembers.contains(member.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedMembers.contains(member.id) ? .blue : .secondary)
                                }
                            }.disabled(draft != nil)
                        }
                        Text("已选择 \(selectedMembers.count) 人").font(.caption).foregroundStyle(.secondary)
                    }
                }
                }
                if step == 2 {
                    Section("核对任务") {
                        LabeledContent("序列号", value: "\(draft?.codes.count ?? serials.count) 个")
                        LabeledContent("成员", value: "\(draft?.recipients.count ?? selectedMembers.count) 人")
                        Text("预计 \((draft?.codes.count ?? serials.count) * (draft?.recipients.count ?? selectedMembers.count)) 项任务。已有的待执行任务不会重复创建。")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if let draft {
                            Text(draft.codes.joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(serials.joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("分配给：" + members.filter { selectedMembers.contains($0.id) }.map(\.username).joined(separator: "、"))
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("任务说明（可选）", text: $note, axis: .vertical).disabled(draft != nil)
                    }
                }
                if let draft {
                    Section {
                        Text("待确认：\(draft.codes.count) 个序列号，分配给 \(draft.recipients.count) 人。可重试实时提交；收到服务端确认后才会显示已分配。")
                        Button("放弃这项待提交分配", role: .destructive) { pendingAssignment = "" }
                    }
                }
                if step == 3, let success {
                    Section("提交结果") {
                        Label(success, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        if let lastResult, lastResult.existingCount > 0 {
                            Text("已有的待执行任务已计入结果，未重复创建。")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
                Section {
                    if step == 0 {
                        Button("下一步：选择成员") {
                            if !serial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { addSerial(serial) }
                            if !serials.isEmpty && serial.isEmpty { step = 1 }
                        }.disabled(serials.isEmpty && serial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else if step == 1 {
                        Button("下一步：核对任务") { step = 2 }
                            .disabled(selectedMembers.isEmpty)
                        Button("返回扫码清单") { step = 0 }
                    } else if step == 2 {
                        Button(sending ? "正在实时提交…" : draft == nil ? "确认并实时分配" : "重试提交") {
                            Task { await submit() }
                        }.disabled(sending || selectedMembers.isEmpty || serials.isEmpty)
                        if draft == nil { Button("返回选择成员") { step = 1 } }
                    } else {
                        Button("继续分配下一批") { step = 0; success = nil; lastResult = nil }
                    }
                }
            }
            .navigationTitle("批量分配任务")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .sheet(isPresented: $scanning) {
                CodeScannerView(onScan: { addSerial($0) }, onCancel: { scanning = false }, title: "连续扫描序列号", continuous: true, scanCount: serials.count)
            }
            .task { await loadMembers() }
        }
    }
    private func loadMembers() async {
        if let draft { serials = draft.codes; note = draft.note; selectedMembers = Set(draft.recipients); step = 2 }
        do { members = try await cloud.organizationMembers() }
        catch { self.error = error.localizedDescription }
    }
    private func addSerial(_ value: String) {
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty && code.count <= 200 else { error = "序列号应为 1–200 个字符"; return }
        guard !serials.contains(code) else { serial = ""; return }
        guard serials.count < 100 else { error = "一次最多分配 100 个序列号"; return }
        serials.append(code); serial = ""; error = nil
    }
    private func submit() async {
        guard let userID = cloud.session?.userID else { error = "请先登录"; return }
        if !pendingAssignment.isEmpty && draft == nil {
            error = "另一账号或组织有待确认的任务，请先切回原组织处理。"
            return
        }
        let assignment: AssignmentDraft
        if let draft { assignment = draft }
        else {
            guard !selectedMembers.isEmpty else { return }
            guard selectedMembers.count <= 100 else { error = "一次最多分配给 100 位成员"; return }
            guard note.count <= 2000 else { error = "任务说明最多 2000 个字符"; return }
            if !serial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                addSerial(serial)
                guard serial.isEmpty else { return }
            }
            guard !serials.isEmpty else { return }
            assignment = AssignmentDraft(id: UUID(), userID: userID, organizationID: organizationID,
                serial: nil, serials: serials, note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                assigneeIDs: selectedMembers.sorted { $0.uuidString < $1.uuidString }, assigneeID: nil)
            guard let data = try? JSONEncoder().encode(assignment), let saved = String(data: data, encoding: .utf8) else {
                error = "待提交任务无法保存"; return
            }
            pendingAssignment = saved
        }
        sending = true; error = nil; success = nil
        defer { sending = false }
        do {
            let result = try await cloud.assignBulkTasks(id: assignment.id, serials: assignment.codes, note: assignment.note,
                assigneeIDs: assignment.recipients, organizationID: assignment.organizationID)
            guard result.serialCount == assignment.codes.count, result.recipientCount == assignment.recipients.count,
                  result.createdCount + result.existingCount == assignment.codes.count * assignment.recipients.count else {
                throw CloudError(message: "任务回执与本机提交不一致")
            }
            pendingAssignment = ""
            success = "\(result.serialCount) 个序列号已分配给 \(result.recipientCount) 人（新建 \(result.createdCount)，已有任务 \(result.existingCount)）"
            lastResult = result
            serial = ""; serials = []; note = ""; selectedMembers = []
            step = 3
            onSuccess()
        } catch { self.error = error.localizedDescription }
    }
}

private struct TaskRemoteRecordView: View {
    @EnvironmentObject private var cloud: CloudService
    let id: UUID
    let spaceID: UUID
    @State private var record: RemoteRecord?
    @State private var error: String?

    var body: some View {
        Group {
            if let record { CloudRecordDetail(record: record) }
            else if let error { ContentUnavailableView("无法读取记录", systemImage: "doc.questionmark", description: Text(error)) }
            else { ProgressView("正在读取记录…") }
        }
        .task {
            do { record = try await cloud.record(id: id, spaceID: spaceID) }
            catch { self.error = error.localizedDescription }
        }
    }
}
