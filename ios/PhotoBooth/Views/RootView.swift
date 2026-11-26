import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showPIN = false
    @State private var showSettings = false

    var body: some View {
        let booth = model.booth
        ZStack {
            Color.black.ignoresSafeArea()
            Group {
                switch booth.phase {
                case .review:
                    ReviewView().transition(.opacity)
                case .share:
                    ShareView().transition(.move(edge: .trailing).combined(with: .opacity))
                default:
                    LiveStageView().transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.35), value: phaseGroup(booth.phase))

            FlashOverlay(counter: booth.flashCounter)

            StatusBadges()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(16)
                .allowsHitTesting(false)

            // Hidden operator access: press and hold the top-left corner for 3 seconds.
            Color.clear
                .frame(width: 90, height: 90)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 3) { showPIN = true }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .ignoresSafeArea()
                .accessibilityHidden(true)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showPIN) {
            OperatorPINView(expected: model.settings.operatorPIN) {
                showPIN = false
                showSettings = true
            }
            .presentationDetents([.large])
            .interactiveDismissDisabled(false)
        }
        .fullScreenCover(isPresented: $showSettings) {
            SettingsView()
        }
    }

    private func phaseGroup(_ p: BoothController.Phase) -> Int {
        switch p {
        case .review: return 1
        case .share: return 2
        default: return 0
        }
    }
}

/// Small, unobtrusive indicators: pending uploads, offline, camera issues.
private struct StatusBadges: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let pending = model.uploads.pending.count
        HStack(spacing: 10) {
            if !model.camera.state.isReady {
                badge("camera.fill", "Camera", .orange)
            }
            if !model.uploads.isOnline {
                badge("wifi.slash", "Offline", .orange)
            }
            if pending > 0 {
                badge("arrow.up.circle.fill", "\(pending)", .white.opacity(0.85))
            }
        }
        .font(.footnote.weight(.semibold))
    }

    private func badge(_ icon: String, _ text: String, _ color: Color) -> some View {
        Label(text, systemImage: icon)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.black.opacity(0.45), in: Capsule())
            .foregroundStyle(color)
    }
}

/// Numeric PIN pad guarding the operator settings. Locks out after repeated failures.
struct OperatorPINView: View {
    let expected: String
    let onSuccess: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var entered = ""
    @State private var failures = 0
    @State private var lockedUntil: Date?
    @State private var shake = false

    var body: some View {
        VStack(spacing: 28) {
            Text("Operator access").font(.title.bold())
            HStack(spacing: 16) {
                ForEach(0..<max(4, expected.count), id: \.self) { i in
                    Circle()
                        .fill(i < entered.count ? Color.primary : Color.secondary.opacity(0.3))
                        .frame(width: 18, height: 18)
                }
            }
            .offset(x: shake ? -12 : 0)
            .animation(.default.repeatCount(3, autoreverses: true).speed(4), value: shake)
            if let until = lockedUntil, until > Date() {
                Text("Too many attempts. Try again shortly.").foregroundStyle(.red)
            }
            let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "⌫"]
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(96), spacing: 18), count: 3), spacing: 18) {
                ForEach(keys, id: \.self) { k in
                    if k.isEmpty {
                        Color.clear.frame(height: 96)
                    } else {
                        Button { press(k) } label: {
                            Text(k).font(.system(size: 34, weight: .medium, design: .rounded))
                                .frame(width: 96, height: 96)
                                .background(Color.secondary.opacity(0.15), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button("Cancel") { dismiss() }.font(.title3)
        }
        .padding(32)
    }

    private func press(_ k: String) {
        if let until = lockedUntil, until > Date() { return }
        if k == "⌫" {
            if !entered.isEmpty { entered.removeLast() }
            return
        }
        entered.append(k)
        guard entered.count >= expected.count else { return }
        if entered == expected {
            onSuccess()
        } else {
            failures += 1
            entered = ""
            shake.toggle()
            if failures >= 5 { lockedUntil = Date().addingTimeInterval(30); failures = 0 }
        }
    }
}
