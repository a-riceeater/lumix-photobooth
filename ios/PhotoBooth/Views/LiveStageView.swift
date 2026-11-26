import SwiftUI

/// Liveview plus the overlay for the current capture phase.
struct LiveStageView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let booth = model.booth
        let settings = model.settings
        ZStack {
            CameraPreviewView(feed: model.camera.preview, mirrored: settings.mirrorPreview,
                              fill: settings.fillScreenPreview, showGuides: settings.showFramingGuides && booth.phase != .welcome)
                .ignoresSafeArea()

            switch booth.phase {
            case .welcome:
                WelcomeOverlay()
                    .transition(.opacity)
            case .countdown(let shot, let remaining):
                CountdownOverlay(shot: shot, total: booth.totalShots, remaining: remaining, message: booth.retryMessage)
            case .capturing(let shot):
                CaptureOverlay(shot: shot, total: booth.totalShots)
            case .showingShot(let shot):
                if shot < booth.thumbnails.count {
                    ShotPreviewOverlay(image: booth.thumbnails[shot], shot: shot, total: booth.totalShots)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            case .transferring(let received, let total):
                TransferOverlay(received: received, total: total)
                    .transition(.opacity)
            case .problem(let message):
                ProblemOverlay(message: message) { booth.finish() }
                    .transition(.opacity)
            default:
                EmptyView()
            }

            if booth.phase != .welcome, !isShowingShot(booth.phase), !booth.thumbnails.isEmpty {
                VStack {
                    Spacer()
                    ShotStrip(images: booth.thumbnails, total: booth.totalShots)
                        .padding(.bottom, 24)
                }
                .allowsHitTesting(false)
            }
        }
    }
}

private func isShowingShot(_ p: BoothController.Phase) -> Bool {
    if case .showingShot = p { return true }
    return false
}

/// The photo just taken, large, before the next countdown.
private struct ShotPreviewOverlay: View {
    let image: CGImage
    let shot: Int
    let total: Int

    var body: some View {
        VStack(spacing: 16) {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white, lineWidth: 6))
                .shadow(radius: 20)
                .padding(.horizontal, 32)
            Text(shot + 1 < total ? "Nice! Get ready for photo \(shot + 2)…" : "That's a wrap!")
                .font(.title.weight(.bold))
                .foregroundStyle(.white)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.75))
    }
}

private struct WelcomeOverlay: View {
    @Environment(AppModel.self) private var model

    private var notReadyText: String {
        if case .busy(let what) = model.camera.state { return what }
        return "Camera warming up…"
    }

    var body: some View {
        let s = model.settings
        let ready = model.camera.state.isReady
        VStack(spacing: 24) {
            Spacer()
            VStack(spacing: 8) {
                Text(s.eventName)
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.5)
                    .lineLimit(2)
                Text(s.welcomeMessage.isEmpty
                     ? "We'll take \(model.booth.totalShots) photo\(model.booth.totalShots == 1 ? "" : "s") — get ready to pose!"
                     : s.welcomeMessage)
                    .font(.title3.weight(.medium))
                    .opacity(0.9)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 10)
            .padding(.horizontal, 24)

            Button {
                model.booth.start()
            } label: {
                Label(ready ? "Start" : notReadyText, systemImage: ready ? "camera.fill" : "hourglass")
                    .frame(minWidth: 220)
            }
            .buttonStyle(BigButtonStyle())
            .disabled(!ready)
            .opacity(ready ? 1 : 0.6)
            .accessibilityHint("Starts the countdown for the first photo")
            Spacer().frame(height: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        )
    }
}

private struct CountdownOverlay: View {
    let shot: Int
    let total: Int
    let remaining: Int
    let message: String?

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 12) {
                Text("Photo \(shot + 1) of \(total)")
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background(.black.opacity(0.45), in: Capsule())
                if let message {
                    Text(message).font(.title3.weight(.semibold))
                }
                Text("\(remaining)")
                    .font(.system(size: min(geo.size.width, geo.size.height) * 0.45, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .shadow(color: .black.opacity(0.55), radius: 18)
                    .id(remaining)
                    .transition(.scale(scale: 1.6).combined(with: .opacity))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: remaining)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Photo \(shot + 1) of \(total) in \(remaining)")
        }
    }
}

/// Wi-Fi camera: fetching the session's photos from the card.
private struct TransferOverlay: View {
    let received: Int
    let total: Int

    var body: some View {
        VStack(spacing: 20) {
            if received == 0 {
                // The camera is switching modes and finding the photos.
                ProgressView().controlSize(.large).tint(.white)
            } else {
                ProgressView(value: Double(received), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .frame(maxWidth: 360)
            }
            Text(received == 0 ? "Getting your photos from the camera…" : "Bringing your photos over…")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
            if received > 0 {
                Text("\(received) of \(total)")
                    .font(.title2.monospacedDigit())
                    .opacity(0.8)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: received)
        .foregroundStyle(.white)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.75))
        .accessibilityElement(children: .combine)
    }
}

private struct CaptureOverlay: View {
    let shot: Int
    let total: Int

    var body: some View {
        Text("Smile!")
            .font(.system(size: 72, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProblemOverlay: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "camera.badge.ellipsis")
                .font(.system(size: 64))
            Text(message)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("OK", action: dismiss).buttonStyle(BigButtonStyle())
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.7))
    }
}

/// Thumbnails of the shots taken so far.
struct ShotStrip: View {
    let images: [CGImage]
    let total: Int

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<total, id: \.self) { i in
                Group {
                    if i < images.count {
                        Image(decorative: images[i], scale: 1).resizable().scaledToFill()
                    } else {
                        Color.white.opacity(0.15)
                    }
                }
                .frame(width: 96, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.8), lineWidth: 2))
            }
        }
        .padding(10)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }
}
