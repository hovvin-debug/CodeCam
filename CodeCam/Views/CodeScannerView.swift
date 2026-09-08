import SwiftUI
import Vision
import VisionKit

struct CodeScannerView: View {
    let onScan: (String) -> Void
    let onCancel: () -> Void
    var title: String = "扫描产品码"
    var lockToCenter: Bool = true
    @State private var manualEntryPresented = false
    @State private var manualCode = ""

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    ZStack {
                        LiveCodeScanner(onScan: onScan, lockToCenter: lockToCenter) {
                            manualCode = ""
                            manualEntryPresented = true
                        }
                        if lockToCenter {
                            ScanAimOverlay()
                        }
                    }
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    manualEntry
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("手动输入") {
                        manualCode = ""
                        manualEntryPresented = true
                    }
                }
            }
        }
        .sheet(isPresented: $manualEntryPresented) {
            NavigationStack {
                Form {
                    Section("产品码") {
                        TextField("输入或粘贴产品码", text: $manualCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    }
                }
                .navigationTitle("手动输入产品码")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { manualEntryPresented = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("确认") {
                            let value = manualCode.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !value.isEmpty else { return }
                            manualEntryPresented = false
                            onScan(value)
                        }
                    }
                }
            }
        }
    }

    private var manualEntry: some View {
        VStack(spacing: 20) {
            ContentUnavailableView(
                "此设备暂不支持实时扫码",
                systemImage: "barcode.viewfinder",
                description: Text("可手动输入或粘贴产品码后继续采集。")
            )
            Button("手动输入产品码") { manualEntryPresented = true }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// Center reticle; keep it light so the system highlight remains visible.
private struct ScanAimOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let shortSide = min(geo.size.width, geo.size.height)
            let box = shortSide * 0.42
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let arm = box * 0.2
            let gap: CGFloat = 9

            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.white.opacity(0.55), lineWidth: 1.5)
                    .frame(width: box, height: box)

                Path { path in
                    path.move(to: CGPoint(x: center.x - arm, y: center.y))
                    path.addLine(to: CGPoint(x: center.x - gap, y: center.y))
                    path.move(to: CGPoint(x: center.x + gap, y: center.y))
                    path.addLine(to: CGPoint(x: center.x + arm, y: center.y))
                    path.move(to: CGPoint(x: center.x, y: center.y - arm))
                    path.addLine(to: CGPoint(x: center.x, y: center.y - gap))
                    path.move(to: CGPoint(x: center.x, y: center.y + gap))
                    path.addLine(to: CGPoint(x: center.x, y: center.y + arm))
                }
                .stroke(.white.opacity(0.92), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .shadow(color: .black.opacity(0.4), radius: 1, y: 1)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct LiveCodeScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    var lockToCenter: Bool = true
    let onUnavailable: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan, lockToCenter: lockToCenter, onUnavailable: onUnavailable) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr, .code128, .code39, .dataMatrix, .ean13, .ean8])],
            qualityLevel: .balanced,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        do {
            try scanner.startScanning()
        } catch {
            DispatchQueue.main.async {
                context.coordinator.onUnavailable()
            }
        }
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (String) -> Void
        let onUnavailable: () -> Void
        private let lockToCenter: Bool
        private var hasScanned = false

        init(onScan: @escaping (String) -> Void, lockToCenter: Bool, onUnavailable: @escaping () -> Void) {
            self.onScan = onScan
            self.lockToCenter = lockToCenter
            self.onUnavailable = onUnavailable
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            commitCenteredBarcode(from: allItems, in: dataScanner)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            commitCenteredBarcode(from: allItems, in: dataScanner)
        }

        private func commitCenteredBarcode(from items: [RecognizedItem], in dataScanner: DataScannerViewController) {
            guard !hasScanned else { return }
            let center = CGPoint(x: dataScanner.view.bounds.midX, y: dataScanner.view.bounds.midY)
            let limit = min(dataScanner.view.bounds.width, dataScanner.view.bounds.height) * 0.21

            let candidates: [(value: String, distance: CGFloat)] = items.compactMap { item in
                guard case .barcode(let barcode) = item, let value = barcode.payloadStringValue, !value.isEmpty else {
                    return nil
                }
                let point = midpoint(of: barcode.bounds)
                let distance = hypot(point.x - center.x, point.y - center.y)
                if lockToCenter, distance > limit { return nil }
                return (value, distance)
            }

            guard let best = candidates.min(by: { $0.distance < $1.distance }) else { return }
            hasScanned = true
            dataScanner.stopScanning()
            onScan(best.value)
        }

        private func midpoint(of bounds: RecognizedItem.Bounds) -> CGPoint {
            let xs = [bounds.topLeft.x, bounds.topRight.x, bounds.bottomLeft.x, bounds.bottomRight.x]
            let ys = [bounds.topLeft.y, bounds.topRight.y, bounds.bottomLeft.y, bounds.bottomRight.y]
            return CGPoint(x: xs.reduce(0, +) / 4, y: ys.reduce(0, +) / 4)
        }
    }
}
