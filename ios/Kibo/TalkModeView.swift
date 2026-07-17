import SwiftUI

/// Immersive full-screen push-to-talk. The destination is locked — the
/// conversation you chose is displayed at the top, the giant mic is the
/// center of the screen, and "Ask Kibo" sits below it, so the flow reads
/// top → bottom: destination → talk → ask. One dynamic status line, no
/// persistent instructions.
struct TalkModeView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var audio: AudioCoordinator
    @StateObject private var session = ReplySession()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.kiboInk, Color.kiboInk.opacity(0.92), .black],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                VStack(spacing: 4) {
                    Text(store.selectedConversation?.name ?? "Conversation")
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    if let project = store.selectedProject {
                        Label(project.name, systemImage: "folder")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)

                GeometryReader { geometry in
                    let diameter = min(
                        260,
                        max(190, min(geometry.size.width, geometry.size.height) * 0.62)
                    )
                    MicButton(
                        diameter: diameter,
                        isRecording: audio.isRecording,
                        isHolding: audio.isHolding,
                        level: audio.level,
                        isEnabled: store.selectedConversationID != nil,
                        beginHold: { session.beginHold() },
                        endHold: { session.endHold() },
                        cancelHold: { session.cancelHold() },
                        askKibo: {
                            if store.askableClipCount > 0 {
                                session.startSubmit(afterCaptureEnded: true)
                            }
                        }
                    )
                    .frame(
                        width: geometry.size.width,
                        height: geometry.size.height
                    )
                }

                Text(statusLine)
                    .font(.footnote)
                    .foregroundStyle(statusIsError ? .red : .white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(minHeight: 36)
                    .padding(.horizontal, 24)
                    .padding(.top, 10)
                    .padding(.bottom, 24)
                    .accessibilityIdentifier("talk-mode-status")
            }
        }
        .preferredColorScheme(.dark)
        .replySessionDriver(session)
        .onDisappear {
            // Errors that occurred here were already shown in the status
            // line; clearing them on the way out prevents the global and
            // detail alerts from re-surfacing them, stale, after dismissal.
            store.errorMessage = nil
            audio.playbackErrorMessage = nil
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .accessibilityLabel("Close talk mode")
            .accessibilityIdentifier("talk-mode-close")
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var statusIsError: Bool {
        audio.recordingErrorMessage != nil
            || audio.playbackErrorMessage != nil
            || store.errorMessage != nil
    }

    /// Dynamic states only — never persistent instructional copy. Store
    /// errors (a failed ask, an upload that will retry) surface here too:
    /// this screen is the top of the stack, so nothing else can show them.
    private var statusLine: String {
        if let message = audio.recordingErrorMessage
            ?? audio.playbackErrorMessage
            ?? store.errorMessage {
            return message
        }
        if audio.isRecording || audio.isStarting || audio.isHolding {
            return "Listening…"
        }
        if store.isUploading {
            return "Sending…"
        }
        if audio.playingID?.hasPrefix("reply-") == true {
            return "Kibo is speaking"
        }
        if store.isAskingKibo || audio.loadingID?.hasPrefix("reply-") == true {
            return "Loading reply…"
        }
        if store.askableClipCount > 0 {
            return "\(store.askableClipCount) pending"
        }
        return ""
    }
}
