import SwiftUI

/// Compatibility wrapper — account and device live on `PlatformConnectionView`.
struct AccountAuthView: View {
    var body: some View {
        PlatformConnectionView()
    }
}
