import SwiftUI
import UIKit

/// CodeCam's visual source of truth. New screens should compose these tokens and
/// components instead of introducing page-specific colors, radii, or controls.
enum CodeCamTheme {
    static let blue = Color(red: 23 / 255, green: 104 / 255, blue: 229 / 255)
    static let ink = Color(red: 21 / 255, green: 32 / 255, blue: 51 / 255)
    static let muted = Color(red: 113 / 255, green: 128 / 255, blue: 150 / 255)
    static let canvas = Color(red: 243 / 255, green: 245 / 255, blue: 248 / 255)
    static let line = Color(red: 230 / 255, green: 234 / 255, blue: 240 / 255)
    static let green = Color(red: 21 / 255, green: 129 / 255, blue: 95 / 255)
    static let orange = Color(red: 201 / 255, green: 119 / 255, blue: 0 / 255)
    static let blueSoft = Color(red: 234 / 255, green: 242 / 255, blue: 255 / 255)
    static let cardBorder = Color(red: 237 / 255, green: 240 / 255, blue: 244 / 255)
    static let accentBorder = Color(red: 223 / 255, green: 232 / 255, blue: 245 / 255)
    static let metricFill = Color(red: 246 / 255, green: 248 / 255, blue: 251 / 255)
    static let pendingFill = Color(red: 237 / 255, green: 244 / 255, blue: 255 / 255)
    static let uploadingFill = Color(red: 255 / 255, green: 245 / 255, blue: 228 / 255)
    static let noteFill = Color(red: 247 / 255, green: 249 / 255, blue: 252 / 255)
    static let searchFill = Color(red: 233 / 255, green: 237 / 255, blue: 242 / 255)
    static let syncBannerFill = Color(red: 237 / 255, green: 245 / 255, blue: 255 / 255)
    static let cardRadius: CGFloat = 16
    static let listCardRadius: CGFloat = 15

    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [blue, Color(red: 76 / 255, green: 147 / 255, blue: 245 / 255)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// Semantic fonts aligned with pre-redesign screens (body / subheadline / headline),
/// not the HTML prototype’s 10–12pt fixed sizes.
enum CodeCamTypography {
    static let sectionTitle = Font.headline.weight(.semibold)
    static let sectionMeta = Font.subheadline
    static let cardTitle = Font.headline.weight(.semibold)
    static let cardSubtitle = Font.subheadline
    static let listTitle = Font.subheadline.weight(.semibold)
    static let listBody = Font.body
    static let listSecondary = Font.subheadline
    static let listMeta = Font.footnote
    static let listBadge = Font.footnote.weight(.semibold)
    static let metricLarge = Font.title2.weight(.bold)
    static let metricMedium = Font.title3.weight(.bold)
    static let metricCaption = Font.footnote
    static let filterChip = Font.subheadline
    static let textAction = Font.subheadline
    static let hero = Font.title.weight(.bold)
    static let heroLarge = Font.largeTitle.weight(.bold)
    static let profileName = Font.title3.weight(.semibold)
    static let profileInitial = Font.title2.weight(.bold)
    static let scanCode = Font.body.weight(.semibold).monospaced()
    static let scanProduct = Font.subheadline
    static let scanMeta = Font.footnote
    static let scanState = Font.footnote.weight(.semibold)
    static let kvLabel = Font.subheadline
    static let kvValue = Font.subheadline.weight(.medium)
    static let note = Font.body
    static let noteTime = Font.caption.weight(.semibold)
    static let productName = Font.headline.weight(.semibold)
    static let bottomBar = Font.subheadline
    static let bottomBarPrimary = Font.subheadline.weight(.bold)
    static let status = Font.subheadline
}

enum CodeCamProgressMath {
    static func fraction(completed: Int, total: Int) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    static func percentText(completed: Int, total: Int) -> String {
        let value = Int((fraction(completed: completed, total: total) * 100).rounded())
        return "\(value)%"
    }
}

extension View {
    func codeCamCard(padding: CGFloat = 14) -> some View {
        self.padding(.all, padding)
            .background(.white, in: RoundedRectangle(cornerRadius: CodeCamTheme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: CodeCamTheme.cardRadius, style: .continuous)
                    .stroke(CodeCamTheme.line.opacity(0.8), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.025), radius: 8, y: 3)
    }

    func codeCamPage() -> some View {
        tint(CodeCamTheme.blue)
            .foregroundStyle(CodeCamTheme.ink)
            .scrollContentBackground(.hidden)
            .background(CodeCamTheme.canvas)
            .toolbarBackground(CodeCamTheme.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }

    /// Prototype `list-card`: grouped rows with shared border and no outer padding.
    func codeCamListCard() -> some View {
        background(.white, in: RoundedRectangle(cornerRadius: CodeCamTheme.listCardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: CodeCamTheme.listCardRadius, style: .continuous)
                    .stroke(CodeCamTheme.cardBorder, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: CodeCamTheme.listCardRadius, style: .continuous))
            .shadow(color: Color.black.opacity(0.035), radius: 12, y: 3)
    }
}

struct CodeCamSectionHeader: View {
    let title: String
    var trailing: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var compactTopSpacing: Bool = false

    var body: some View {
        HStack {
            Text(title).font(CodeCamTypography.sectionTitle)
            Spacer()
            if let actionTitle, let action {
                CodeCamPlainButton(title: actionTitle, action: action)
            } else if let trailing {
                Text(trailing).font(CodeCamTypography.sectionMeta).foregroundStyle(CodeCamTheme.muted)
            }
        }
        .padding(.horizontal, 2)
        .padding(.top, compactTopSpacing ? 4 : 0)
    }
}

struct CodeCamPrimaryButton: View {
    let title: String
    var subtitle: String? = nil
    var icon: String? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.title2.weight(.semibold)) }
                Text(title).font(.headline.weight(.semibold))
                if let subtitle { Text(subtitle).font(CodeCamTypography.listMeta).opacity(0.82) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, subtitle == nil ? 14 : 19)
            .foregroundStyle(.white)
            .background(CodeCamTheme.blue, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .shadow(color: CodeCamTheme.blue.opacity(0.2), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
    }
}

struct CodeCamMetric: View {
    let value: Int
    let title: String
    var tint: Color = CodeCamTheme.ink

    var body: some View {
        VStack(spacing: 3) {
            Text("\(value)").font(CodeCamTypography.metricMedium.monospacedDigit()).foregroundStyle(tint)
            Text(title).font(CodeCamTypography.metricCaption).foregroundStyle(CodeCamTheme.muted)
        }
        .frame(maxWidth: .infinity)
    }
}

struct CodeCamStatusDot: View {
    var tint: Color = CodeCamTheme.green

    var body: some View {
        Circle().fill(tint).frame(width: 7, height: 7)
            .shadow(color: tint.opacity(0.25), radius: 0, x: 0, y: 0)
    }
}

struct CodeCamGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            configuration.label
                .font(.subheadline.weight(.semibold))
            configuration.content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .codeCamCard()
    }
}

