import SwiftData
import SwiftUI
import PhotosUI

enum CodeCamAppMode: String {
    case staff = "STAFF"
    case customer = "CUSTOMER"
}

enum CodeCamAppModeStore {
    static let key = "codecam.app-mode"
    static var current: CodeCamAppMode {
        CodeCamAppMode(rawValue: UserDefaults.standard.string(forKey: key) ?? CodeCamAppMode.staff.rawValue) ?? .staff
    }
    static func set(_ mode: CodeCamAppMode) { UserDefaults.standard.set(mode.rawValue, forKey: key) }
}

struct CustomerOrderRow: Identifiable {
    let id: String
    let status: String
    let productNames: String
    let production: String
}

struct CustomerOrderItemRow: Identifiable {
    let id: String
    let productName: String
    let completedQuantity: String
    let totalQuantity: String
    let stageLabel: String
}

struct CustomerOrderDetail {
    let orderId: String
    let status: String
    let items: [CustomerOrderItemRow]
    let receiptRequestIDs: [String]
    let shipments: [String]
}

struct CustomerAftersalesRow: Identifiable {
    let id: String
    let orderID: String
    let category: String
    let status: String
    let description: String
}

@MainActor
enum CustomerPortalService {
    static func orders() async throws -> [CustomerOrderRow] {
        let object = try await EdgeFlowClient.get("/api/v1/me/orders", token: .user)
        let items = object["items"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let id = item["orderId"] as? String else { return nil }
            let products = (item["items"] as? [[String: Any]] ?? []).compactMap { $0["productName"] as? String }.joined(separator: "、")
            let production = (item["productionStatus"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "待排产"
            return CustomerOrderRow(id: id, status: item["status"] as? String ?? "", productNames: products.isEmpty ? "订单产品" : products, production: production)
        }
    }

    static func trace(code: String) async throws -> ProductProfile {
        let object = try await EdgeFlowClient.get("/api/v1/me/code-trace", queryItems: [URLQueryItem(name: "code", value: code)], token: .user)
        guard let payload = object["code"] as? [String: Any] else { throw EdgeFlowServiceError.invalidResponse }
        let fields = (payload["fields"] as? [String: Any] ?? [:]).reduce(into: [String: String]()) { result, pair in result[pair.key] = String(describing: pair.value) }
        return ProductProfile.platform(code: payload["codeValue"] as? String ?? code, productReference: payload["productRef"] as? String ?? "", status: payload["status"] as? String ?? "", fields: fields)
    }

    static func order(id: String) async throws -> CustomerOrderDetail {
        let object = try await EdgeFlowClient.get("/api/v1/orders/\(id)", token: .user)
        let items = (object["items"] as? [[String: Any]] ?? []).compactMap { item -> CustomerOrderItemRow? in
            guard let itemID = item["orderItemId"] as? String else { return nil }
            let progress = item["productionProgress"] as? [String: Any] ?? [:]
            return CustomerOrderItemRow(id: itemID, productName: item["productName"] as? String ?? "订单产品", completedQuantity: progress["completedQuantity"] as? String ?? "0", totalQuantity: progress["totalQuantity"] as? String ?? (item["quantity"] as? String ?? "0"), stageLabel: progress["label"] as? String ?? "待排产")
        }
        let receipts = (object["receiptRequests"] as? [[String: Any]] ?? []).compactMap { $0["receiptId"] as? String }
        let shipments = (object["shipments"] as? [[String: Any]] ?? []).compactMap { $0["status"] as? String }
        return CustomerOrderDetail(orderId: object["orderId"] as? String ?? id, status: object["status"] as? String ?? "", items: items, receiptRequestIDs: receipts, shipments: shipments)
    }

    static func confirmReceipt(id: String) async throws {
        _ = try await EdgeFlowClient.post("/api/v1/receipts/\(id)/confirm", body: ["result": "CONFIRMED"], token: .user)
    }

    static func confirmReceiptOrQueue(id: String, in context: ModelContext) async throws {
        do { try await confirmReceipt(id: id) }
        catch {
            let data = try JSONSerialization.data(withJSONObject: ["id": id])
            context.insert(CustomerPendingAction(action: "RECEIPT_CONFIRM", payloadJSON: String(decoding: data, as: UTF8.self))); try? context.save(); throw error
        }
    }

    static func createAftersales(orderID: String, category: String, description: String) async throws {
        _ = try await EdgeFlowClient.post("/api/v1/aftersales", body: ["orderId": orderID, "category": category, "description": description], token: .user)
    }

    static func createAftersalesOrQueue(orderID: String, category: String, description: String, in context: ModelContext) async throws {
        do { try await createAftersales(orderID: orderID, category: category, description: description) }
        catch {
            let data = try JSONSerialization.data(withJSONObject: ["orderId": orderID, "category": category, "description": description])
            context.insert(CustomerPendingAction(action: "AFTERSALES_CREATE", payloadJSON: String(decoding: data, as: UTF8.self))); try? context.save(); throw error
        }
    }

    static func flushPending(in context: ModelContext) async {
        let actions = (try? context.fetch(FetchDescriptor<CustomerPendingAction>())) ?? []
        for action in actions {
            guard let data = action.payloadJSON.data(using: .utf8), let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            do {
                if action.action == "RECEIPT_CONFIRM", let id = payload["id"] as? String { try await confirmReceipt(id: id) }
                else if action.action == "AFTERSALES_CREATE", let orderID = payload["orderId"] as? String { try await createAftersales(orderID: orderID, category: payload["category"] as? String ?? "其他", description: payload["description"] as? String ?? "") }
                else { continue }
                context.delete(action)
            } catch { continue }
        }
        try? context.save()
    }

    static func aftersales() async throws -> [CustomerAftersalesRow] {
        let object = try await EdgeFlowClient.get("/api/v1/me/aftersales", token: .user)
        return (object["items"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["caseId"] as? String else { return nil }
            return CustomerAftersalesRow(id: id, orderID: item["orderId"] as? String ?? "", category: item["category"] as? String ?? "售后", status: item["status"] as? String ?? "处理中", description: item["description"] as? String ?? "")
        }
    }

    static func confirmAftersales(caseID: String, result: String, note: String) async throws {
        _ = try await EdgeFlowClient.post("/api/v1/me/aftersales/\(caseID)/confirm-result", body: ["result": result, "note": note], token: .user)
    }

    static func uploadEvidence(caseID: String, data: Data, fileName: String, contentType: String) async throws {
        _ = try await EdgeFlowClient.uploadMultipart(path: "/api/v1/me/aftersales/\(caseID)/evidence", fileData: data, fileName: fileName, contentType: contentType, token: .user)
    }

    static func aftersalesDetail(id: String) async throws -> CustomerAftersalesRow {
        let item = try await EdgeFlowClient.get("/api/v1/me/aftersales/\(id)", token: .user)
        return CustomerAftersalesRow(id: id, orderID: item["orderId"] as? String ?? "", category: item["category"] as? String ?? "售后", status: item["status"] as? String ?? "处理中", description: item["description"] as? String ?? "")
    }
}

struct CustomerModeRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var sessions: [UserSessionRecord]
    @State private var scannerPresented = false
    @State private var orders: [CustomerOrderRow] = []
    @State private var aftersales: [CustomerAftersalesRow] = []
    @State private var trace: ProductProfile?
    @State private var selectedOrderID: String?
    @State private var errorMessage: String?

    private var session: UserSessionRecord? { sessions.first }
    private var isAuthenticated: Bool { session?.isAuthenticated == true && session?.contextTypeRaw == CodeCamAppMode.customer.rawValue }

    var body: some View {
        NavigationStack {
            Group {
                if isAuthenticated { customerHome } else { CustomerModeAuthView() }
            }
            .navigationTitle("顾客模式")
            .navigationBarTitleDisplayMode(.large)
            .codeCamPage()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("切换员工模式") {
                        AccountAuthService.logout(in: modelContext)
                        CodeCamAppModeStore.set(.staff)
                    }
                }
            }
            .task(id: isAuthenticated) { if isAuthenticated { await CustomerPortalService.flushPending(in: modelContext); await reload() } }
            .alert("顾客模式", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("知道了", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .sheet(isPresented: $scannerPresented) {
                CodeScannerView(onScan: { value in
                    scannerPresented = false
                    Task { await resolveTrace(value) }
                }, onCancel: { scannerPresented = false }, title: "扫描自己的产品")
            }
            .sheet(item: Binding(get: { selectedOrderID.map(CustomerOrderSelection.init) }, set: { selectedOrderID = $0?.id })) { selection in
                CustomerOrderDetailView(orderID: selection.id)
            }
        }
    }

    private var customerHome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 19) {
                CodeCamGradientHero(
                    eyebrow: session?.displayName ?? "顾客",
                    title: "欢迎回来",
                    subtitle: "产品状态、订单进度与售后服务，一处查询。"
                )

                Button { scannerPresented = true } label: {
                    HStack(spacing: 12) {
                        Text("▥")
                            .font(.title3)
                            .foregroundStyle(CodeCamTheme.blue)
                            .frame(width: 34, height: 34)
                            .background(CodeCamTheme.blueSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("扫描产品码").font(.subheadline.weight(.semibold))
                            Text("快速查看产品档案与采集记录").font(.caption).foregroundStyle(CodeCamTheme.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(CodeCamTheme.muted)
                    }
                    .padding(13)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(CodeCamTheme.line, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)

                if let trace {
                    CodeCamSectionHeader(title: "最近追溯结果")
                    VStack(alignment: .leading, spacing: 10) {
                        ProductIdentityRow(code: trace.serialNumber, productName: trace.productName, productModel: trace.productReference, caption: trace.status)
                        ForEach(trace.fields) { field in LabeledContent(field.name, value: field.value).font(.caption) }
                    }.codeCamCard()
                }

                CodeCamSectionHeader(title: "我的订单")
                if orders.isEmpty {
                    Text("暂无已授权订单").font(.subheadline).foregroundStyle(CodeCamTheme.muted).codeCamCard()
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(orders.enumerated()), id: \.element.id) { index, order in
                            Button { selectedOrderID = order.id } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 5) {
                                        StatusCapsule(title: order.status.isEmpty ? "处理中" : order.status, tint: CodeCamTheme.green)
                                        Text(order.productNames).font(.subheadline.weight(.semibold))
                                        Text(orderSummary(order)).font(.caption).foregroundStyle(CodeCamTheme.muted)
                                    }
                                    Spacer(); Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(CodeCamTheme.muted)
                                }.padding(.vertical, 8)
                            }.buttonStyle(.plain)
                            if index < orders.count - 1 { Divider() }
                        }
                    }.codeCamCard(padding: 12)
                }

