import Photos
import SwiftUI

struct SwipeCardView: View {
    let asset: PHAsset
    let canShowPrevious: Bool
    let canShowNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onFinish: () -> Void
    let onDelete: () -> Void
    let onDeleteProgress: (Double) -> Void

    @State private var offset: CGSize = .zero
    @State private var isFinishingGesture = false
    @State private var isMediaZoomed = false
    @State private var dragWasInterrupted = false
    @GestureState private var isTouchingCard = false

    var body: some View {
        ZStack(alignment: .top) {
            AssetMediaView(asset: asset) { isZoomed in
                isMediaZoomed = isZoomed
            }

            HStack {
                mediaBadge
                Spacer()
                if let date = asset.creationDate {
                    Text(date, format: .dateTime.year().month().day())
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.55), in: Capsule())
                }
            }
            .foregroundStyle(.white)
            .padding(14)

        }
        .aspectRatio(assetAspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 24, y: 12)
        // Rotate the card itself, then translate in screen-aligned axes.
        .rotationEffect(.degrees(Double(min(max(offset.width / 28, -8), 8))))
        .offset(offset)
        // Track contact alongside the media's tap/long-press recognizers.
        // Waiting for them to fail makes a held photo feel stuck.
        .simultaneousGesture(dragGesture)
        .onChange(of: isTouchingCard) { _, isTouching in
            if !isTouching {
                dragWasInterrupted = false
                if !isFinishingGesture {
                    onDeleteProgress(0)
                    resetPosition()
                }
            }
        }
        .onChange(of: isMediaZoomed) { _, isZoomed in
            if isZoomed {
                dragWasInterrupted = true
                onDeleteProgress(0)
                resetPosition()
            }
        }
        .onDisappear { onDeleteProgress(0) }
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAction(named: "上一项") {
            if canShowPrevious { onPrevious() }
        }
        .accessibilityAction(named: "下一项") {
            canShowNext ? onNext() : onFinish()
        }
        .accessibilityAction(named: "删除") { onDelete() }
    }

    private var dragGesture: some Gesture {
        // The coordinate space must stay fixed while the card moves and rotates.
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($isTouchingCard) { _, isTouching, transaction in
                transaction.disablesAnimations = true
                isTouching = true
            }
            .onChanged { value in
                guard !isFinishingGesture, !isMediaZoomed, !dragWasInterrupted else { return }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    offset = value.translation
                }
                let progress = Double(min(max(-value.translation.height / 130.0, 0.0), 1.0))
                onDeleteProgress(progress)
            }
            .onEnded { value in
                guard !isFinishingGesture else { return }
                guard !isMediaZoomed, !dragWasInterrupted else {
                    onDeleteProgress(0)
                    resetPosition()
                    return
                }
                let predicted = value.predictedEndTranslation
                let isUpwardDelete = predicted.height < -110
                    && abs(predicted.height) > abs(predicted.width) * 0.75
                let isHorizontalNavigation = abs(predicted.width) > 120

                if isUpwardDelete {
                    onDeleteProgress(1)
                    finish(at: CGSize(
                        width: value.translation.width + (predicted.width - value.translation.width) * 0.25,
                        height: min(-900, value.translation.height - 300)
                    )) {
                        onDelete()
                        onDeleteProgress(0)
                    }
                } else if isHorizontalNavigation {
                    onDeleteProgress(0)
                    let isMovingToNext = predicted.width < 0
                    guard isMovingToNext || canShowPrevious else {
                        resetPosition()
                        return
                    }
                    let direction: CGFloat = predicted.width >= 0 ? 1 : -1
                    finish(at: CGSize(
                        width: direction * max(700, abs(value.translation.width) + 300),
                        height: value.translation.height + (predicted.height - value.translation.height) * 0.25
                    )) {
                        if isMovingToNext {
                            canShowNext ? onNext() : onFinish()
                        } else {
                            onPrevious()
                        }
                    }
                } else {
                    onDeleteProgress(0)
                    resetPosition()
                }
            }
    }

    private var mediaBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: asset.mediaType == .video ? "video.fill" : badgeIcon)
            Text(badgeText)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55), in: Capsule())
    }

    private var assetAspectRatio: CGFloat {
        guard asset.pixelHeight > 0 else { return 1 }
        return CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
    }

    private var badgeIcon: String {
        if asset.mediaSubtypes.contains(.photoLive) { return "livephoto" }
        if asset.mediaSubtypes.contains(.photoScreenshot) { return "iphone" }
        return "photo.fill"
    }

    private var badgeText: String {
        if asset.mediaType == .video {
            return Self.durationFormatter.string(from: asset.duration) ?? "视频"
        }
        if asset.mediaSubtypes.contains(.photoLive) { return "实况照片" }
        if asset.mediaSubtypes.contains(.photoScreenshot) { return "截图" }
        return "照片"
    }

    private var accessibilityDescription: String {
        "\(badgeText)，左右滑浏览同组项目，上滑加入待删除"
    }

    private func finish(at destination: CGSize, action: @escaping () -> Void) {
        isFinishingGesture = true
        withAnimation(.easeOut(duration: 0.18), completionCriteria: .removed) {
            offset = destination
        } completion: {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                action()
                offset = .zero
                isFinishingGesture = false
            }
        }
    }

    private func resetPosition() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
            offset = .zero
        }
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }()
}
