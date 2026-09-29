import SwiftUI
import AVFoundation
import PhotosUI
import ImageIO

@main
struct CodeCamApp: App {
    @StateObject private var store = RecordStore()
    @StateObject private var cloud = CloudService()
    var body: some Scene {
        WindowGroup {
            if let error = store.loadError {
                ContentUnavailableView {
                    Label("记录暂时无法读取", systemImage: "externaldrive.badge.exclamationmark")
                } description: { Text("原始数据已保留。\n" + error) } actions: {
                    Button("重新读取") { store.reload() }
                }
            } else { HomeView().environmentObject(store).environmentObject(cloud) }
        }
    }
}

struct HomeView: View {
    @EnvironmentObject private var store: RecordStore
    @EnvironmentObject private var cloud: CloudService
    var body: some View {
        TabView {
            CaptureHome().tabItem { Label("采集", systemImage: "viewfinder") }
            TasksView().tabItem { Label("任务", systemImage: "checklist") }
            RecordsView().tabItem { Label("记录", systemImage: "clock.arrow.circlepath") }
            CloudSettingsView().tabItem { Label("我的", systemImage: "person") }
        }
        .tint(.blue)
        .task { if cloud.session != nil { try? await cloud.refreshSpaces() } }
    }
}

struct CaptureHome: View {
    @EnvironmentObject private var store: RecordStore
    @EnvironmentObject private var cloud: CloudService
    @State private var serial = ""
    @State private var scanning = false
    @State private var path: [UUID] = []
    @State private var error: String?
    @State private var legacyDraftIDs: Set<UUID> = []
    @State private var draftLifecyclePrepared = false
    @AppStorage("codecam.draftLifecycleMigrated") private var draftLifecycleMigrated = false
    @AppStorage("codecam.legacyDraftIDs") private var legacyDraftIDsJSON = "[]"
    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Label(currentSpaceName, systemImage: currentSpaceIsOrganization ? "person.3.fill" : "person.crop.circle.fill").foregroundStyle(.blue)
                    Text("从一个序列号开始，留下每一次现场记录。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section {
                    Button { requestScanner() } label: {
                        Label("扫描产品序列号", systemImage: "barcode.viewfinder")
                            .font(.title3.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 54)
                    }
                    .buttonStyle(.borderedProminent)
                    DisclosureGroup("无法扫码？手动输入") {
                        TextField("输入或粘贴序列号", text: $serial)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("serialInput")
                        Button("确认序列号") { start(serial) }
                            .disabled(serial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } footer: {
                    Text("扫到产品码后直接拍照。组织任务会按序列号自动关联。")
                }
                if !legacyDraftIDs.isEmpty {
                    Section("升级前未完成 · 恢复或放弃") {
                        ForEach(store.records.filter { legacyDraftIDs.contains($0.id) && $0.submittedAt == nil }) { record in
                            VStack(alignment: .leading, spacing: 8) {
                                RecordRow(record: record)
                                HStack {
                                    NavigationLink("恢复这条采集") { RecordDetail(id: record.id) }
                                    Spacer()
                                    Button("放弃", role: .destructive) { discardLegacy(record.id) }
                                }.font(.subheadline)
                            }
                        }
                    }
                }
                Section("最近记录") {
                    let recent = Array(store.records.filter { $0.submittedAt != nil }.prefix(5))
                    if recent.isEmpty { Text("还没有完成的记录").foregroundStyle(.secondary) }
                    ForEach(recent) { record in
                        NavigationLink(value: record.id) { RecordRow(record: record) }
                    }
                }
            }
            .navigationTitle("采集")
            .navigationDestination(for: UUID.self) { RecordDetail(id: $0) }
            .sheet(isPresented: $scanning) {
                CodeScannerView(onScan: { value in scanning = false; start(value) }, onCancel: { scanning = false })
            }
            .errorAlert($error)
            .onAppear(perform: prepareDraftLifecycle)
            .onChange(of: store.records) { _, _ in pruneLegacyDrafts() }
        }
    }
    private func requestScanner() {
        Task { @MainActor in
            if await AVCaptureDevice.requestAccess(for: .video) { scanning = true }
            else { error = "相机权限未开启，请在系统设置中允许相机访问，或手动输入序列号。" }
        }
    }
    private func prepareDraftLifecycle() {
        guard !draftLifecyclePrepared else { return }
        draftLifecyclePrepared = true
        if !draftLifecycleMigrated {
            legacyDraftIDs = Set(store.records.filter { $0.submittedAt == nil }.map(\.id))
            persistLegacyDrafts()
            draftLifecycleMigrated = true
        } else if let data = legacyDraftIDsJSON.data(using: .utf8),
                  let ids = try? JSONDecoder().decode([UUID].self, from: data) {
            legacyDraftIDs = Set(ids)
        }
        try? store.discardUnfinished(except: legacyDraftIDs)
    }
    private func discardLegacy(_ id: UUID) {
        do { try store.discardUnfinished(id); legacyDraftIDs.remove(id); persistLegacyDrafts() }
        catch { self.error = error.localizedDescription }
    }
    private func pruneLegacyDrafts() {
        legacyDraftIDs = Set(legacyDraftIDs.filter { store.record($0)?.submittedAt == nil })
        persistLegacyDrafts()
    }
    private func persistLegacyDrafts() {
        guard let data = try? JSONEncoder().encode(legacyDraftIDs.sorted { $0.uuidString < $1.uuidString }),
              let value = String(data: data, encoding: .utf8) else { return }
        legacyDraftIDsJSON = value
    }
    private func start(_ value: String) {
        do { path.append(try store.create(serial: value)); serial = "" }
        catch { self.error = error.localizedDescription }
    }
    private var currentSpaceName: String {
        guard let id=store.archive.activeSpaceID, let space=cloud.spaces.first(where:{$0.id==id}) else { return "个人空间" }
        return space.name
    }
    private var currentSpaceIsOrganization: Bool {
        guard let id=store.archive.activeSpaceID else { return false }
        return cloud.spaces.first(where:{$0.id==id})?.kind == "organization"
    }
}

