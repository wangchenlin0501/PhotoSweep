import AVKit
import Photos
import PhotosUI
import SwiftUI
import UIKit

struct AssetMediaView: View {
    let asset: PHAsset
    let onZoomStateChange: (Bool) -> Void

    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var livePhoto: PHLivePhoto?
    @State private var loadingIdentifier: String?

    init(
        asset: PHAsset,
        onZoomStateChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.asset = asset
        self.onZoomStateChange = onZoomStateChange
    }

    var body: some View {
        ZStack {
            Color.clear

            if asset.mediaSubtypes.contains(.photoLive) {
                if let livePhoto {
                    ZoomableLivePhotoPlaybackView(
                        livePhoto: livePhoto,
                        onZoomStateChange: onZoomStateChange
                    )
                } else if let image {
                    ZoomableImageView(
                        image: image,
                        onZoomStateChange: onZoomStateChange
                    )
                } else {
                    ProgressView("正在载入实况照片…")
                        .tint(.secondary)
                        .foregroundStyle(.secondary)
                }
            } else if asset.mediaType == .video {
                if let player {
                    VideoPlayer(player: player)
                } else if let image {
                    ZoomableImageView(
                        image: image,
                        onZoomStateChange: onZoomStateChange
                    )
                } else {
                    ProgressView("正在载入视频…")
                        .tint(.secondary)
                        .foregroundStyle(.secondary)
                }
            } else if let image {
                ZoomableImageView(
                    image: image,
                    onZoomStateChange: onZoomStateChange
                )
            } else {
                ProgressView("正在载入照片…")
                    .tint(.secondary)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: asset.localIdentifier) {
            loadMedia()
        }
        .onDisappear {
            loadingIdentifier = nil
            player?.pause()
            onZoomStateChange(false)
        }
    }

    private func loadMedia() {
        let identifier = asset.localIdentifier
        loadingIdentifier = identifier
        image = nil
        player = nil
        livePhoto = nil

        if let cachedImage = OfflineCacheService.shared.cachedImage(for: identifier) {
            image = cachedImage
        }

        MediaPreloadService.shared.loadImage(for: asset) { loadedImage in
            guard loadingIdentifier == identifier, let loadedImage else { return }
            image = loadedImage
        }

        if asset.mediaSubtypes.contains(.photoLive) {
            MediaPreloadService.shared.loadLivePhoto(for: asset) { loadedLivePhoto in
                guard loadingIdentifier == identifier, let loadedLivePhoto else { return }
                livePhoto = loadedLivePhoto
            }
        } else if asset.mediaType == .video {
            MediaPreloadService.shared.loadVideoAsset(for: asset) { videoAsset in
                guard loadingIdentifier == identifier, let videoAsset else { return }
                let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: videoAsset))
                player = newPlayer
                newPlayer.play()
            }
        }
    }
}

private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    let onZoomStateChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onZoomStateChange: onZoomStateChange)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = makeZoomScrollView(coordinator: context.coordinator)
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)
        constrainToViewport(imageView, in: scrollView)

        context.coordinator.scrollView = scrollView
        context.coordinator.zoomView = imageView
        context.coordinator.imageView = imageView
        addDoubleTap(to: scrollView, coordinator: context.coordinator)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.onZoomStateChange = onZoomStateChange
        if context.coordinator.imageView?.image !== image {
            scrollView.setZoomScale(1, animated: false)
            context.coordinator.imageView?.image = image
        }
    }

    static func dismantleUIView(_ scrollView: UIScrollView, coordinator: Coordinator) {
        coordinator.reportZoomState(false)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var onZoomStateChange: (Bool) -> Void
        weak var scrollView: UIScrollView?
        weak var zoomView: UIView?
        weak var imageView: UIImageView?
        private var wasZoomed = false

        init(onZoomStateChange: @escaping (Bool) -> Void) {
            self.onZoomStateChange = onZoomStateChange
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            zoomView
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            // Suspend card dragging as soon as a pinch begins, even at 1x.
            reportZoomState(true)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let isZoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            scrollView.panGestureRecognizer.isEnabled = isZoomed
            let pinchState = scrollView.pinchGestureRecognizer?.state
            reportZoomState(isZoomed || pinchState == .began || pinchState == .changed)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            reportZoomState(scale > scrollView.minimumZoomScale + 0.01)
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView, let zoomView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let zoomScale: CGFloat = 2.5
                let point = recognizer.location(in: zoomView)
                let width = scrollView.bounds.width / zoomScale
                let height = scrollView.bounds.height / zoomScale
                scrollView.zoom(
                    to: CGRect(
                        x: point.x - width / 2,
                        y: point.y - height / 2,
                        width: width,
                        height: height
                    ),
                    animated: true
                )
            }
        }

        func reportZoomState(_ isZoomed: Bool) {
            guard wasZoomed != isZoomed else { return }
            wasZoomed = isZoomed
            onZoomStateChange(isZoomed)
        }
    }
}