struct StatusCapsule: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(CodeCamTypography.listBadge)
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(tint.opacity(0.11), in: Capsule())
    }
}

struct CountBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(CodeCamTypography.listBadge.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(CodeCamTheme.blue, in: Capsule())
        }
    }
}

struct ProductIdentityRow: View {
    let code: String
    var productName: String?
    var productModel: String?
    var caption: String?
    var thumbnail: UIImage?
    var showsThumbnailSlot: Bool = false

    private var productLine: String {
        let text = [productName, productModel].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return text.isEmpty ? "产品资料待获取" : text
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if showsThumbnailSlot {
                Image(systemName: "photo")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 48, height: 48)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(code)
                    .font(.body.monospaced())
                    .foregroundStyle(.primary)
                Text(productLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let caption, !caption.isEmpty {
                    Text(caption)
                        .font(CodeCamTypography.listMeta)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

struct SyncStateBadge: View {
    let state: SyncState
    var body: some View { StatusCapsule(title: state.title, tint: state.tint) }
}

struct DeviceStateBadge: View {
    let state: DeviceConnectionState
    var body: some View { StatusCapsule(title: state.title, tint: state.tint) }
}

// MARK: - Prototype-aligned controls

struct CodeCamPlainButton: View {
    let title: String
    var action: () -> Void

    var body: some View {
        Button(title, action: action)
            .font(CodeCamTypography.textAction)
            .foregroundStyle(CodeCamTheme.blue)
            .buttonStyle(.plain)
    }
}

struct CodeCamOutlineButton: View {
    let title: String
    var action: () -> Void

    var body: some View {
        Button(title, action: action)
            .font(CodeCamTypography.textAction.weight(.semibold))
            .foregroundStyle(CodeCamTheme.blue)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color(red: 169 / 255, green: 201 / 255, blue: 250 / 255), lineWidth: 1)
            }
            .buttonStyle(.plain)
    }
}

enum CodeCamTagStyle {
    case blue, mint

    var foreground: Color {
        switch self {
        case .blue: Color(red: 18 / 255, green: 89 / 255, blue: 195 / 255)
        case .mint: Color(red: 18 / 255, green: 108 / 255, blue: 80 / 255)
        }
    }

    var background: Color {
        switch self {
        case .blue: Color(red: 233 / 255, green: 242 / 255, blue: 255 / 255)
        case .mint: Color(red: 232 / 255, green: 247 / 255, blue: 241 / 255)
        }
    }
}

struct CodeCamTag: View {
    let title: String
    var style: CodeCamTagStyle = .blue

    var body: some View {
        Text(title)
            .font(CodeCamTypography.listBadge)
            .foregroundStyle(style.foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(style.background, in: Capsule())
    }
}

struct CodeCamProgressLine: View {
    var progress: Double
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(red: 229 / 255, green: 235 / 255, blue: 244 / 255))
                Capsule()
                    .fill(CodeCamTheme.blue)
                    .frame(width: max(0, proxy.size.width * min(1, max(0, progress))))
            }
        }
        .frame(height: height)
    }
}

