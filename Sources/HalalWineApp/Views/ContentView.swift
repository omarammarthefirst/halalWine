import HalalWineCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.showSetup {
                SetupView()
            } else {
                LibraryView()
            }
        }
        .frame(minWidth: 880, minHeight: 600)
        .alert(L("error.title"), isPresented: Binding(get: { model.errorMessage != nil },
                                                      set: { if !$0 { model.errorMessage = nil } })) {
            Button(L("common.ok")) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// The game's icon from its .exe, or a placeholder.
struct GameIcon: View {
    let id: UUID
    var size: CGFloat = 48
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let image = NSImage(contentsOf: model.iconURL(for: id)) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .fill(LinearGradient(colors: [Color.accentColor.opacity(0.85), Color.accentColor.opacity(0.45)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: size * 0.45))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// Small rounded label.
struct Badge: View {
    let text: String
    var systemImage: String?

    var body: some View {
        Label {
            Text(text)
        } icon: {
            if let systemImage { Image(systemName: systemImage) }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
    }
}