private struct ZoomableLivePhotoPlaybackView: UIViewRepresentable {
    let livePhoto: PHLivePhoto
    let onZoomStateChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onZoomStateChange: onZoomStateChange)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = makeZoomScrollView(coordinator: context.coordinator)
        let livePhotoView = PHLivePhotoView()
        livePhotoView.contentMode = .scaleAspectFit
        livePhotoView.livePhoto = livePhoto
        livePhotoView.isMuted = false
        livePhotoView.isUserInteractionEnabled = true
        livePhotoView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(livePhotoView)
        constrainToViewport(livePhotoView, in: scrollView)

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.22
        longPress.cancelsTouchesInView = false
        longPress.delegate = context.coordinator
        // Use our press-and-release playback handler without a second competing
        // playback recognizer supplied by PHLivePhotoView.
        livePhotoView.playbackGestureRecognizer.isEnabled = false
        livePhotoView.addGestureRecognizer(longPress)

        context.coordinator.scrollView = scrollView
        context.coordinator.livePhotoView = livePhotoView
        addDoubleTap(to: scrollView, coordinator: context.coordinator)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.onZoomStateChange = onZoomStateChange
        if context.coordinator.livePhotoView?.livePhoto !== livePhoto {
            scrollView.setZoomScale(1, animated: false)
            context.coordinator.livePhotoView?.livePhoto = livePhoto
        }
    }

    static func dismantleUIView(_ scrollView: UIScrollView, coordinator: Coordinator) {
        coordinator.livePhotoView?.stopPlayback()
        coordinator.reportZoomState(false)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var onZoomStateChange: (Bool) -> Void
        weak var scrollView: UIScrollView?
        weak var livePhotoView: PHLivePhotoView?
        private var wasZoomed = false

        init(onZoomStateChange: @escaping (Bool) -> Void) {
            self.onZoomStateChange = onZoomStateChange
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            livePhotoView
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            // Suspend card dragging as soon as a pinch begins, even at 1x.
            reportZoomState(true)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let isZoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            scrollView.panGestureRecognizer.isEnabled = isZoomed
            let pinchState = scrollView.pinchGestureRecognizer?.state
            reportZoomState(isZoomed || pinchState == .began || pinchState == .changed)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            reportZoomState(scale > scrollView.minimumZoomScale + 0.01)
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView, let livePhotoView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let zoomScale: CGFloat = 2.5
                let point = recognizer.location(in: livePhotoView)
                let width = scrollView.bounds.width / zoomScale
                let height = scrollView.bounds.height / zoomScale
                scrollView.zoom(
                    to: CGRect(
                        x: point.x - width / 2,
                        y: point.y - height / 2,
                        width: width,
                        height: height
                    ),
                    animated: true
                )
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Playing a Live Photo must not lock out moving the card.
            gestureRecognizer is UILongPressGestureRecognizer
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began:
                livePhotoView?.startPlayback(with: .full)
            case .ended, .cancelled, .failed:
                livePhotoView?.stopPlayback()
            default:
                break
            }
        }

        func reportZoomState(_ isZoomed: Bool) {
            guard wasZoomed != isZoomed else { return }
            wasZoomed = isZoomed
            onZoomStateChange(isZoomed)
        }
    }
}

private func makeZoomScrollView(
    coordinator: UIScrollViewDelegate
) -> UIScrollView {
    let scrollView = UIScrollView()
    scrollView.delegate = coordinator
    scrollView.minimumZoomScale = 1
    scrollView.maximumZoomScale = 5
    scrollView.bouncesZoom = true
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.showsVerticalScrollIndicator = false
    scrollView.panGestureRecognizer.isEnabled = false
    scrollView.delaysContentTouches = false
    scrollView.backgroundColor = .clear
    return scrollView
}

private func constrainToViewport(_ view: UIView, in scrollView: UIScrollView) {
    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
        view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
        view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
        view.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        view.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
    ])
}

private func addDoubleTap(
    to scrollView: UIScrollView,
    coordinator: AnyObject
) {
    let selector = NSSelectorFromString("handleDoubleTap:")
    let doubleTap = UITapGestureRecognizer(target: coordinator, action: selector)
    doubleTap.numberOfTapsRequired = 2
    scrollView.addGestureRecognizer(doubleTap)
}