enum CodeCamMetricTileStyle {
    case neutral, pending, uploading

    var valueColor: Color {
        switch self {
        case .neutral: CodeCamTheme.ink
        case .pending: CodeCamTheme.blue
        case .uploading: CodeCamTheme.orange
        }
    }

    var background: Color {
        switch self {
        case .neutral: CodeCamTheme.metricFill
        case .pending: CodeCamTheme.pendingFill
        case .uploading: CodeCamTheme.uploadingFill
        }
    }
}

struct CodeCamMetricTile: View {
    let value: Int
    let title: String
    var style: CodeCamMetricTileStyle = .neutral

    var body: some View {
        VStack(spacing: 3) {
            Text("\(value)")
                .font(CodeCamTypography.metricMedium.monospacedDigit())
                .foregroundStyle(style.valueColor)
            Text(title)
                .font(CodeCamTypography.metricCaption)
                .foregroundStyle(CodeCamTheme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 5)
        .background(style.background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct CodeCamTaskSummaryCard: View {
    let stationTitle: String
    var taskLabel: String = "今日任务"
    let pending: Int
    let completed: Int
    let uploading: Int
    var progress: Double? = nil
    var showsChevron: Bool = true

    private var resolvedProgress: Double {
        if let progress { return progress }
        return CodeCamProgressMath.fraction(completed: completed, total: pending + completed + uploading)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                Text(stationTitle)
                    .font(CodeCamTypography.cardTitle)
                    .foregroundStyle(CodeCamTheme.ink)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(CodeCamTheme.muted)
                }
            }
            Text(taskLabel)
                .font(CodeCamTypography.cardSubtitle)
                .foregroundStyle(CodeCamTheme.muted)
            HStack(spacing: 7) {
                CodeCamMetricTile(value: pending, title: "待扫码", style: .pending)
                CodeCamMetricTile(value: completed, title: "已完成", style: .neutral)
                CodeCamMetricTile(value: uploading, title: "待上传", style: .uploading)
            }
            CodeCamProgressLine(progress: resolvedProgress)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(CodeCamTheme.accentBorder, lineWidth: 1)
        }
    }
}

struct CodeCamCompactTaskBar: View {
    let taskTitle: String

