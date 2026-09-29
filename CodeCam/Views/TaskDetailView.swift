import SwiftData
import SwiftUI

struct TaskDetailView: View {
    @Query private var items: [ExecutionItem]
    @Query private var drafts: [TaskDraft]
    @Query private var allItems: [ExecutionItem]

    let itemID: String
    let onOpenCapture: (String) -> Void

    private var item: ExecutionItem? { items.first { $0.id == itemID } }
    private var draft: TaskDraft? { guard let item else { return nil }; return drafts.first { $0.id == item.draftID } }

    private var listItems: [ExecutionItem] {
        guard let item else { return [] }
        return allItems.filter { $0.listID == item.listID }
    }

    private var completedInList: Int {
        listItems.filter { $0.state == .synced || $0.state == .skipped }.count
    }

    var body: some View {
        Group {
            if let item, let draft {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        CodeCamDetailHero(
                            tag: item.state.title,
                            tagStyle: item.state.isOutstanding ? .blue : .mint,
                            title: draft.title,
                            subtitle: "CodeCam 本地 SN 任务"
                        )

                        CodeCamKeyValueList {
                            CodeCamKeyValueRow(
                                label: "执行范围",
                                value: "\(listItems.count) 个 SN，已完成 \(completedInList) 个"
                            )
                            CodeCamKeyValueRow(label: "当前 SN", value: item.codeValue)
                            CodeCamKeyValueRow(
                                label: "采集规则",
                                value: item.requirementSummary.isEmpty ? "扫码后按产品规则执行" : item.requirementSummary
                            )
                        }

                        CodeCamSectionHeader(
                            title: "执行进度",
                            trailing: "\(completedInList) / \(listItems.count)"
                        )
                        CodeCamProgressLine(
                            progress: CodeCamProgressMath.fraction(completed: completedInList, total: max(listItems.count, 1))
                        )
                        .padding(.horizontal, 2)

                        ProductIdentityRow(
                            code: item.codeValue,
                            productName: item.productName,
                            productModel: item.productModel
                        )
                        .codeCamCard()

                        if let notice = item.changeNotice, !notice.isEmpty {
                            CodeCamNoteCard(bodyText: notice)
                        } else {
                            CodeCamNoteCard(bodyText: "扫描 SN 后按产品规则采集；不在清单内的 SN 不可加入本任务。")
                        }

                        if item.state.isOutstanding {
                            CodeCamPrimaryButton(
                                title: item.state == .inProgress ? "继续采集" : "扫码开始采集",
                                subtitle: nil,
                                icon: "barcode.viewfinder"
                            ) {
                                onOpenCapture(item.id)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .codeCamPage()
            } else {
                ContentUnavailableView("任务不存在", systemImage: "exclamationmark.triangle")
                    .codeCamPage()
            }
        }
        .navigationTitle("任务详情")
        .navigationBarTitleDisplayMode(.inline)
    }
}
