import HalalWineCore
import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                Section(L("library.title")) {
                    ForEach(model.games) { game in
                        GameRow(game: game)
                            .tag(game.id)
                            .contextMenu {
                                Button(L("game.play")) { model.play(game.id) }
                                Button(L("game.showInFinder")) {
                                    NSWorkspace.shared.activateFileViewerSelecting([game.executableURL])
                                }
                                Divider()
                                Button(L("game.remove"), role: .destructive) { model.remove(game.id, deleteFiles: false) }
                            }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
            .safeAreaInset(edge: .bottom) {
                Button {
                    model.presentOpenPanel()
                } label: {
                    Label(L("library.add"), systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .padding(12)
            }
        } detail: {
            if let id = model.selection, let game = model.game(id) {
                GameDetailView(game: game)
                    .id(id)
            } else {
                DropZone()
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, dash: [12, 8]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    .padding(8)
                    .overlay(Text(L("library.drop.release")).font(.title2.weight(.semibold)))
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if let name = model.importingName {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(L("library.importing", name))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(20)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.addItems(urls)
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 }
    }
}

private struct GameRow: View {
    let game: GameRecord
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            GameIcon(id: game.id, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(game.name).lineLimit(1)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var status: String {
        if model.controllers[game.id]?.isActive == true { return L("library.status.running") }
        if model.installersRunning.contains(game.id) { return L("library.status.installing") }
        if game.isMissing { return L("library.status.missing") }
        if game.history.working != nil { return L("library.status.ready") }
        return game.report.engine.displayName
    }
}

/// Shown when nothing is selected: the big "drop your game here" area.
struct DropZone: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            Text(L("library.drop.title"))
                .font(.title.weight(.semibold))
            Text(L("library.drop.subtitle"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button(L("library.add")) { model.presentOpenPanel() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                .padding(24)
        }
    }
}
