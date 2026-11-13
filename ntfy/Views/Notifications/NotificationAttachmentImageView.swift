//
//  NotificationAttachmentImageView.swift
//  ntfy
//
//  Created by Alek Michelson on 5/11/26.
//

import SwiftUI

struct NotificationAttachmentImageView: View {
    @State private var imagePresentation: PresentedImage?
    @StateObject private var imageLoader = NotificationAttachmentImageLoader()

    let localFileUrl: URL?
    let isLoading: Bool

    var body: some View {
        Group {
            if let image = imageLoader.image {
                renderedImage(image)
            } else if isLoading || imageLoader.phase == .idle || imageLoader.phase == .loading {
                AttachmentLoadingPlaceholder()
            } else {
                failedPlaceholder
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: localFileUrl?.path) {
            await imageLoader.load(from: localFileUrl)
        }
        .fullScreenCover(item: $imagePresentation) { presentedImage in
            AttachmentFullscreenImageView(image: presentedImage.image)
        }
    }

    private func renderedImage(_ image: UIImage) -> some View {
        Button {
            imagePresentation = PresentedImage(image: image)
        } label: {
            AttachmentThumbnail(image: image)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Open image"))
    }

    private var failedPlaceholder: some View {
        RoundedRectangle(cornerRadius: AttachmentImageLayout.cornerRadius, style: .continuous)
            .fill(Color(.secondarySystemFill))
            .frame(height: AttachmentImageLayout.placeholderHeight)
            .overlay {
                Image(systemName: "photo")
                    .accessibilityLabel(String(localized: "Image preview unavailable"))
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
    }
}

/// How an image sits in a dense row (REVIEW.md 2026-11-12, finding 2). Pure, so it is testable.
enum AttachmentImageLayout {
    /// The line between "rich" and "a feed": one screenshot never takes the screen.
    static let maxHeight: CGFloat = 180
    static let placeholderHeight: CGFloat = 120
    static let cornerRadius: CGFloat = 10

    /// Landscape fills the text column's width, capped at `maxHeight` (cropped to fill, centred,
    /// when capped). Portrait and square are `maxHeight` tall at their own aspect, leading-aligned,
    /// so a phone screenshot is a thumbnail. Never upscaled past the image's own size.
    static func size(for image: CGSize, availableWidth: CGFloat) -> CGSize {
        guard image.width > 0, image.height > 0, availableWidth > 0, availableWidth.isFinite else {
            return CGSize(width: max(0, availableWidth.isFinite ? availableWidth : 0), height: placeholderHeight)
        }
        let aspect = image.width / image.height
        if aspect > 1 {
            let width = min(availableWidth, image.width)
            return CGSize(width: width, height: min(maxHeight, width / aspect))
        }
        let height = min(maxHeight, image.height)
        return CGSize(width: min(availableWidth, height * aspect), height: height)
    }
}

/// The image at `AttachmentImageLayout`'s size, with a hairline so a white screenshot doesn't
/// dissolve into a light background.
struct AttachmentThumbnail: View {
    let image: UIImage

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AttachmentImageLayout.cornerRadius, style: .continuous)
        Group {
            if #available(iOS 16.0, *) {
                AttachmentImageFrame(imageSize: image.size) {
                    Color.clear
                        .overlay(Image(uiImage: image).resizable().scaledToFill())
                        .clipped()
                }
            } else {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: AttachmentImageLayout.maxHeight, alignment: .leading)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@available(iOS 16.0, *)
private struct AttachmentImageFrame: Layout {
    let imageSize: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        AttachmentImageLayout.size(for: imageSize, availableWidth: proposal.width ?? 320)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}

/// A download in progress: the space an image takes, so the row doesn't jump when it arrives.
struct AttachmentLoadingPlaceholder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: AttachmentImageLayout.cornerRadius, style: .continuous)
            .fill(Color(.secondarySystemFill))
            .frame(maxWidth: .infinity)
            .frame(height: AttachmentImageLayout.placeholderHeight)
            .overlay { ProgressView() }
            .accessibilityElement()
            .accessibilityLabel(String(localized: "Loading preview"))
    }
}

private struct PresentedImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct AttachmentFullscreenImageView: View {
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .body) private var closeButtonSize: CGFloat = 44

    let image: UIImage

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .ignoresSafeArea()

            ZoomableImageScrollView(image: image)
                .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: closeButtonSize, height: closeButtonSize)
                    .background(.regularMaterial, in: Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                    }
            }
            .accessibilityLabel(HardeningCopy.close)
            .padding(.top, 14)
            .padding(.trailing, 14)
        }
    }
}

private struct ZoomableImageScrollView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 4
        scrollView.minimumZoomScale = 1
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.bouncesZoom = true

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = String(localized: "Image attachment")
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
        scrollView.zoomScale = 1
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }
    }
}
