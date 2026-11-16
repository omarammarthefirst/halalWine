import HalalWineCore
import SwiftUI

struct GameDetailView: View {
    let game: GameRecord
    @Environment(AppModel.self) private var model
    @State private var confirmBlocked = false
    @State private var confirmRemove = false
    @State private var extraArguments = ""
    @State private var exportingDiagnostics = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if !game.report.redFlags.isEmpty { warnings }
                playArea
                howItRuns
                advanced
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { extraArguments = game.extraArguments.joined(separator: " ") }
        .confirmationDialog(L("game.blocked.title"), isPresented: $confirmBlocked) {
            Button(L("game.blocked.tryAnyway")) { model.play(game.id) }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(game.report.redFlags.filter(\.blocksPlay).map(\.message).joined(separator: "\n"))
        }
        .confirmationDialog(L("game.remove.title", game.name), isPresented: $confirmRemove) {
            if game.isManagedCopy {
                Button(L("game.remove.withFiles"), role: .destructive) { model.remove(game.id, deleteFiles: true) }
            }
            Button(L("game.remove.keepFiles"), role: .destructive) { model.remove(game.id, deleteFiles: false) }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("game.remove.message"))
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            GameIcon(id: game.id, size: 96)
            VStack(alignment: .leading, spacing: 8) {
                Text(game.name)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Badge(text: engineText, systemImage: "shippingbox")
                    if let api = game.report.graphicsAPIs.first, api != .unknown {
                        Badge(text: api.displayName, systemImage: "display")
                    }
                    if game.report.isDotNet { Badge(text: ".NET") }
                    if game.report.architecture == .x86 { Badge(text: "32-bit") }
                }
                Text(game.report.executable)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    private var engineText: String {
        [game.report.engine.displayName, game.report.engineVersion].compactMap { $0 }.joined(separator: " ")
    }

    private var warnings: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(game.report.redFlags, id: \.self) { flag in
                Label {
                    Text(flag.message).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: flag.blocksPlay ? "xmark.octagon.fill" : "info.circle.fill")
                        .foregroundStyle(flag.blocksPlay ? .red : .orange)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var playArea: some View {
        if model.installersRunning.contains(game.id) {
            StatusCard(systemImage: "shippingbox", tint: .accentColor, title: L("installer.running.title"),
                       message: L("installer.running.message"), showsProgress: true)
        } else if game.report.kind == .installer {
            HStack {
                Text(L("installer.notInstalled")).foregroundStyle(.secondary)
                Spacer()
                Button(L("installer.run")) { Task { await model.runInstaller(game.id) } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        } else if let controller = model.controllers[game.id], controller.phase != .idle {
            LaunchStatusView(controller: controller, game: game)
        } else {
            Button {
                if game.report.redFlags.contains(where: \.blocksPlay) {
                    confirmBlocked = true
                } else {
                    model.play(game.id)
                }
            } label: {
                Label(L("game.play"), systemImage: "play.fill")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.runtime == nil || game.isMissing)
            if game.isMissing {
                Label(L("game.missing"), systemImage: "questionmark.folder")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var howItRuns: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if let working = game.history.working {
                    Label(L("game.works.title"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.headline)
                    Text(working.summary)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    Text(working.backend.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Label(L("game.auto.title"), systemImage: "wand.and.stars")
                        .font(.headline)
                    Text(L("game.auto.message"))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var advanced: some View {
        DisclosureGroup(L("game.advanced")) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(L("game.windowed"), isOn: Binding(
                    get: { game.preferWindowed },
                    set: { value in model.update(game.id) { $0.preferWindowed = value } }))
                Toggle(L("game.avx"), isOn: Binding(
                    get: { game.advertiseAVX },
                    set: { value in model.update(game.id) { $0.advertiseAVX = value } }))
                HStack {
                    TextField(L("game.arguments"), text: $extraArguments)
                        .textFieldStyle(.roundedBorder)
                        .environment(\.layoutDirection, .leftToRight)
                        .onSubmit(saveArguments)
                    Button(L("common.save"), action: saveArguments)
                }

                Text(L("game.plan.title")).font(.headline)
                let plan = model.plan(for: game)
                ForEach(Array(plan.configs.enumerated()), id: \.element.key) { index, config in
                    HStack {
                        Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                        Image(systemName: icon(for: config)).foregroundStyle(color(for: config))
                        Text(config.summary)
                            .font(.callout.monospaced())
                            .environment(\.layoutDirection, .leftToRight)
                        Spacer()
                        Button(L("game.plan.try")) { model.play(game.id, forcing: config) }
                            .disabled(model.controllers[game.id]?.isActive == true)
                    }
                }
                ForEach(plan.unavailable, id: \.key) { config in
                    HStack {
                        Image(systemName: "lock").foregroundStyle(.secondary)
                        Text(config.summary).font(.callout.monospaced()).foregroundStyle(.secondary)
                            .environment(\.layoutDirection, .leftToRight)
                        Spacer()
                        Text(L("game.plan.needsD3DMetal")).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Divider()
                HStack(spacing: 10) {
                    Button(L("game.reset")) { model.resetLearnedSettings(game.id) }
                    Button(L("game.openDriveC")) {
                        NSWorkspace.shared.open(model.paths.prefix(for: game.id).appendingPathComponent("drive_c"))
                    }
                    Button(L("game.showLog")) {
                        let log = model.paths.logs.appendingPathComponent("\(game.id.uuidString).log")
                        if FileManager.default.fileExists(atPath: log.path) { NSWorkspace.shared.open(log) }
                    }
                }
                HStack(spacing: 10) {
                    Button(L("game.showInFinder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([game.executableURL])
                    }
                    Button(exportingDiagnostics ? L("game.diagnostics.working") : L("game.diagnostics")) { exportDiagnostics() }
                        .disabled(exportingDiagnostics)
                    Spacer()
                    Button(L("game.remove"), role: .destructive) { confirmRemove = true }
                }
            }
            .padding(.top, 10)
        }
    }

    // MARK: Helpers

    private func saveArguments() {
        let parts = extraArguments.split(separator: " ").map(String.init)
        model.update(game.id) { $0.extraArguments = parts }
    }

    private func icon(for config: LaunchConfig) -> String {
        if game.history.working?.key == config.key { return "checkmark.circle.fill" }
        if game.history.failedKeys.contains(config.key) { return "xmark.circle" }
        return "circle"
    }

    private func color(for config: LaunchConfig) -> Color {
        if game.history.working?.key == config.key { return .green }
        if game.history.failedKeys.contains(config.key) { return .red }
        return .secondary
    }

    private func exportDiagnostics() {
        exportingDiagnostics = true
        Task {
            defer { exportingDiagnostics = false }
            do {
                let zip = try await Diagnostics.export(game: game, plan: model.plan(for: game), model: model)
                NSWorkspace.shared.activateFileViewerSelecting([zip])
            } catch {
                model.errorMessage = L("error.diagnostics", error.localizedDescription)
            }
        }
    }
}