    var body: some View {
        HStack(spacing: 8) {
            Text("当前任务")
                .font(CodeCamTypography.listMeta)
                .foregroundStyle(CodeCamTheme.muted)
            Text(taskTitle)
                .font(CodeCamTypography.listTitle)
                .foregroundStyle(CodeCamTheme.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(CodeCamTheme.muted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(CodeCamTheme.accentBorder, lineWidth: 1)
        }
    }
}

struct CodeCamWelcomeHeader: View {
    let greeting: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting)
                .font(CodeCamTypography.cardSubtitle)
                .foregroundStyle(CodeCamTheme.muted)
            Text(title)
                .font(CodeCamTypography.heroLarge)
                .foregroundStyle(CodeCamTheme.ink)
            Text(subtitle)
                .font(CodeCamTypography.listMeta)
                .foregroundStyle(CodeCamTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CodeCamTaskOverviewStrip: View {
    let pending: Int
    let completed: Int
    let uploading: Int
    var progressLabel: String? = nil

    private var progressText: String {
        progressLabel ?? CodeCamProgressMath.percentText(
            completed: completed,
            total: pending + completed + uploading
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            overviewCell(value: pending, title: "待扫码", highlight: true)
            divider
            overviewCell(value: completed, title: "已完成", highlight: false)
            divider
            overviewCell(value: uploading, title: "待上传", highlight: false)
            VStack(alignment: .trailing, spacing: 2) {
                Text(progressText)
                    .font(CodeCamTypography.metricMedium)
                    .foregroundStyle(CodeCamTheme.blue)
                Text("任务进度")
                    .font(CodeCamTypography.metricCaption)
                    .foregroundStyle(CodeCamTheme.muted)
            }
            .padding(.leading, 10)
        }
        .padding(13)
        .codeCamCard()
    }

    private var divider: some View {
        Rectangle()
            .fill(CodeCamTheme.line)
            .frame(width: 1, height: 36)
    }

    private func overviewCell(value: Int, title: String, highlight: Bool) -> some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(CodeCamTypography.metricLarge.monospacedDigit())
                .foregroundStyle(highlight ? CodeCamTheme.blue : CodeCamTheme.ink)
            Text(title)
                .font(CodeCamTypography.metricCaption)
                .foregroundStyle(CodeCamTheme.muted)
        }
        .frame(maxWidth: .infinity)
    }
}

struct CodeCamAssignedTaskCard: View {
    var tagTitle: String = "执行中"
    var deviceCaption: String?
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                CodeCamTag(title: tagTitle, style: .blue)
                Spacer()
                if let deviceCaption {
                    Text(deviceCaption)
                        .font(CodeCamTypography.listMeta)
                        .foregroundStyle(CodeCamTheme.muted)
                }
            }
            Text(title)
                .font(CodeCamTypography.cardTitle)
                .padding(.top, 12)
            Text(subtitle)
                .font(CodeCamTypography.listMeta)
                .foregroundStyle(CodeCamTheme.muted)
                .padding(.top, 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(CodeCamTheme.accentBorder, lineWidth: 1)
        }
    }
}

