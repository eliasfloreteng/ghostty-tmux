import SwiftUI

extension Ghostty {
    /// Covers a surface while it hosts a tmux control mode session.
    ///
    /// The host's terminal has nothing of its own to show while tmux is
    /// attached through it: everything tmux says to it is control mode, and
    /// the session's windows are open as tabs of their own. Typing into it
    /// goes nowhere either, since the core keeps it from reaching tmux as a
    /// command. Left alone it would show the `tmux -CC` it ran, looking like
    /// a terminal that has stopped responding. So say what it is, and offer
    /// what can be done from here.
    struct TmuxHostOverlay: View {
        let surfaceView: SurfaceView
        let session: String

        @EnvironmentObject private var ghostty: Ghostty.App

        var body: some View {
            ZStack {
                Rectangle()
                    .fill(ghostty.config.backgroundColor)

                VStack(spacing: 12) {
                    Image(systemName: "rectangle.split.3x1")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)

                    Text(title)
                        .font(.title2)
                        .multilineTextAlignment(.center)

                    Text("The session's windows are open in their own tabs. Detaching leaves it running in tmux.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button("Show Windows") {
                            guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
                            appDelegate.tmuxWindowManager.showWindows(hostedBy: surfaceView)
                        }

                        Button("Detach") {
                            surfaceView.tmuxDetach(nil)
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(20)
                .frame(maxWidth: 420)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding()
            }
            .accessibilityElement(children: .contain)
        }

        private var title: String {
            session.isEmpty ? "Attached to tmux" : "Attached to tmux session “\(session)”"
        }
    }
}
