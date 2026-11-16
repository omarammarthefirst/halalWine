import HalalWineCore
import SwiftUI

/// First-run setup, like WhiskyWine: Rosetta, then the Windows runtime.
struct SetupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            Image(systemName: icon)
                .font(.system(size: 64, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .frame(height: 80)
            VStack(spacing: 10) {
                Text(title)
                    .font(.largeTitle.weight(.semibold))
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
                .frame(maxWidth: 420)
            if let error = model.setup.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
            Spacer(minLength: 0)
            StepDots(current: model.setup.step)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private var icon: String {
        switch model.setup.step {
        case .welcome: return "macwindow.on.rectangle"
        case .rosetta: return "cpu"
        case .runtime: return "arrow.down.circle"
        case .done: return "checkmark.seal.fill"
        }
    }

    private var title: String {
        switch model.setup.step {
        case .welcome: return L("setup.welcome.title")
        case .rosetta: return L("setup.rosetta.title")
        case .runtime: return L("setup.runtime.title")
        case .done: return L("setup.done.title")
        }
    }

    private var subtitle: String {
        switch model.setup.step {
        case .welcome: return L("setup.welcome.subtitle")
        case .rosetta: return L("setup.rosetta.subtitle")
        case .runtime: return L("setup.runtime.subtitle")
        case .done: return L("setup.done.subtitle")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.setup.step {
        case .welcome:
            Button(L("setup.welcome.start")) { model.beginSetup() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        case .rosetta:
            if model.setup.isWorking {
                ProgressView(L("setup.rosetta.installing"))
            } else {
                Button(L("setup.rosetta.install")) { model.installRosetta() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        case .runtime:
            VStack(spacing: 12) {
                if model.setup.isWorking {
                    if let fraction = model.setup.fraction {
                        ProgressView(value: fraction)
                        Text(L("setup.runtime.progress",
                               ByteCountFormatter.string(fromByteCount: model.setup.received, countStyle: .file),
                               ByteCountFormatter.string(fromByteCount: model.setup.expected, countStyle: .file)))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                        Text(phaseText).foregroundStyle(.secondary)
                    }
                } else {
                    Button(model.setup.error == nil ? L("setup.runtime.download") : L("common.tryAgain")) {
                        model.installRuntime()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        case .done:
            Button(L("setup.done.open")) { model.finishSetup() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var phaseText: String {
        switch model.setup.phase {
        case .downloading: return L("setup.runtime.connecting")
        case .installing: return L("setup.runtime.installing")
        case .preparing: return L("setup.runtime.preparing")
        case .idle: return ""
        }
    }
}

private struct StepDots: View {
    let current: SetupProgress.Step
    private let steps: [SetupProgress.Step] = [.welcome, .rosetta, .runtime, .done]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(steps.indices, id: \.self) { i in
                Circle()
                    .fill(i <= (steps.firstIndex(of: current) ?? 0) ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
    }
}
