import AppKit
import SwiftUI
import JingXuCore

extension AppModel {
    func compareSelected() {
        guard selectedPhotoIDs.count == 2, operationBlockReason(.browse) == nil else { return }
        transitionPreview {
            self.isPreparingSelection = true
            Task {
                defer { self.isPreparingSelection = false }
                do {
                    let rows = try await self.resolveColorTargets()
                    guard rows.count == 2 else { return }
                    self.comparisonReference = rows[0]; self.presentPreview(rows[1])
                } catch { self.errorMessage = "无法比较：\(error.localizedDescription)" }
            }
        }
    }
    func compareSimilarGroup(_ id: String) {
        guard operationBlockReason(.browse) == nil, let store else { return }
        transitionPreview {
            self.isPreparingSelection = true
            Task {
                defer { self.isPreparingSelection = false }
                do {
                    let query = BrowseQuery(similarGroupID: id)
                    let page = try await store.browsePage(query, photosOnly: true, limit: 2)
                    guard page.items.count == 2 else { self.errorMessage = "相似组不足两张可比较照片"; return }
                    self.comparisonReturnQuery = self.appliedQuery
                    self.pendingQuery = query
                    await self.loadBrowsePage()
                    guard self.appliedQuery == query else { return }
                    self.comparisonReference = page.items[0]; self.presentPreview(page.items[1])
                } catch { self.errorMessage = "读取相似组失败：\(error.localizedDescription)" }
            }
        }
    }
    func promoteComparisonCandidate() {
        guard previewNavigationEnabled, let candidate = previewAsset, let store else { return }
        transitionPreview {
            self.isPreparingSelection = true
            Task {
                defer { self.isPreparingSelection = false }
                do {
                    let page = try await store.browsePage(self.appliedQuery, cursor: BrowseCursor(candidate), photosOnly: true, limit: 1)
                    guard let next = page.items.first else { self.statusText = "没有更多候选，当前比较保持不变"; return }
                    self.comparisonReference = candidate; self.previewAsset = next; await self.refreshPreviewWindow()
                } catch { self.errorMessage = "切换参考图失败：\(error.localizedDescription)" }
            }
        }
    }
    func leaveSimilarGroup() {
        transitionPreview {
            self.pendingQuery = self.comparisonReturnQuery ?? BrowseQuery()
            self.comparisonReturnQuery = nil
            self.clearComparisonPrefetch()
            Task { await self.loadBrowsePage() }
        }
    }
    func clearComparisonPrefetch() {
        comparisonPrefetchGeneration = UUID(); comparisonPrefetchTask?.cancel(); comparisonPrefetchTask = nil
        prefetchedComparison = nil; prefetchedComparisonKey = nil
    }
    func comparisonImage(_ item: AssetListItem) async throws -> PreviewImage {
        let key = "\(item.id)-\(item.fileVersion)-\(item.colorRevision)"
        if prefetchedComparisonKey == key, let prefetchedComparison {
            self.prefetchedComparison = nil; prefetchedComparisonKey = nil
            return prefetchedComparison
        }
        return try await loadOriginal(item)
    }
    func prefetchComparisonNext(from item: AssetListItem) {
        guard previewAsset?.id == item.id, comparisonReference != nil,
              let index = previewItems.firstIndex(where: { $0.id == item.id }),
              let next = previewItems.dropFirst(index + 1).first(where: { $0.id != comparisonReference?.id }) else { clearComparisonPrefetch(); return }
        let key = "\(next.id)-\(next.fileVersion)-\(next.colorRevision)"
        guard prefetchedComparisonKey != key else { return }
        clearComparisonPrefetch()
        let generation = comparisonPrefetchGeneration
        comparisonPrefetchTask = Task {
            do {
                let image = try await loadOriginal(next)
                guard !Task.isCancelled, comparisonPrefetchGeneration == generation, comparisonReference != nil else { return }
                prefetchedComparison = image; prefetchedComparisonKey = key
            } catch { /* The visible candidate owns error presentation when reached. */ }
        }
    }

}

