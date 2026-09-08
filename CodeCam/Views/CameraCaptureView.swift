import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CameraCaptureView: UIViewControllerRepresentable {
    let mode: CaptureMode
    let onPhoto: (UIImage) -> Void
    let onVideo: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(mode: mode, onPhoto: onPhoto, onVideo: onVideo, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        picker.mediaTypes = [mode == .photo ? UTType.image.identifier : UTType.movie.identifier]
        picker.cameraCaptureMode = mode == .photo ? .photo : .video
        // 现场采集以可辨识、易上传为目标；避免生成高质量原始录像。
        picker.videoQuality = .typeMedium
        picker.videoMaximumDuration = 60
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let mode: CaptureMode
        private let onPhoto: (UIImage) -> Void
        private let onVideo: (URL) -> Void
        private let onCancel: () -> Void

        init(mode: CaptureMode, onPhoto: @escaping (UIImage) -> Void, onVideo: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.mode = mode
            self.onPhoto = onPhoto
            self.onVideo = onVideo
            self.onCancel = onCancel
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            switch mode {
            case .photo:
                guard let image = info[.originalImage] as? UIImage else {
                    onCancel()
                    return
                }
                onPhoto(image)
            case .video:
                guard let url = info[.mediaURL] as? URL else {
                    onCancel()
                    return
                }
                onVideo(url)
            }
        }
    }
}