struct RecordRow: View {
    @EnvironmentObject private var cloud: CloudService
    @EnvironmentObject private var store: RecordStore
    let record: CaptureRecord
    var body: some View {
        HStack(spacing: 12) {
            PhotoThumbnail(photo: record.photos.first, store: store)
            VStack(alignment: .leading, spacing: 6) {
                Text(record.serial).font(.headline)
                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
                if let space=cloud.spaces.first(where:{$0.id==record.spaceID}), space.kind == "organization" {
                    Text(space.name).font(.caption2).foregroundStyle(.blue)
                }
                if record.taskID != nil { Text("关联任务").font(.caption2).foregroundStyle(.blue) }
                HStack {
                    Text(record.submittedAt == nil ? "草稿 · 已保存本机" : (record.syncedAt != nil ? "已同步" : (record.syncError != nil ? "上传未完成 · 可重试" : "已完成 · 待同步")))
                    Spacer()
                    Label("\(record.photos.count)", systemImage: "photo")
                }.font(.caption).foregroundStyle(record.submittedAt == nil ? .orange : .secondary)
            }
        }.padding(.vertical, 4)
    }
}

private struct PhotoThumbnail: View {
    let photo: Photo?
    let store: RecordStore
    var body: some View {
        Group {
            if let photo, let image = thumbnailImage(photo) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").font(.title3).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary.opacity(0.45))
            }
        }
        .frame(width: 58, height: 58).clipShape(RoundedRectangle(cornerRadius: 9))
        .accessibilityHidden(true)
    }
    private func thumbnailImage(_ photo: Photo) -> UIImage? {
        let url = store.photoURL(photo) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 180
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

struct RecordsView: View {
    @EnvironmentObject private var store: RecordStore
    @State private var search = ""
    var serials: [String] {
        var seen = Set<String>()
        return store.records.filter { $0.submittedAt != nil && (search.isEmpty || $0.serial.localizedStandardContains(search)) }
            .compactMap { seen.insert($0.serial).inserted ? $0.serial : nil }
    }
    var body: some View {
        NavigationStack {
            List {
                ForEach(serials, id: \.self) { serial in
                    NavigationLink {
                        List {
                            ForEach(store.records.filter { $0.serial == serial && $0.submittedAt != nil }) { record in
                                NavigationLink { RecordDetail(id: record.id) } label: { RecordRow(record: record) }
                            }
                        }.navigationTitle(serial).navigationBarTitleDisplayMode(.inline)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 12) {
                                PhotoThumbnail(photo: store.records.first { $0.serial == serial && $0.submittedAt != nil }?.photos.first, store: store)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(serial).font(.headline)
                                    Text("\(store.records.filter { $0.serial == serial && $0.submittedAt != nil }.count) 次采集")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }.navigationTitle("记录")
                .searchable(text: $search, prompt: "搜索序列号")
                .overlay { if serials.isEmpty { ContentUnavailableView("暂无记录", systemImage: "tray", description: Text("采集后可在这里按序列号查看历史。")) } }
        }
    }
}

struct RecordDetail: View {
    @EnvironmentObject private var store: RecordStore
    @EnvironmentObject private var cloud: CloudService
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var note = ""
    @State private var error: String?
    @State private var camera = false
    @State private var selected: PhotosPickerItem?
    @State private var loading = false
    @State private var preview: Photo?
    @State private var confirmDiscard = false
    var body: some View {
        Group {
            if let record = store.record(id) {
                List {
                    Section {
                        Text(record.serial).font(.title2.bold()).textSelection(.enabled)
                        Label("\(spaceName(for: record.spaceID)) · \(record.syncedAt == nil ? "尚未同步" : "已同步")", systemImage: record.syncedAt == nil ? "internaldrive" : "checkmark.icloud")
                            .font(.caption).foregroundStyle(.secondary)
                        if record.taskID != nil { Label("组织任务采集", systemImage: "checklist").font(.caption).foregroundStyle(.blue) }
                        Text(record.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                    }
                    Section("照片（\(record.photos.count)）") {
                        ForEach(record.photos) { photo in
                            Button { preview = photo } label: {
                                if let image = UIImage(contentsOfFile: store.photoURL(photo).path) {
                                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220)
                                } else { Label("照片暂时无法读取", systemImage: "exclamationmark.triangle") }
                            }
                        }
                        if record.submittedAt == nil {
                            Button("拍摄照片", systemImage: "camera") { requestCamera() }.disabled(loading)
                            PhotosPicker(selection: $selected, matching: .images) { Label("从相册添加", systemImage: "photo") }.disabled(loading)
                            if loading { ProgressView("正在保存照片…") }
                        }
                    }
                    Section("备注") {
                        if record.submittedAt == nil {
                            TextField("填写现场情况", text: $note, axis: .vertical)
                                .lineLimit(3...8).accessibilityIdentifier("noteInput")
                                .onChange(of: note) { _, value in updateDraftNote(value) }
                        } else { Text(record.note.isEmpty ? "无备注" : record.note).textSelection(.enabled) }
                    }
                    if record.submittedAt == nil {
                        Section {
                            Button("完成采集") {
                                do {
                                    try store.updateNote(id, note: note)
                                    try store.complete(id)
                                    if shouldSyncOnComplete(record) { Task { await cloud.sync(store: store, recordID: id) } }
                                }
                                catch { self.error = error.localizedDescription }
                            }.disabled(loading)
                        } footer: {
                            if record.taskID != nil { Text("完成后先保存在本机，并尝试上传；服务端确认后任务才会完成。") }
                            else if isOrganizationRecord(record) { Text("完成后先保存在本机，再尝试同步并匹配分配给你的任务。") }
                            else { Text("照片与备注自动保存在本机。完成后记录只读。") }
                        }
                    } else {
                        Section {
                            Label("采集已完成", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            if record.syncedAt == nil {
                                if let reason = record.syncError {
                                    Text(reason).font(.footnote).foregroundStyle(.red)
                                } else if shouldSyncOnComplete(record) {
                                    Text("组织记录正在上传；失败时可在「我的」重试。").font(.footnote).foregroundStyle(.secondary)
                                } else {
                                    Text("到「我的」同步，可在 CamFlow 查看。").font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } else { ContentUnavailableView("记录不存在", systemImage: "doc.questionmark") }
        }.navigationTitle("采集详情").navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(store.record(id)?.submittedAt == nil)
            .toolbar {
                if store.record(id)?.submittedAt == nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("退出") { confirmDiscard = true }
                    }
                }
            }
            .alert("放弃本次采集？", isPresented: $confirmDiscard) {
                Button("放弃并退出", role: .destructive) {
                    do { try store.discardUnfinished(id); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
                Button("继续采集", role: .cancel) {}
            } message: {
                Text("未完成的照片和备注会删除。离开产品现场后，建议不要保留未完成采集。")
            }
            .onAppear { note = store.record(id)?.note ?? "" }
            .sheet(isPresented: $camera) { CameraView { image in camera = false; save(image) } onCancel: { camera = false } }
            .sheet(item: $preview) { photo in
                NavigationStack {
                    Group {
                        if let image = UIImage(contentsOfFile: store.photoURL(photo).path) { Image(uiImage: image).resizable().scaledToFit() }
                        else { Text("照片暂时无法读取") }
                    }.toolbar { Button("关闭") { preview = nil } }
                }
            }
            .onChange(of: selected) { _, item in
                guard let item else { return }
                loading = true
                Task { @MainActor in
                    defer { loading = false; selected = nil }
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { throw StoreError.unavailable }
                        save(image)
                    } catch { self.error = error.localizedDescription }
                }
            }
            .errorAlert($error)
    }
    private func save(_ image: UIImage) {
        let scale = min(1, 2000 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        do {
            guard let data = resized.jpegData(compressionQuality: 0.85) else { throw StoreError.unavailable }
            try store.addPhoto(id, jpeg: data)
        } catch { self.error = error.localizedDescription }
    }
    private func updateDraftNote(_ value: String) {
        guard store.record(id)?.submittedAt == nil else { return }
        do { try store.updateNote(id, note: value) }
        catch { self.error = error.localizedDescription }
    }
    private func requestCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { error = "此设备没有可用相机，可从相册添加照片。"; return }
        Task { @MainActor in
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            if allowed { camera = true } else { error = "相机权限未开启。请到系统设置中允许 CodeCam 使用相机，或从相册添加照片。" }
        }
    }
    private func spaceName(for id: UUID) -> String {
        cloud.spaces.first(where:{$0.id==id})?.name ?? (store.archive.cloudBinding?.spaceID == id ? "个人空间" : "本机空间")
    }
    private func isOrganizationRecord(_ record: CaptureRecord) -> Bool {
        cloud.spaces.contains { $0.id == record.spaceID && $0.kind == "organization" }
    }
    private func shouldSyncOnComplete(_ record: CaptureRecord) -> Bool {
        record.taskID != nil || isOrganizationRecord(record)
    }
}

struct CameraView: UIViewControllerRepresentable {
    let onPhoto: (UIImage) -> Void
    let onCancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController(); picker.sourceType = .camera; picker.delegate = context.coordinator; return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraView
        init(parent: CameraView) { self.parent = parent }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.onCancel() }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onPhoto(image) } else { parent.onCancel() }
        }
    }
}

extension View {
    func errorAlert(_ message: Binding<String?>) -> some View {
        alert("未能完成操作", isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } })) {
            Button("知道了") { message.wrappedValue = nil }
        } message: { Text(message.wrappedValue ?? "") }
    }
}