struct ComparisonView: View {
    @EnvironmentObject private var model: AppModel
    @State private var linked = true
    @State private var transform = CanvasTransform()
    @State private var transformCommand = 0
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("返回网格") { model.closePreview() }
                if model.currentQuery().similarGroupID != nil { Button("返回原范围") { model.leaveSimilarGroup() } }
                Button("上一候选") { model.navigatePreview(-1) }.disabled(!model.canNavigatePreview(-1))
                Button("下一候选") { model.navigatePreview(1) }.disabled(!model.canNavigatePreview(1))
                Button("设为参考图") { model.promoteComparisonCandidate() }.disabled(!model.previewNavigationEnabled)
                Spacer()
                Toggle("同步缩放", isOn: $linked).toggleStyle(.checkbox)
                Button("适应") { transform = CanvasTransform(); transformCommand += 1 }
                Button("100%") { transform = CanvasTransform(fitted: false); transformCommand += 1 }
                Button("调色当前照片") {
                    model.transitionPreview { model.comparisonReference = nil; model.clearComparisonPrefetch(); model.beginColorEditing() }
                }.disabled(!model.canStartColorAction)
            }.padding(10)
            if let reference = model.comparisonReference, let candidate = model.previewAsset {
                HStack(spacing: 2) {
                    ComparisonPane(item: reference, title: "参考图", active: false, linked: linked, command: transformCommand, transform: $transform)
                    ComparisonPane(item: candidate, title: "当前候选 · 操作作用于此照片", active: true, linked: linked, command: transformCommand, transform: $transform)
                }
                HStack {
                    Text(candidate.fileName).lineLimit(1)
                    ForEach(1...5, id: \.self) { rating in
                        Button { model.updateRating(candidate.rating == rating ? 0 : rating) } label: {
                            Image(systemName: candidate.rating >= rating ? "star.fill" : "star").foregroundStyle(.yellow)
                        }
                    }
                    Button("淘汰并下一张") { model.updateFlag(.rejected, advanceToNext: true) }
                    Button("取消淘汰") { model.updateFlag(.none) }
                    TextField("关键词", text: $model.keywordDraft).onSubmit { Task { _ = await model.flushKeywords() } }
                    Button("保存关键词") { Task { _ = await model.flushKeywords() } }
                }.padding(10).disabled(model.operationBlockReason(.annotation) != nil)
                PreviewFilmstrip(items: model.previewFilmstrip, currentID: candidate.id)
            }
            Text(model.activeTaskSummary ?? model.statusText).font(.caption).foregroundStyle(.secondary).padding(6)
        }
        .background(.black).environment(\.colorScheme, .dark)
        .onExitCommand { model.closePreview() }
        .accessibilityIdentifier("comparison-view")
    }
}

private struct ComparisonPane: View {
    @EnvironmentObject private var model: AppModel
    let item: AssetListItem
    let title: String
    let active: Bool
    let linked: Bool
    let command: Int
    @Binding var transform: CanvasTransform
    @State private var image: PreviewImage?
    @State private var error: String?
    @State private var retry = 0
    var body: some View {
        VStack(spacing: 0) {
            Text(title + " · " + item.fileName).font(.caption).lineLimit(1).padding(8)
            ComparisonCanvas(image: image, assetID: item.id, linked: linked, command: command, transform: $transform) { model.closePreview() }
                .overlay {
                    if let error {
                        VStack(spacing: 8) {
                            Text(error).font(.caption).multilineTextAlignment(.center)
                            Button("重试") { retry += 1 }
                            Button("重新授权…") { model.reauthorizeThumbnailSource(item) }
                        }.padding(16).frame(maxWidth: 300).background(.regularMaterial)
                    } else if image == nil { ProgressView() }
                }
        }
        .overlay(Rectangle().stroke(active ? Color.accentColor : Color.gray, lineWidth: active ? 2 : 1).allowsHitTesting(false))
        .task(id: "\(item.id)-\(item.fileVersion)-\(item.colorRevision)-\(retry)") {
            image = nil; error = nil
            do {
                let loaded = try await model.comparisonImage(item)
                guard !Task.isCancelled else { return }
                image = loaded
                if active { model.prefetchComparisonNext(from: item) }
            } catch is CancellationError {} catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
        .onDisappear { image = nil }
    }
}

private struct ComparisonCanvas: NSViewRepresentable {
    let image: PreviewImage?
    let assetID: String
    let linked: Bool
    let command: Int
    @Binding var transform: CanvasTransform
    let exit: () -> Void
    final class Coordinator { var command = -1 }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PreviewCanvasView { PreviewCanvasView() }
    func updateNSView(_ view: PreviewCanvasView, context: Context) {
        view.onExit = exit
        view.setImage(image?.image, assetID: assetID, nativeSize: image?.nativeSize ?? .zero)
        if image != nil, linked || context.coordinator.command != command { view.applyTransform(transform); context.coordinator.command = command }
        view.onTransformChange = { value in if linked { transform = value } }
    }
    static func dismantleNSView(_ view: PreviewCanvasView, coordinator: Coordinator) {
        view.onTransformChange = nil; view.onExit = nil; view.clearImage()
    }
}