                CodeCamSectionHeader(title: "售后服务")
                if aftersales.isEmpty {
                    Text("暂无售后记录").font(.subheadline).foregroundStyle(CodeCamTheme.muted).codeCamCard()
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(aftersales.enumerated()), id: \.element.id) { index, item in
                            NavigationLink { CustomerAftersalesDetailView(item: item) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.category).font(.subheadline.weight(.semibold))
                                    Text("订单 \(item.orderID.prefix(8)) · \(item.status)").font(.caption).foregroundStyle(CodeCamTheme.muted)
                                    if !item.description.isEmpty { Text(item.description).font(.caption).foregroundStyle(CodeCamTheme.muted).lineLimit(2) }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                            }
                            if index < aftersales.count - 1 { Divider() }
                        }
                    }.codeCamCard(padding: 12)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .refreshable { await reload() }
    }

    private func reload() async {
        do {
            async let orderResult = CustomerPortalService.orders()
            async let aftersalesResult = CustomerPortalService.aftersales()
            orders = try await orderResult
            aftersales = try await aftersalesResult
        } catch { errorMessage = error.localizedDescription }
    }

    private func resolveTrace(_ code: String) async {
        do { trace = try await CustomerPortalService.trace(code: code) } catch { errorMessage = error.localizedDescription }
    }

    private func orderSummary(_ order: CustomerOrderRow) -> String {
        let status = order.status.isEmpty ? "处理中" : order.status
        return "订单 \(order.id.prefix(8)) · \(status) · \(order.production)"
    }
}

