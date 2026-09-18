import Photos
import SwiftData
import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = ReviewViewModel()
    @State private var deletionGlowProgress = 0.0
    @State private var isPreparingShare = false
    @State private var shareExport: ShareExport?
    @State private var shareTemporaryDirectory: URL?
    @State private var shareErrorMessage: String?

    var body: some View {
        ZStack {
            NavigationStack {
                Group {
                    switch viewModel.authorizationStatus {
                    case .notDetermined:
                        permissionRequestView
                    case .denied, .restricted:
                        permissionDeniedView
                    case .authorized, .limited:
                        authorizedContent
                    @unknown default:
                        permissionDeniedView
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        NavigationLink {
                            StatisticsView(viewModel: viewModel)
                        } label: {
                            Image(systemName: "chart.bar.xaxis")
                        }
                        .accessibilityLabel("查看统计")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if let currentAsset = viewModel.currentAsset,
                           !viewModel.isBatchComplete {
                            Button {
                                Task { await share(currentAsset) }
                            } label: {
                                if isPreparingShare {
                                    ProgressView()
                                } else {
                                    Image(systemName: "square.and.arrow.up")
                                }
                            }
                            .disabled(isPreparingShare)
                            .accessibilityLabel(
                                isPreparingShare ? "正在准备分享" : "分享当前项目"
                            )
                        }
                    }
                }
                .toolbar(viewModel.isBatchComplete ? .hidden : .visible, for: .navigationBar)
            }

            DynamicIslandDeletionGlow(progress: deletionGlowProgress)
                .allowsHitTesting(false)
        }
        .task {
            viewModel.configure(modelContext: modelContext)
            await viewModel.startIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                viewModel.refreshAuthorization()
            }
        }
        .alert(
            "操作未完成",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.dismissError() } }
            )
        ) {
            Button("知道了") { viewModel.dismissError() }
        } message: {
            Text(viewModel.errorMessage ?? "请稍后重试。")
        }
        .alert(
            "无法分享",
            isPresented: Binding(
                get: { shareErrorMessage != nil },
                set: { if !$0 { shareErrorMessage = nil } }
            )
        ) {
            Button("知道了") { shareErrorMessage = nil }
        } message: {
            Text(shareErrorMessage ?? "请稍后重试。")
        }
        .sheet(item: $shareExport, onDismiss: removeTemporaryShareFiles) { export in
            ActivityShareSheet(activityItems: export.fileURLs)
        }
    }

    private var permissionRequestView: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "photo.stack")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(.blue)

            VStack(spacing: 10) {
                Text("每天轻松整理一点")
                    .font(.title.bold())
                Text("每组随机抽取 15 个照片或视频。左右滑浏览同组项目，上滑加入待删除。浏览记录只保存在这台设备上。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await viewModel.requestAccess() }
            } label: {
                Label("允许访问相册", systemImage: "photo.on.rectangle.angled")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)

            Text("需要“完全访问”才能从整个相册随机抽取；你也可以选择有限访问。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(28)
    }

    private var permissionDeniedView: some View {
        ContentUnavailableView {
            Label("无法访问相册", systemImage: "photo.badge.exclamationmark")
        } description: {
            Text("请在系统设置中允许相册读写权限，才能随机浏览并删除项目。")
        } actions: {
            Button("打开设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var authorizedContent: some View {
        if viewModel.isLoading && viewModel.batch.isEmpty {
            ProgressView("正在随机挑选…")
        } else if viewModel.isBatchComplete {
            completionView
        } else if let asset = viewModel.currentAsset {
            reviewView(asset: asset)
        } else {
            emptyStateView
        }
    }

    private func reviewView(asset: PHAsset) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Text("\(viewModel.reviewedCount) / \(viewModel.originalBatchCount)")
                    .font(.headline.monospacedDigit())
                ProgressView(
                    value: Double(viewModel.reviewedCount),
                    total: Double(max(viewModel.originalBatchCount, 1))
                )
                if viewModel.authorizationStatus == .limited {
                    Button("有限访问") { openSettings() }
                        .font(.caption.weight(.semibold))
                }
            }

            SwipeCardView(
                asset: asset,
                canShowPrevious: viewModel.canShowPrevious,
                canShowNext: viewModel.canShowNext,
                onPrevious: { viewModel.showPreviousAsset() },
                onNext: { viewModel.showNextAsset() },
                onFinish: viewModel.finishBatch,
                onDelete: viewModel.markCurrentForDeletion,
                onDeleteProgress: { deletionGlowProgress = $0 }
            )
            .id(asset.localIdentifier)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Reserve a separate row so controls never cover the resting photo
            // or resize it when undo becomes available.
            ZStack {
                if let creationDate = asset.creationDate {
                    NavigationLink {
                        DayGalleryView(
                            date: creationDate,
                            currentAssetIdentifier: asset.localIdentifier,
                            viewModel: viewModel
                        )
                    } label: {
                        Image(systemName: "calendar.day.timeline.left")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 48, height: 48)
                            .modifier(ReviewControlGlass())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看这一天的全部项目")
                    .accessibilityValue(creationDate.formatted(date: .complete, time: .omitted))
                }

                HStack {
                    Spacer(minLength: 0)
                    if viewModel.canUndoDeletion {
                        undoButton
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .animation(.spring(response: 0.3, dampingFraction: 0.78), value: viewModel.canUndoDeletion)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var completionView: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()
            LinearGradient(
                colors: [Color.accentColor.opacity(0.08), .clear],
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(spacing: 24) {
                    VStack(spacing: 6) {
                        Text("回顾完毕")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text(
                            viewModel.deletionReviewAssets.isEmpty
                                ? "这一组没有需要删除的项目"
                                : "请选择最终需要删除的项目"
                        )
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    }

                    if viewModel.deletionReviewAssets.isEmpty {
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 82, weight: .semibold))
                            .foregroundStyle(.green)
                        Text("已查看 \(viewModel.reviewedCount) 个项目")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVGrid(
                                columns: Array(
                                    repeating: GridItem(.flexible(), spacing: 10),
                                    count: 3
                                ),
                                spacing: 10
                            ) {
                                ForEach(viewModel.deletionReviewAssets, id: \.localIdentifier) { asset in
                                    Button {
                                        viewModel.toggleDeletionSelection(for: asset)
                                    } label: {
                                        DeletionReviewThumbnail(
                                            asset: asset,
                                            isSelected: viewModel.isSelectedForDeletion(asset)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(
                                        viewModel.isSelectedForDeletion(asset)
                                            ? "取消选择此项目"
                                            : "选择此项目删除"
                                    )
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                    }

                    completionActions
                }
                .padding(.horizontal, 22)
                .padding(.top, 38)
                .padding(.bottom, 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.14), radius: 28, y: 14)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 20)

        }
        .animation(
            .spring(response: 0.3, dampingFraction: 0.78),
            value: viewModel.pendingDeletionIdentifiers.count
        )
    }

    @ViewBuilder
    private var completionActions: some View {
        if viewModel.deletionReviewAssets.isEmpty {
            Button {
                Task { await viewModel.loadBatch() }
            } label: {
                Text("再来一组")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(.blue, in: Capsule())
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 12) {
                Button {
                    Task { await viewModel.changePendingDeletionToKeep() }
                } label: {
                    Text("放弃，再来一组")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .overlay {
                            Capsule().stroke(Color.secondary.opacity(0.24), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isDeleting)

                Button(role: .destructive) {
                    Task { await viewModel.commitPendingDeletion() }
                } label: {
                    Group {
                        if viewModel.isDeleting {
                            ProgressView().tint(.white)
                        } else {
                            Text("确认删除（\(viewModel.pendingDeletionIdentifiers.count)）")
                                .font(.headline)
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(
                        Color.red.opacity(
                            viewModel.pendingDeletionIdentifiers.isEmpty ? 0.28 : 0.82
                        ),
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .disabled(
                    viewModel.isDeleting || viewModel.pendingDeletionIdentifiers.isEmpty
                )
            }
        }
    }

    private var undoButton: some View {
        Button(action: viewModel.undoLastDeletion) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 48, height: 48)
                .modifier(ReviewControlGlass())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("撤销最近一次待删除")
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label(
                viewModel.hasOfflinePackage
                    ? "离线照片包已看完"
                    : (viewModel.accessibleCount == 0 ? "没有可访问的项目" : "暂时都看完了"),
                systemImage: viewModel.hasOfflinePackage ? "airplane" : "checkmark.seal"
            )
        } description: {
            if viewModel.hasOfflinePackage {
                Text("可以在左上角统计页面重置浏览记录，或重新提前加载一批项目。")
            } else if let nextDate = viewModel.nextEligibleDate {
                Text("下一批最早会在 \(nextDate.formatted(date: .long, time: .omitted)) 重新进入随机池。新加入相册的项目仍会立即参与随机。")
            } else if viewModel.authorizationStatus == .limited {
                Text("当前有限权限中没有可用项目。可在系统设置中增加允许访问的照片和视频。")
            } else {
                Text("相册中没有可整理的照片或视频。")
            }
        } actions: {
            Button("重新检查") {
                Task { await viewModel.loadBatch() }
            }
            if viewModel.authorizationStatus == .limited {
                Button("管理相册权限") { openSettings() }
            }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }

    private func share(_ asset: PHAsset) async {
        guard !isPreparingShare else { return }
        isPreparingShare = true
        defer { isPreparingShare = false }

        do {
            removeTemporaryShareFiles()
            let export = try await ShareExportService.shared.export(asset)
            shareTemporaryDirectory = export.temporaryDirectory
            shareExport = export
        } catch {
            shareErrorMessage = error.localizedDescription
        }
    }

    private func removeTemporaryShareFiles() {
        ShareExportService.shared.removeTemporaryFiles(at: shareTemporaryDirectory)
        shareTemporaryDirectory = nil
    }
}

private struct ReviewControlGlass: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.45), .primary.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
                }
                .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
        }
    }
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

private struct DynamicIslandDeletionGlow: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(.black)
                .frame(width: 128, height: 37)
                .shadow(color: Color.red.opacity(0.58), radius: 9)
                .shadow(color: Color.red.opacity(0.34), radius: 18)
                .scaleEffect(0.96 + progress * 0.04)
                .opacity(progress)
                .position(x: proxy.size.width / 2, y: 30)
                .animation(.easeOut(duration: 0.08), value: progress)
        }
        .ignoresSafeArea()
    }
}

private struct DeletionReviewThumbnail: View {
    let asset: PHAsset
    let isSelected: Bool

    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?
    private let manager = PHImageManager.default()

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.secondary.opacity(0.08)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else {
                    ProgressView()
                        .tint(.secondary)
                }

                if asset.mediaType == .video {
                    VStack {
                        HStack {
                            Image(systemName: "video.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(7)
                                .background(.black.opacity(0.55), in: Circle())
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(7)
                }

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        ZStack {
                            Circle()
                                .fill(
                                    isSelected
                                        ? Color.green
                                        : Color.black.opacity(0.28)
                                )
                            Circle().stroke(.white, lineWidth: 2)
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: 28, height: 28)
                    }
                }
                .padding(8)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .opacity(isSelected ? 1 : 0.58)
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear(perform: loadThumbnail)
        .onDisappear(perform: cancelRequest)
    }

    private func loadThumbnail() {
        if let cachedImage = OfflineCacheService.shared.cachedImage(
            for: asset.localIdentifier
        ) {
            image = cachedImage
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
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
