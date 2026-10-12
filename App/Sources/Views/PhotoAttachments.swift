import PhotosUI
import SwiftUI
import UIKit

/// A photo waiting in the composer: a thumbnail to show and the JPEG to upload.
struct PhotoAttachment: Identifiable {
    let id = UUID()
    let thumbnail: UIImage
    let jpeg: Data

    /// Longest side sent to agents: plenty to read a screenshot, a few hundred KB.
    static let maxSide: CGFloat = 2048

    /// Downscales and re-encodes as JPEG (HEIC and PNG included); nil if it isn't an image.
    init?(data: Data) {
        guard let image = UIImage(data: data) else { return nil }
        self.init(image: image)
    }

    init?(image: UIImage) {
        let full = Self.resized(image, maxSide: Self.maxSide)
        guard let jpeg = full.jpegData(compressionQuality: 0.8) else { return nil }
        self.jpeg = jpeg
        thumbnail = Self.resized(image, maxSide: 160)
    }

    private static func resized(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        // Drawing also applies the photo's orientation, so the JPEG comes out upright.
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

/// The 📎 button: pick from the library or take a photo.
struct AttachPhotoButton: View {
    @Binding var attachments: [PhotoAttachment]
    var limit = 4
    @State private var picking = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var takingPhoto = false

    var body: some View {
        Menu {
            Button { picking = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { takingPhoto = true } label: { Label("Take Photo", systemImage: "camera") }
            }
        } label: {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 18))
                .frame(width: 34, height: 34)
        }
        .disabled(attachments.count >= limit)
        .accessibilityLabel("Attach photo")
        .photosPicker(isPresented: $picking, selection: $picked,
                      maxSelectionCount: max(1, limit - attachments.count), matching: .images)
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task {
                for item in items {
                    guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                    let made = await Task.detached(priority: .userInitiated) { PhotoAttachment(data: data) }.value
                    if let made, attachments.count < limit { attachments.append(made) }
                }
            }
        }
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraView { image in
                takingPhoto = false
                guard let image else { return }
                Task {
                    let made = await Task.detached(priority: .userInitiated) { PhotoAttachment(image: image) }.value
                    if let made, attachments.count < limit { attachments.append(made) }
                }
            }
            .ignoresSafeArea()
        }
    }
}

/// Thumbnails of the attached photos, each with a remove button.
struct AttachmentStrip: View {
    @Binding var attachments: [PhotoAttachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { a in
                    Image(uiImage: a.thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                attachments.removeAll { $0.id == a.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                                    .font(.system(size: 18))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 5, y: -5)
                            .accessibilityLabel("Remove photo")
                        }
                }
            }
            .padding(.top, 6)
            .padding(.horizontal, 2)
        }
    }
}

/// The system camera, for one photo.
struct CameraView: UIViewControllerRepresentable {
    let onDone: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onDone: (UIImage?) -> Void

        init(onDone: @escaping (UIImage?) -> Void) { self.onDone = onDone }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onDone(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onDone(nil) }
    }
}