private struct CustomerOrderSelection: Identifiable { let id: String }

private struct CustomerOrderDetailView: View {
    let orderID: String
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var detail: CustomerOrderDetail?
    @State private var errorMessage: String?
    @State private var confirming = false
    @State private var confirmed = false

    var body: some View {
        NavigationStack {
            List {
                if let detail {
                    Section("订单状态") {
                        LabeledContent("订单号", value: detail.orderId)
                        LabeledContent("状态", value: detail.status.isEmpty ? "处理中" : detail.status)
                    }
                    Section("生产进度") {
                        ForEach(detail.items) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.productName).font(.headline)
                                Text("数量 \(item.completedQuantity)/\(item.totalQuantity) · \(item.stageLabel)").font(.subheadline).foregroundStyle(.secondary)
                                ProgressView(value: Double(item.completedQuantity) ?? 0, total: max(Double(item.totalQuantity) ?? 1, 1))
                            }.padding(.vertical, 3)
                        }
                    }
                    if !detail.shipments.isEmpty {
                        Section("物流") { ForEach(detail.shipments, id: \.self) { Text($0) } }
                    }
                    if let receiptID = detail.receiptRequestIDs.first, !confirmed {
                        Section {
                            Button(confirming ? "提交中…" : "确认收货") {
                                confirming = true
                                Task {
                                    do { try await CustomerPortalService.confirmReceiptOrQueue(id: receiptID, in: modelContext); confirmed = true }
                                    catch { errorMessage = error.localizedDescription }
                                    confirming = false
                                }
                            }.disabled(confirming)
                        } footer: { Text("确认后工厂将收到收货结果。") }
                    } else if confirmed {
                        Section { Label("已确认收货", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    }
                    Section("售后服务") {
                        NavigationLink("申请售后") { CustomerAftersalesForm(orderID: detail.orderId) }
                    }
                } else { ProgressView("加载订单详情…") }
            }
            .navigationTitle("订单详情")
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } } }
            .task { do { detail = try await CustomerPortalService.order(id: orderID) } catch { errorMessage = error.localizedDescription } }
            .alert("订单详情", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("知道了", role: .cancel) {} } message: { Text(errorMessage ?? "") }
        }
    }
}

