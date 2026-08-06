import PhotosUI
import SwiftUI

/// Screenshot picking and preview inside the feedback form.
struct AttachmentPicker: View {
    @Binding var attachments: [Attachment]
    let maxCount: Int
    let maxDimension: CGFloat
    let quality: CGFloat

    @State private var selection: [PhotosPickerItem] = []
    @State private var isProcessing = false
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("rater.form.attachments", bundle: .module)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(verbatim: "\(attachments.count)/\(maxCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(attachments) { attachment in
                        thumbnail(attachment)
                    }
                    if attachments.count < maxCount {
                        addButton
                    }
                }
                .padding(.vertical, 2)
            }

            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onChange(of: selection) { _, items in
            guard !items.isEmpty else { return }
            Task { await load(items) }
        }
    }

    private var addButton: some View {
        // PhotosPicker's label closure isn't MainActor-isolated, so read state up front.
        let processing = isProcessing
        return PhotosPicker(
            selection: $selection,
            maxSelectionCount: maxCount - attachments.count,
            matching: .images,
            photoLibrary: .shared()
        ) {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(.tertiary)
                .frame(width: 72, height: 72)
                .overlay {
                    if processing {
                        ProgressView()
                    } else {
                        Image(systemName: "photo.badge.plus")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
        }
        .disabled(processing)
        .accessibilityLabel(Text("rater.form.addScreenshot", bundle: .module))
    }

    private func thumbnail(_ attachment: Attachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let data = attachment.thumbnail ?? attachment.data as Data?,
                   let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.secondary.opacity(0.2)
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Button {
                attachments.removeAll { $0.id == attachment.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
                    .font(.body)
            }
            .offset(x: 6, y: -6)
            .accessibilityLabel(Text("rater.form.removeScreenshot", bundle: .module))
        }
        .padding(.trailing, 4)
        .padding(.top, 4)
    }

    /// Compression saturates a core, so it runs off the main actor — typing in the form
    /// should stay responsive while screenshots are being processed.
    private func load(_ items: [PhotosPickerItem]) async {
        isProcessing = true
        loadError = nil
        defer {
            isProcessing = false
            selection = []
        }

        for item in items {
            guard attachments.count < maxCount else { break }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let attachment = try await Task.detached(priority: .userInitiated) {
                    try Attachment.make(fromImageData: data,
                                        maxDimension: maxDimension, quality: quality)
                }.value
                attachments.append(attachment)
            } catch {
                loadError = String(localized: "rater.form.imageFailed", defaultValue: "One image couldn't be read. Try another one.", bundle: .module)
            }
        }
    }
}
