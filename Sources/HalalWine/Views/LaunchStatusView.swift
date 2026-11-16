import HalalWineCore
import SwiftUI

/// Live status while halalWine looks for working settings.
struct LaunchStatusView: View {
    let controller: LaunchController
    let game: GameRecord
    @Environment(AppModel.self) private var model

    var body: some View {
        switch controller.phase {
        case .idle:
            EmptyView()
        case .preparing:
            StatusCard(systemImage: "gearshape.2", tint: .accentColor, title: L("launch.preparing.title"),
                       message: L("launch.preparing.message"), showsProgress: true) { stopButton }
        case .installing(let dependency):
            StatusCard(systemImage: "shippingbox", tint: .accentColor, title: L("launch.installing.title"),
                       message: L("launch.installing.message", dependency.displayName), showsProgress: true) { stopButton }
        case .starting(let attempt, let total), .checking(let attempt, let total):
            StatusCard(systemImage: "wand.and.stars", tint: .accentColor, title: L("launch.searching.title"),
                       message: attemptText(attempt, total), showsProgress: true) { stopButton }
        case .confirm(let attempt, let total):
            StatusCard(systemImage: "questionmark.bubble", tint: .accentColor, title: L("launch.confirm.title"),
                       message: L("launch.confirm.message") + "\n" + attemptText(attempt, total)) {
                Button(L("launch.confirm.yes")) { controller.answer(true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button(L("launch.confirm.no")) { controller.answer(false) }
            }
        case .running:
            StatusCard(systemImage: "play.circle.fill", tint: .green, title: L("launch.running.title"),
                       message: L("launch.running.message")) { stopButton }
        case .finished:
            StatusCard(systemImage: "checkmark.circle.fill", tint: .green, title: L("launch.finished.title"),
                       message: L("launch.finished.message")) {
                Button(L("game.play")) { controller.dismiss(); model.play(game.id) }
                    .buttonStyle(.borderedProminent)
                Button(L("common.close")) { controller.dismiss() }
            }
        case .failed:
            StatusCard(systemImage: "exclamationmark.triangle.fill", tint: .orange, title: L("launch.failed.title"),
                       message: failureMessage) {
                Button(L("common.tryAgain")) {
                    controller.dismiss()
                    model.resetLearnedSettings(game.id)
                    model.play(game.id)
                }
                Button(L("common.close")) { controller.dismiss() }
            }
        case .blocked(let reason):
            StatusCard(systemImage: "hand.raised.fill", tint: .red, title: L("launch.blocked.title"),
                       message: blockedMessage(reason)) {
                Button(L("common.close")) { controller.dismiss() }
            }
        }
    }

    private var stopButton: some View {
        Button(L("launch.stop"), role: .destructive) { controller.stop() }
    }

    private func attemptText(_ attempt: Int, _ total: Int) -> String {
        var text = L("launch.attempt", "\(attempt)", "\(total)")
        if let config = controller.currentConfig { text += " — " + config.backend.displayName }
        return text
    }

    private var failureMessage: String {
        var text = L("launch.failed.message")
        if let diagnosis = controller.lastDiagnosis { text += "\n\n" + diagnosis.message }
        return text
    }

    private func blockedMessage(_ reason: LaunchController.BlockReason) -> String {
        switch reason {
        case .needsSteam: return L("launch.blocked.steam")
        case .antiCheat: return L("launch.blocked.antiCheat")
        case .noRuntime: return L("launch.blocked.noRuntime")
        case .missingFiles: return L("launch.blocked.missingFiles")
        }
    }
}

struct StatusCard<Actions: View>: View {
    let systemImage: String
    let tint: Color
    let title: String
    let message: String
    var showsProgress = false
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 30))
                .foregroundStyle(tint)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(title).font(.headline)
                    if showsProgress { ProgressView().controlSize(.small) }
                }
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) { actions() }
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
}

extension StatusCard where Actions == EmptyView {
    init(systemImage: String, tint: Color, title: String, message: String, showsProgress: Bool = false) {
        self.init(systemImage: systemImage, tint: tint, title: title, message: message, showsProgress: showsProgress) { EmptyView() }
    }
}
