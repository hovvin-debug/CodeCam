import Foundation
import SwiftUI

/// Compatibility wrapper — account and device live on `PlatformConnectionView`.
struct DeviceRegistrationView: View {
    var body: some View {
        PlatformConnectionView()
    }
}

struct PairingCountdownView: View {
    let expiresAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let status = PairingCountdownStatus(expiresAt: expiresAt, now: context.date)
            HStack {
                Image(systemName: status.isExpired ? "clock.badge.exclamationmark" : "timer")
                Text(status.title)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                Spacer()
                if let detail = status.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(status.tint)
            .accessibilityElement(children: .combine)
        }
    }
}

struct PairingCountdownStatus {
    let title: String
    let detail: String?
    let tint: Color
    let isExpired: Bool

    init(expiresAt: Date?, now: Date) {
        guard let expiresAt else {
            title = "有效期未知"
            detail = "请刷新验证码以同步过期时间"
            tint = .secondary
            isExpired = false
            return
        }

        let remaining = expiresAt.timeIntervalSince(now)
        if remaining <= 0 {
            title = "验证码已过期"
            detail = "可刷新验证码，同时仍在确认是否已被认领"
            tint = .red
            isExpired = true
            return
        }

        let totalSeconds = Int(remaining.rounded(.down))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        title = String(format: "剩余 %02d:%02d", minutes, seconds)
        detail = "有效至 \(WallClock.time(expiresAt))"
        tint = remaining <= 5 * 60 ? .orange : .green
        isExpired = false
    }
}