struct CodeCamWorkEntryRow: View {
    let icon: String
    let title: String
    let subtitle: String
    var trailing: String
    var isComplete: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isComplete ? Color(red: 232 / 255, green: 247 / 255, blue: 241 / 255) : CodeCamTheme.blueSoft)
                    .frame(width: 29, height: 29)
                Image(systemName: icon)
                    .font(CodeCamTypography.listTitle)
                    .foregroundStyle(isComplete ? CodeCamTheme.green : CodeCamTheme.blue)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(CodeCamTypography.listTitle)
                Text(subtitle).font(CodeCamTypography.listSecondary).foregroundStyle(CodeCamTheme.muted)
            }
            Spacer()
            Text(trailing)
                .font(CodeCamTypography.listMeta.weight(.medium))
                .foregroundStyle(CodeCamTheme.muted)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CodeCamSearchBar: View {
    @Binding var text: String
    var placeholder: String = "搜索"
    var showsScanButton: Bool = false
    var onScan: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color(red: 125 / 255, green: 135 / 255, blue: 150 / 255))
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(CodeCamTypography.listBody)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(CodeCamTheme.muted)
                }
                .buttonStyle(.plain)
            }
            if showsScanButton {
                Button {
                    onScan?()
                } label: {
                    Image(systemName: "barcode.viewfinder")
                        .font(.title3.weight(.semibold))
                        .frame(width: 30, height: 28)
                        .background(.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .foregroundStyle(CodeCamTheme.blue)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("扫码搜索")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(CodeCamTheme.searchFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct CodeCamFilterChip: View {
    let title: String
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(CodeCamTypography.filterChip)
                .foregroundStyle(isSelected ? CodeCamTheme.blue : Color(red: 101 / 255, green: 113 / 255, blue: 131 / 255))
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(
                    isSelected ? CodeCamTheme.blueSoft : CodeCamTheme.searchFill,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }
}

enum CodeCamScanThumbPalette: Int, CaseIterable {
    case a, b, c, d, e

    var gradient: LinearGradient {
        switch self {
        case .a:
            LinearGradient(colors: [Color(red: 220 / 255, green: 239 / 255, blue: 227 / 255), Color(red: 169 / 255, green: 200 / 255, blue: 142 / 255)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .b:
            LinearGradient(colors: [Color(red: 216 / 255, green: 232 / 255, blue: 255 / 255), Color(red: 123 / 255, green: 176 / 255, blue: 220 / 255)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .c:
            LinearGradient(colors: [Color(red: 233 / 255, green: 220 / 255, blue: 255 / 255), Color(red: 188 / 255, green: 157 / 255, blue: 206 / 255)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .d:
            LinearGradient(colors: [Color(red: 255 / 255, green: 232 / 255, blue: 201 / 255), Color(red: 217 / 255, green: 173 / 255, blue: 108 / 255)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .e:
            LinearGradient(colors: [Color(red: 221 / 255, green: 231 / 255, blue: 212 / 255), Color(red: 158 / 255, green: 175 / 255, blue: 143 / 255)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    static func forIndex(_ index: Int) -> CodeCamScanThumbPalette {
        let all = allCases
        return all[index % all.count]
    }
}

struct CodeCamScanThumbnail: View {
    var palette: CodeCamScanThumbPalette = .a
    var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(palette.gradient)
            }
        }
        .frame(width: 46, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

struct CodeCamScanRow: View {
    let serial: String
    var productName: String?
    var productModel: String?
    var mediaSummary: String?
    var stateTitle: String
    var timeCaption: String
    var palette: CodeCamScanThumbPalette = .a
    var thumbnail: UIImage?

    private var productLine: String {
        let text = [productName, productModel].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return text.isEmpty ? "产品资料待获取" : text
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            CodeCamScanThumbnail(palette: palette, image: thumbnail)
            VStack(alignment: .leading, spacing: 4) {
                Text(serial)
                    .font(CodeCamTypography.scanCode)
                    .lineLimit(1)
                Text(productLine)
                    .font(CodeCamTypography.scanProduct)
                    .foregroundStyle(CodeCamTheme.muted)
                    .lineLimit(1)
                if let mediaSummary, !mediaSummary.isEmpty {
                    Text(mediaSummary)
                        .font(CodeCamTypography.scanMeta)
                        .foregroundStyle(Color(red: 137 / 255, green: 148 / 255, blue: 162 / 255))
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 5) {
                Text(stateTitle)
                    .font(CodeCamTypography.scanState)
                    .foregroundStyle(CodeCamTheme.green)
                Text(timeCaption)
                    .font(CodeCamTypography.scanMeta)
                    .foregroundStyle(Color(red: 139 / 255, green: 150 / 255, blue: 165 / 255))
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CodeCamOnlineStatus: View {
    var title: String = "在线"
    var isOnline: Bool = true

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isOnline ? CodeCamTheme.green : CodeCamTheme.muted)
                .frame(width: 6, height: 6)
            Text(title)
                .font(CodeCamTypography.status)
                .foregroundStyle(isOnline ? CodeCamTheme.green : CodeCamTheme.muted)
        }
    }
}

struct CodeCamOfflineCaptureStatus: View {
    var body: some View {
        HStack(spacing: 7) {
            CodeCamStatusDot()
            Text("支持离线扫码")
                .font(CodeCamTypography.listTitle)
            Text("网络恢复后将自动上传")
                .font(CodeCamTypography.listMeta)
                .foregroundStyle(CodeCamTheme.muted)
        }
        .frame(maxWidth: .infinity)
    }
}

struct CodeCamRecordSummaryLine: View {
    let leading: String
    let trailing: String

    var body: some View {
        HStack {
            Text(leading).font(CodeCamTypography.listMeta).foregroundStyle(CodeCamTheme.muted)
            Spacer()
            Text(trailing).font(CodeCamTypography.listMeta).foregroundStyle(CodeCamTheme.muted)
        }
        .padding(.horizontal, 2)
    }
}

struct CodeCamDateSectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(CodeCamTypography.sectionMeta.weight(.semibold))
            .foregroundStyle(Color(red: 102 / 255, green: 115 / 255, blue: 134 / 255))
            .padding(.horizontal, 2)
            .padding(.top, 4)
    }
}

struct CodeCamDetailHero: View {
    var tag: String?
    var tagStyle: CodeCamTagStyle = .blue
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let tag {
                CodeCamTag(title: tag, style: tagStyle)
            }
            Text(title)
                .font(CodeCamTypography.hero)
                .foregroundStyle(CodeCamTheme.ink)
            if let subtitle {
                Text(subtitle)
                    .font(CodeCamTypography.cardSubtitle)
                    .foregroundStyle(CodeCamTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }
}

struct CodeCamNoteCard: View {
    var timeCaption: String?
    let bodyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let timeCaption {
                Text(timeCaption)
                    .font(CodeCamTypography.noteTime)
                    .foregroundStyle(CodeCamTheme.blue)
            }
            Text(bodyText)
                .font(CodeCamTypography.note)
                .foregroundStyle(Color(red: 73 / 255, green: 85 / 255, blue: 102 / 255))
                .lineSpacing(3)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CodeCamTheme.noteFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct CodeCamKeyValueRow: View {
    let label: String
    let value: String
    var valueColor: Color = CodeCamTheme.ink

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(label)
                .font(CodeCamTypography.kvLabel)
                .foregroundStyle(CodeCamTheme.muted)
                .frame(width: 72, alignment: .leading)
            Spacer(minLength: 0)
            Text(value)
                .font(CodeCamTypography.kvValue)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(valueColor)
        }
        .padding(.vertical, 11)
    }
}

struct CodeCamKeyValueList<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, 14)
        .codeCamListCard()
    }
}

struct CodeCamConfigStatusBanner: View {
    let title: String
    let subtitle: String
    var systemImage: String? = nil
    var showsOnlineDot: Bool = true

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            if let systemImage {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(CodeCamTheme.blueSoft)
                        .frame(width: 28, height: 28)
                    Image(systemName: systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CodeCamTheme.blue)
                }
            } else if showsOnlineDot {
                CodeCamStatusDot()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(CodeCamTypography.listTitle)
                Text(subtitle).font(CodeCamTypography.listMeta).foregroundStyle(CodeCamTheme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(CodeCamTheme.syncBannerFill, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

struct CodeCamGradientHero: View {
    let eyebrow: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(eyebrow)
                .font(CodeCamTypography.listMeta)
                .opacity(0.84)
            Text(title)
                .font(CodeCamTypography.hero)
            Text(subtitle)
                .font(CodeCamTypography.cardSubtitle)
                .opacity(0.92)
                .lineSpacing(3)
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CodeCamTheme.brandGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct CodeCamStorageHero: View {
    let title: String
    let value: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(CodeCamTypography.listMeta).opacity(0.84)
            Text(value).font(CodeCamTypography.heroLarge)
            Text(subtitle).font(CodeCamTypography.listMeta).opacity(0.84)
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CodeCamTheme.brandGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct CodeCamSyncSummaryCard: View {
    let title: String
    let value: String
    let subtitle: String
    var buttonTitle: String = "查看"
    var action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(CodeCamTypography.listMeta).foregroundStyle(Color(red: 96 / 255, green: 113 / 255, blue: 139 / 255))
                Text(value).font(CodeCamTypography.cardTitle)
                Text(subtitle).font(CodeCamTypography.listMeta).foregroundStyle(CodeCamTheme.muted)
            }
            Spacer()
            CodeCamOutlineButton(title: buttonTitle, action: action)
        }
        .padding(14)
        .background(CodeCamTheme.syncBannerFill, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

struct CodeCamSettingsRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(CodeCamTheme.blueSoft)
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CodeCamTheme.blue)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(CodeCamTypography.listTitle)
                Text(subtitle).font(CodeCamTypography.listMeta).foregroundStyle(CodeCamTheme.muted).lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(CodeCamTheme.muted)
        }
        .padding(.vertical, 4)
    }
}

struct CodeCamProfileHeader: View {
    let initials: String
    let name: String
    let roleLine: String
    var statusTitle: String = "工位在线"
    var isOnline: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(CodeCamTheme.blue)
                    .frame(width: 50, height: 50)
                Text(initials)
                    .font(CodeCamTypography.profileInitial)
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(CodeCamTypography.profileName)
                Text(roleLine).font(CodeCamTypography.listMeta).foregroundStyle(CodeCamTheme.muted)
                HStack(spacing: 5) {
                    CodeCamStatusDot(tint: isOnline ? CodeCamTheme.green : CodeCamTheme.muted)
                    Text(statusTitle)
                        .font(CodeCamTypography.listMeta)
                        .foregroundStyle(isOnline ? CodeCamTheme.green : CodeCamTheme.muted)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(CodeCamTheme.muted)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 8)
    }
}

enum CodeCamSNBadgeKind {
    case pending, uploading, complete

    var title: String {
        switch self {
        case .pending: "待扫码"
        case .uploading: "待上传"
        case .complete: "已完成"
        }
    }

    var foreground: Color {
        switch self {
        case .pending: CodeCamTheme.blue
        case .uploading: CodeCamTheme.orange
        case .complete: CodeCamTheme.green
        }
    }

    var background: Color {
        switch self {
        case .pending: CodeCamTheme.pendingFill
        case .uploading: CodeCamTheme.uploadingFill
        case .complete: Color(red: 232 / 255, green: 247 / 255, blue: 241 / 255)
        }
    }

    static func from(_ state: ExecutionItemState) -> CodeCamSNBadgeKind {
        switch state {
        case .captured: .uploading
        case .synced, .skipped: .complete
        default: .pending
        }
    }
}

struct CodeCamSNListRow: View {
    let serial: String
    var productName: String?
    var productModel: String?
    var badge: CodeCamSNBadgeKind = .pending
    var stateTitle: String? = nil
    var isPending: Bool = true

    private var productLine: String {
        let text = [productName, productModel].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return text.isEmpty ? "产品资料待获取" : text
    }

    private var resolvedBadge: CodeCamSNBadgeKind {
        if stateTitle == nil { return badge }
        if isPending { return .pending }
        return badge
    }

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(serial)
                    .font(CodeCamTypography.scanCode)
                Text(productLine)
                    .font(CodeCamTypography.scanProduct)
                    .foregroundStyle(Color(red: 73 / 255, green: 85 / 255, blue: 102 / 255))
            }
            Spacer()
            Text(stateTitle ?? resolvedBadge.title)
                .font(CodeCamTypography.scanState)
                .foregroundStyle(resolvedBadge.foreground)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(resolvedBadge.background, in: Capsule())
        }
        .padding(13)
    }
}

struct CodeCamProductInfoCard: View {
    let productName: String
    var rows: [(label: String, value: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(productName)
                .font(CodeCamTypography.productName)
                .padding(.bottom, 6)
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    Divider()
                }
                HStack {
                    Text(row.label)
                        .font(CodeCamTypography.listMeta)
                        .foregroundStyle(CodeCamTheme.muted)
                    Spacer()
                    Text(row.value)
                        .font(CodeCamTypography.listTitle)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(.white, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(CodeCamTheme.accentBorder, lineWidth: 1)
        }
    }
}

struct CodeCamBottomActionBar: View {
    var secondaryTitles: [String]
    var primaryTitle: String = "完成"
    var onSecondary: (Int) -> Void = { _ in }
    var onPrimary: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            ForEach(Array(secondaryTitles.enumerated()), id: \.offset) { index, title in
                Button(title) { onSecondary(index) }
                    .font(CodeCamTypography.bottomBar)
                    .foregroundStyle(Color(red: 52 / 255, green: 64 / 255, blue: 82 / 255))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color(red: 241 / 255, green: 244 / 255, blue: 247 / 255), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .buttonStyle(.plain)
            }
            Button(primaryTitle, action: onPrimary)
                .font(CodeCamTypography.bottomBarPrimary)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(CodeCamTheme.blue, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(.white.opacity(0.95))
        .overlay(alignment: .top) {
            Rectangle().fill(CodeCamTheme.line).frame(height: 1)
        }
    }
}

struct CodeCamServiceEntryButton: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(icon)
                .font(.title3)
                .foregroundStyle(CodeCamTheme.blue)
            Text(title).font(CodeCamTypography.listTitle)
            Text(subtitle).font(CodeCamTypography.listMeta).foregroundStyle(CodeCamTheme.muted)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(CodeCamTheme.line, lineWidth: 1)
        }
    }
}

struct CodeCamListDivider: View {
    var body: some View {
        Divider().overlay(CodeCamTheme.line)
    }
}