private struct CustomerAftersalesForm: View {
    let orderID: String
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var category = "质量问题"
    @State private var description = ""
    @State private var submitting = false
    @State private var message: String?

    var body: some View {
        Form {
            Section("问题类型") {
                Picker("类型", selection: $category) {
                    Text("质量问题").tag("质量问题")
                    Text("物流损坏").tag("物流损坏")
                    Text("安装服务").tag("安装服务")
                    Text("其他").tag("其他")
                }
            }
            Section("问题描述") { TextEditor(text: $description).frame(minHeight: 120) }
            Button(submitting ? "提交中…" : "提交售后申请") {
                submitting = true
                Task {
                    do { try await CustomerPortalService.createAftersalesOrQueue(orderID: orderID, category: category, description: description, in: modelContext); message = "申请已提交" }
                    catch { message = error.localizedDescription }
                    submitting = false
                }
            }.disabled(submitting || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .navigationTitle("申请售后")
        .alert("售后申请", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("完成") { if message == "申请已提交" { dismiss() } }
        } message: { Text(message ?? "") }
    }
}

private struct CustomerAftersalesDetailView: View {
    let item: CustomerAftersalesRow
    @State private var note = ""
    @State private var message: String?
    @State private var submitting = false
    @State private var photo: PhotosPickerItem?
    @State private var uploaded = false

    var body: some View {
        Form {
            Section("售后信息") {
                LabeledContent("类型", value: item.category)
                LabeledContent("订单", value: String(item.orderID.prefix(12)))
                LabeledContent("状态", value: item.status)
                Text(item.description)
            }
            if item.status.uppercased().contains("WAIT") || item.status.contains("确认") || item.status.contains("完成") {
                Section("服务结果") {
                    TextField("补充意见（可选）", text: $note)
                    HStack {
                        Button("满意") { submit("SATISFIED") }
                        Button("不满意") { submit("DISSATISFIED") }
                    }.disabled(submitting)
                }
            }
            Section("问题证据") {
                PhotosPicker(selection: $photo, matching: .any(of: [.images, .videos])) { Label("选择照片或视频上传", systemImage: "paperclip") }
                if uploaded { Label("证据已上传", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            }
        }
        .navigationTitle("售后详情")
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                do {
                    let data = try await item.loadTransferable(type: Data.self)
                    if let data { try await CustomerPortalService.uploadEvidence(caseID: self.item.id, data: data, fileName: "evidence-\(UUID().uuidString).jpg", contentType: "image/jpeg"); uploaded = true }
                } catch { message = error.localizedDescription }
            }
        }
        .alert("售后服务", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("知道了", role: .cancel) {} } message: { Text(message ?? "") }
    }

    private func submit(_ result: String) {
        submitting = true
        Task {
            do { try await CustomerPortalService.confirmAftersales(caseID: item.id, result: result, note: note); message = "服务结果已提交" }
            catch { message = error.localizedDescription }
            submitting = false
        }
    }
}

private struct CustomerModeAuthView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var username = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var register = false
    @State private var errorMessage: String?
    @State private var working = false

    var body: some View {
        Form {
            Section("顾客账号") {
                Picker("操作", selection: $register) { Text("登录").tag(false); Text("注册").tag(true) }.pickerStyle(.segmented)
                if register { TextField("姓名或称呼", text: $displayName) }
                TextField("手机号、邮箱或账号", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("密码", text: $password)
                Button(working ? "正在处理…" : (register ? "注册并进入顾客模式" : "登录顾客模式")) { submit() }.disabled(working)
            }
            Section { Text("顾客模式不需要工厂设备登记；接受工厂邀请后才能查看订单和产品。").font(.footnote).foregroundStyle(.secondary) }
        }
        .alert("无法进入顾客模式", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("知道了", role: .cancel) {} } message: { Text(errorMessage ?? "") }
    }

    private func submit() {
        working = true
        Task {
            defer { working = false }
            do {
                if register { try await AccountAuthService.register(username: username, password: password, displayName: displayName, contextType: "CUSTOMER", in: modelContext) }
                else { try await AccountAuthService.login(username: username, password: password, contextType: "CUSTOMER", in: modelContext) }
                CodeCamAppModeStore.set(.customer)
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
