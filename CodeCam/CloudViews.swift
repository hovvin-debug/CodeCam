import SwiftUI

struct CloudSettingsView: View {
    @EnvironmentObject private var store: RecordStore
    @EnvironmentObject private var cloud: CloudService
    @AppStorage("camflow.server") private var server = "http://192.168.1.7:8766"
    @State private var username = ""
    @State private var password = ""
    @State private var working = false
    @State private var error: String?
    @State private var confirmBinding = false
    @State private var loginVisible = false
    @State private var checkingServer = false
    @State private var organizationName = ""
    @State private var inviteCode = ""
    private var pending: Int { store.records.filter { $0.submittedAt != nil && $0.syncedAt == nil }.count }

    var body: some View {
        NavigationStack {
            Form {
                Section("本机资料") {
                    LabeledContent("本机记录", value: "\(store.records.count) 条")
                    LabeledContent("待同步", value: "\(pending) 条")
                    if let binding = store.archive.cloudBinding {
                        Text("本机资料绑定账号：\(binding.username)").font(.footnote)
                    }
                }
                let pendingRecords = store.records.filter { $0.submittedAt != nil && $0.syncedAt == nil }
                if !pendingRecords.isEmpty {
                    Section("待同步 · \(pendingRecords.count)") {
                        Button(cloud.syncing ? "正在同步…" : "手动同步全部") {
                            Task { await cloud.sync(store: store) }
                        }
                        .disabled(cloud.syncing || serverMismatch)
                        ForEach(pendingRecords) { record in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(record.serial).font(.headline)
                                        Text("\(record.photos.count) 张照片 · \(record.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("重试此条") {
                                        Task { await cloud.sync(store: store, recordID: record.id) }
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(cloud.syncing || serverMismatch)
                                }
                                if let reason = record.syncError {
                                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption).foregroundStyle(.red)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                if let session = cloud.session {
                    Section("工作空间") {
                        ForEach(cloud.spaces) { space in
                            Button {
                                do { try cloud.selectSpace(space, store: store) }
                                catch { self.error = error.localizedDescription }
                            } label: {
                                HStack {
                                    Text(space.name)
                                    if space.kind == "organization" { Text("组织").font(.caption).foregroundStyle(.secondary) }
                                    Spacer()
                                    if space.id == session.spaceID { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }
                            }.disabled(cloud.syncing)
                        }
                        TextField("新组织名称", text: $organizationName)
                        Button("创建组织并生成邀请码") {
                            Task {
                                do { _ = try await cloud.createOrganization(name: organizationName, store: store); organizationName = "" }
                                catch { self.error = error.localizedDescription }
                            }
                        }.disabled(organizationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || cloud.syncing)
                        if let code = cloud.latestJoinCode {
                            LabeledContent("组织邀请码", value: code).textSelection(.enabled)
                        }
                        TextField("输入组织邀请码", text: $inviteCode).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("加入组织") {
                            Task {
                                do { _ = try await cloud.joinOrganization(code: inviteCode, store: store); inviteCode = "" }
                                catch { self.error = error.localizedDescription }
                            }
                        }.disabled(inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || cloud.syncing)
                    }
                    Section("CamFlow") {
                        LabeledContent("账号", value: session.username)
                        Text(session.server).font(.caption).textSelection(.enabled)
                        if serverAddressChanged(session.server) {
                            Text("登录凭证仍指向旧服务器。请重新登录后再同步。")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                        LabeledContent("存储", value: session.storage == "cos" ? "腾讯云 COS" : "服务端本地测试存储")
                        Button(checkingServer ? "正在检查服务…" : "检查当前服务地址") { checkServer() }
                            .disabled(checkingServer || cloud.syncing)
                        Button(cloud.syncing ? "正在同步…" : "同步已完成记录") {
                            if store.archive.cloudBinding == nil { confirmBinding = true }
                            else { Task { await cloud.sync(store: store) } }
                        }.disabled(cloud.syncing || working || pending == 0 || serverAddressChanged(session.server))
                        NavigationLink("查看云端记录") { CloudRecordsView() }
                        Button("重新登录") { loginVisible = true }
                        Button("退出登录") {
                            working = true
                            Task {
                                defer { working = false }
                                do { try await cloud.logout() } catch { self.error = error.localizedDescription }
                            }
                        }.disabled(working || cloud.syncing)
                    }
                }
                if cloud.session == nil || loginVisible {
                    Section("连接服务") {
                        TextField("服务地址", text: $server).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        TextField("账号", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.username)
                        SecureField("密码（至少 10 位）", text: $password).textContentType(.password)
                        Button(checkingServer ? "正在检查服务…" : "检查当前服务地址") { checkServer() }
                            .disabled(checkingServer || working)
                        Button("登录") { authenticate(register: false) }.disabled(working || cloud.syncing)
                        Button("注册个人账号") { authenticate(register: true) }.disabled(working || cloud.syncing)
                    }
                }
                if let message = cloud.message { Section("同步状态") { Text(message).font(.footnote) } }
                Section {
                    Text("仅上传已完成的采集。失败后资料保留在本机，重新同步不会创建重复记录。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("CodeCam · 个人与组织采集").font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("我的")
            .onAppear {
                Task { try? await cloud.refreshSpaces() }
                if let binding = store.archive.cloudBinding {
                    server = binding.server; username = binding.username
                } else {
                    if server == "http://192.168.1.5:8765" || server == "http://192.168.1.5:8766" {
                        server = "http://192.168.1.7:8766"
                    }
                    if let session = cloud.session { username = session.username }
                }
            }
            .errorAlert($error)
            .confirmationDialog("将本机资料同步到此个人账号？", isPresented: $confirmBinding, titleVisibility: .visible) {
                Button("绑定并同步") { Task { await cloud.sync(store: store) } }
            } message: {
                Text("目标：\(cloud.session?.username ?? "")。本机资料将固定绑定此账号和服务。")
            }
        }
    }
    private func authenticate(register: Bool) {
        working = true
        Task {
            defer { working = false }
            do {
                try await cloud.login(server: server, username: username, password: password, register: register, store: store)
                password = ""; loginVisible = false
            } catch { self.error = error.localizedDescription }
        }
    }
    private func serverAddressChanged(_ active: String) -> Bool {
        (try? CloudService.normalizedServer(server)) != active
    }
    private var serverMismatch: Bool {
        guard let active = cloud.session?.server else { return false }
        return serverAddressChanged(active)
    }
    private func checkServer() {
        checkingServer = true
        Task {
            defer { checkingServer = false }
            do {
                let result = try await cloud.checkServer(server)
                cloud.message = "服务可连接 · \(result.service) · \(result.storage == "cos" ? "COS" : "本地测试存储")"
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct CloudRecordsView: View {
    @EnvironmentObject private var cloud: CloudService
    @State private var records: [RemoteRecord] = []
    @State private var serial = ""
    @State private var nextOffset: Int?
    @State private var error: String?
    @State private var loading = false
    var body: some View {
        List {
            Section {
                TextField("完整序列号（留空查看全部）", text: $serial).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("查询") { Task { await load() } }.disabled(loading)
            }
            ForEach(records) { record in
                NavigationLink { CloudRecordDetail(record: record) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(record.serial).font(.headline)
                        Text(record.createdAt).font(.caption).foregroundStyle(.secondary)
                        Text("\(record.photos.count) 张照片 · 已同步").font(.caption).foregroundStyle(.green)
                    }
                }
            }
            if loading { ProgressView("正在读取…") }
            else if records.isEmpty { Text("没有已同步记录").foregroundStyle(.secondary) }
            if nextOffset != nil { Button("加载更多") { Task { await load(more: true) } }.disabled(loading) }
        }.navigationTitle("云端记录")
            .task { await load() }.refreshable { await load() }.errorAlert($error)
    }
    private func load(more: Bool = false) async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        do {
            let page = try await cloud.records(serial: serial.trimmingCharacters(in: .whitespacesAndNewlines), offset: more ? nextOffset ?? 0 : 0)
            records = more ? records + page.records : page.records; nextOffset = page.nextOffset
        } catch { self.error = error.localizedDescription }
    }
}

struct CloudRecordDetail: View {
    let record: RemoteRecord
    var body: some View {
        List {
            Section { Text(record.serial).font(.title2.bold()); Text(record.createdAt).font(.caption) }
            if record.taskID != nil { Section { Label("来自组织任务", systemImage: "checklist") } }
            Section("备注") { Text(record.note.isEmpty ? "无备注" : record.note).textSelection(.enabled) }
            Section("照片") { ForEach(record.photos) { photo in CloudPhotoView(record: record.id, photo: photo.id, spaceID: record.spaceID) } }
        }.navigationTitle("云端详情").navigationBarTitleDisplayMode(.inline)
    }
}
private struct CloudPhotoView: View {
    @EnvironmentObject private var cloud: CloudService
    let record: UUID
    let photo: UUID
    let spaceID: UUID
    @State private var image: UIImage?
    @State private var error: String?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else if let error { Text(error).foregroundStyle(.secondary) }
            else { ProgressView("读取照片…") }
        }.task {
            do {
                let data = try await cloud.photo(record: record, photo: photo, spaceID: spaceID)
                guard let decoded = UIImage(data: data) else { throw CloudError(message: "照片无法读取") }
                image = decoded
            } catch { self.error = error.localizedDescription }
        }
    }
}
