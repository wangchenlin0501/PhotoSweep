import Photos
import SwiftUI
import UIKit

struct DayGalleryView: View {
    let date: Date
    let currentAssetIdentifier: String
    @ObservedObject var viewModel: ReviewViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var assets: [PHAsset] = []
    @State private var selectedIdentifiers: Set<String> = []
    @State private var isLoading = true
    @State private var isShowingDeleteConfirmation = false
    @State private var previewItem: DayGalleryPreviewItem?

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 3),
        count: 3
    )

    var body: some View {
        Group {
            if isLoading {
                ProgressView("正在读取当天项目…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if assets.isEmpty {
                ContentUnavailableView(
                    "这一天没有项目",
                    systemImage: "calendar.badge.exclamationmark",
                    description: Text("当天的照片和视频可能已经被删除。")
                )
            } else {
                gallery
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("回到那天")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(allSelected ? "取消全选" : "全选") {
                    toggleSelectAll()
                }
                .disabled(viewModel.isDeleting || assets.isEmpty)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !assets.isEmpty {
                deleteBar
            }
        }
        .fullScreenCover(item: $previewItem) { item in
            DayGalleryPreview(
                asset: item.asset,
                isSelected: Binding(
                    get: { selectedIdentifiers.contains(item.asset.localIdentifier) },
                    set: { isSelected in
                        if isSelected {
                            selectedIdentifiers.insert(item.asset.localIdentifier)
                        } else {
                            selectedIdentifiers.remove(item.asset.localIdentifier)
                        }
                    }
                )
            )
        }
        .task(id: Calendar.autoupdatingCurrent.startOfDay(for: date)) {
            await loadAssets()
        }
        .alert(
            "删除选中的 \(selectedIdentifiers.count) 个项目？",
            isPresented: $isShowingDeleteConfirmation
        ) {
            Button("确认删除", role: .destructive) {
                Task { await deleteSelection() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后，项目会进入系统相册的“最近删除”。")
        }
    }

    private var gallery: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(date, format: .dateTime.year().month(.wide).day())
                            .font(.title2.bold())
                        Text("\(assets.count) 个项目")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !selectedIdentifiers.isEmpty {
                        Text("已选择 \(selectedIdentifiers.count)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.blue)
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 16)

                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(assets, id: \.localIdentifier) { asset in
                        Button {
                            previewItem = DayGalleryPreviewItem(asset: asset)
                        } label: {
                            DayGalleryThumbnail(
                                asset: asset,
                                isSelected: selectedIdentifiers.contains(
                                    asset.localIdentifier
                                ),
                                isCurrent: asset.localIdentifier == currentAssetIdentifier
                            )
                        }
                        .buttonStyle(.plain)
                        .contentShape(.interaction, Rectangle())
                        .accessibilityLabel("查看\(accessibilityLabel(for: asset))")
                        .disabled(viewModel.isDeleting)
                        .overlay(alignment: .topTrailing) {
                            Button {
                                toggleSelection(asset)
                            } label: {
                                DaySelectionIndicator(
                                    isSelected: selectedIdentifiers.contains(asset.localIdentifier)
                                )
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isDeleting)
                            .accessibilityLabel(
                                selectedIdentifiers.contains(asset.localIdentifier)
                                    ? "取消选择此项目" : "选择此项目删除"
                            )
                        }
                    }
                }
            }
            .padding(.top, 10)
            .padding(.horizontal, 3)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
    }

    private var deleteBar: some View {
        Button(role: .destructive) {
            isShowingDeleteConfirmation = true
        } label: {
            Group {
                if viewModel.isDeleting {
                    ProgressView()
                        .tint(.white)
                } else {
                    Label("删除", systemImage: "trash.fill")
                }
            }
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .frame(height: 48)
            .background(
                selectedIdentifiers.isEmpty ? Color.red.opacity(0.32) : Color.red,
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .disabled(selectedIdentifiers.isEmpty || viewModel.isDeleting)
        .accessibilityValue("已选择 \(selectedIdentifiers.count) 个项目")
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var allSelected: Bool {
        !assets.isEmpty && selectedIdentifiers.count == assets.count
    }

    private func loadAssets() async {
        isLoading = true
        assets = await PhotoLibraryService.shared.assets(createdOn: date)
        let availableIdentifiers = Set(assets.map(\.localIdentifier))
        selectedIdentifiers.formIntersection(availableIdentifiers)
        isLoading = false
    }

    private func toggleSelection(_ asset: PHAsset) {
        let identifier = asset.localIdentifier
        if selectedIdentifiers.contains(identifier) {
            selectedIdentifiers.remove(identifier)
        } else {
            selectedIdentifiers.insert(identifier)
            PhotoLibraryService.shared.prepareDeletionSize(for: asset)
        }
    }

    private func toggleSelectAll() {
        if allSelected {
            selectedIdentifiers = []
        } else {
            selectedIdentifiers = Set(assets.map(\.localIdentifier))
        }
    }

    private func deleteSelection() async {
        let identifiers = selectedIdentifiers
        let selectedAssets = assets.filter {
            identifiers.contains($0.localIdentifier)
        }
        guard await viewModel.deleteAssetsFromDay(selectedAssets) else { return }

        assets.removeAll { identifiers.contains($0.localIdentifier) }
        selectedIdentifiers = []
        dismiss()
    }

    private func accessibilityLabel(for asset: PHAsset) -> String {
        let kind: String
        if asset.mediaType == .video {
            kind = "视频"
        } else if asset.mediaSubtypes.contains(.photoLive) {
            kind = "实况照片"
        } else if asset.mediaSubtypes.contains(.photoScreenshot) {
            kind = "截图"
        } else {
            kind = "照片"
        }
        let state = selectedIdentifiers.contains(asset.localIdentifier) ? "已选择" : "未选择"
        return "\(kind)，\(state)"
    }
}

private struct DayGalleryThumbnail: View {
    let asset: PHAsset
    let isSelected: Bool
    let isCurrent: Bool

    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?
    private let manager = PHImageManager.default()

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.secondary.opacity(0.1)

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .allowsHitTesting(false)
                } else {
                    Image(systemName: placeholderIcon)
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }

                if isSelected {
                    Color.black.opacity(0.18)
                }

                VStack {
                    HStack {
                        mediaMarker
                        Spacer()
                    }
                    Spacer()
                    if isCurrent {
                        HStack {
                            Text("当前")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(.blue, in: Capsule())
                            Spacer()
                        }
                    }
                }
                .padding(7)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay {
                if isCurrent && !isSelected {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(.blue, lineWidth: 2)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        // Clipping only limits drawing; explicitly bound the button's hit area.
        .contentShape(.interaction, Rectangle())
        .onAppear(perform: loadThumbnail)
        .onDisappear(perform: cancelRequest)
    }

    @ViewBuilder
    private var mediaMarker: some View {
        if asset.mediaType == .video || asset.mediaSubtypes.contains(.photoLive) {
            Image(systemName: asset.mediaType == .video ? "video.fill" : "livephoto")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(5)
                .background(.black.opacity(0.52), in: Circle())
        }
    }

    private var placeholderIcon: String {
        asset.mediaType == .video ? "video" : "photo"
    }

    private func loadThumbnail() {
        if let cachedImage = OfflineCacheService.shared.cachedImage(
            for: asset.localIdentifier
        ) {
            image = cachedImage
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        requestID = manager.requestImage(
            for: asset,
            targetSize: CGSize(width: 500, height: 500),
            contentMode: .aspectFill,
            options: options
        ) { result, _ in
            guard let result else { return }
            Task { @MainActor in image = result }
        }
    }

    private func cancelRequest() {
        if let requestID {
            manager.cancelImageRequest(requestID)
        }
        requestID = nil
    }
}

private struct DaySelectionIndicator: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isSelected ? Color.blue : Color.black.opacity(0.28))
            Circle()
                .stroke(.white, lineWidth: 1.5)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 24, height: 24)
    }
}

private struct DayGalleryPreviewItem: Identifiable {
    let asset: PHAsset
    var id: String { asset.localIdentifier }
}

private struct DayGalleryPreview: View {
    let asset: PHAsset
    @Binding var isSelected: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var isMediaZoomed = false
    @State private var dragWasInterrupted = false
    @State private var dragOffset: CGSize = .zero
    @State private var isDismissing = false
    @GestureState private var isDragging = false

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ZStack {
                    Color.black.ignoresSafeArea()
                    AssetMediaView(asset: asset) { isZoomed in
                        isMediaZoomed = isZoomed
                        if isZoomed {
                            if isDragging { dragWasInterrupted = true }
                            resetDrag()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scaleEffect(1 - min(hypot(dragOffset.width, dragOffset.height) / 1600, 0.12))
                    .offset(dragOffset)
                    .simultaneousGesture(dismissGesture(in: proxy.frame(in: .global)))
                }
            }
            .onChange(of: isDragging) { _, isDragging in
                if !isDragging {
                    dragWasInterrupted = false
                    if !isDismissing { resetDrag() }
                }
            }
            .navigationTitle(
                asset.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? "预览"
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("关闭预览")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isSelected.toggle()
                    } label: {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? .blue : .white)
                    }
                    .accessibilityLabel(isSelected ? "取消选择此项目" : "选择此项目删除")
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func dismissGesture(in mediaFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .updating($isDragging) { _, isDragging, _ in
                isDragging = true
            }
            .onChanged { value in
                if isMediaZoomed { dragWasInterrupted = true }
                guard canDismiss(from: value.startLocation, in: mediaFrame) else { return }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    dragOffset = value.translation
                }
            }
            .onEnded { value in
                guard canDismiss(from: value.startLocation, in: mediaFrame) else {
                    resetDrag()
                    return
                }
                let distance = hypot(value.translation.width, value.translation.height)
                let projectedDistance = hypot(
                    value.predictedEndTranslation.width,
                    value.predictedEndTranslation.height
                )
                // Use distance rather than an axis: all swipe directions dismiss.
                if distance >= 80 || (distance >= 24 && projectedDistance >= 160) {
                    isDismissing = true
                    dismiss()
                } else {
                    resetDrag()
                }
            }
    }

    private func canDismiss(from start: CGPoint, in mediaFrame: CGRect) -> Bool {
        guard !isMediaZoomed, !dragWasInterrupted, !isDismissing else { return false }
        // Leave the video's bottom transport/scrubbing region to the player.
        return asset.mediaType != .video || start.y < mediaFrame.maxY - 100
    }

    private func resetDrag() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            dragOffset = .zero
        }
    }
}
