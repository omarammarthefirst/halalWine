import HalalWineCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label(L("settings.general"), systemImage: "gearshape") }
            GraphicsSettings()
                .tabItem { Label(L("settings.graphics"), systemImage: "display") }
            RuntimeSettings()
                .tabItem { Label(L("settings.runtime"), systemImage: "shippingbox") }
            AboutSettings()
                .tabItem { Label(L("settings.about"), systemImage: "info.circle") }
        }
        .frame(width: 560, height: 420)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Prefs.keepGamesInLibrary) private var keepGames = true
    @State private var language = AppLanguage.selected
    @State private var needsRestart = false

    var body: some View {
        Form {
            Picker(L("settings.language"), selection: $language) {
                ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: language) { _, value in
                AppLanguage.select(value)
                needsRestart = true
            }
            if needsRestart {
                HStack {
                    Text(L("settings.language.restart")).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("settings.language.restartNow")) { NSWorkspace.shared.relaunchApp() }
                }
            }
            Toggle(L("settings.keepGames"), isOn: $keepGames)
            Text(L("settings.keepGames.help"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct GraphicsSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.blackScreenDetection) private var blackScreenDetection = false
    @AppStorage(Prefs.metalHUD) private var metalHUD = false

    var body: some View {
        Form {
            Section(L("settings.d3dmetal")) {
                if model.runtime?.hasD3DMetal == true {
                    Label(L("settings.d3dmetal.installed"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button(L("settings.d3dmetal.remove"), role: .destructive) { model.removeD3DMetal() }
                } else {
                    Text(L("settings.d3dmetal.about"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Link(L("settings.d3dmetal.download"),
                             destination: URL(string: "https://developer.apple.com/download/all/?q=game%20porting%20toolkit")!)
                        Spacer()
                        if model.d3dmetalImporting {
                            ProgressView().controlSize(.small)
                        } else {
                            Button(L("settings.d3dmetal.import")) { model.importD3DMetal() }
                                .disabled(model.runtime == nil)
                        }
                    }
                }
            }
            Section(L("settings.checks")) {
                Toggle(L("settings.blackScreen"), isOn: $blackScreenDetection)
                    .onChange(of: blackScreenDetection) { _, on in
                        if on, !BlackFrameDetector.hasPermission { BlackFrameDetector.requestPermission() }
                    }
                Text(L("settings.blackScreen.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(L("settings.metalHUD"), isOn: $metalHUD)
            }
        }
        .formStyle(.grouped)
    }
}

private struct RuntimeSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            if let runtime = model.runtime {
                LabeledContent(L("settings.runtime.version"), value: runtime.info.version)
                LabeledContent("Wine", value: runtime.info.wineVersion)
                LabeledContent(L("settings.runtime.backends"),
                               value: runtime.availableBackends.sorted().map(\.displayName).joined(separator: ", "))
            } else {
                Text(L("settings.runtime.none"))
            }
            if let update = model.availableRuntimeUpdate {
                HStack {
                    Text(L("settings.runtime.update", update.version))
                    Spacer()
                    Button(L("settings.runtime.updateNow")) {
                        model.setup.step = .runtime
                        model.showSetup = true
                        model.installRuntime()
                    }
                }
            }
            HStack {
                Button(L("settings.runtime.check")) { Task { await model.checkForRuntimeUpdate() } }
                Spacer()
                Button(L("settings.runtime.openFolder")) { NSWorkspace.shared.open(model.paths.root) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)
            Text(L("app.name")).font(.title.weight(.semibold))
            Text(L("settings.about.version", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"))
                .foregroundStyle(.secondary)
            Text(L("settings.about.credits"))
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            Link(L("settings.about.source"), destination: URL(string: "https://github.com/omarammarthefirst/halalWine")!)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
