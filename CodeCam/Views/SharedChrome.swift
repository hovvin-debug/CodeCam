import SwiftUI
import UIKit

struct StatusCapsule: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

struct CountBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.orange, in: Capsule())
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
                        .font(.caption)
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
