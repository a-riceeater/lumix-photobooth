import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showPIN = false
    @State private var showSettings = false
    /// Set when the PIN was right; settings open once the PIN sheet has fully
    /// closed (presenting during the dismissal is silently dropped by SwiftUI).
    @State private var openSettingsAfterPIN = false

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

            OperatorAccess(showGear: model.settings.showSettingsButton && booth.phase == .welcome) {
                if !showPIN && !showSettings { showPIN = true }
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showPIN, onDismiss: {
            if openSettingsAfterPIN {
                openSettingsAfterPIN = false
                showSettings = true
            }
        }) {
            OperatorPINView(expected: model.settings.operatorPIN) {
                openSettingsAfterPIN = true
                showPIN = false
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

/// Ways into the operator settings (all lead to the PIN pad):
/// * hold the top-left corner for 1.5 s, or tap it 5 times quickly;
/// * the small gear on the welcome screen (operator setting, on by default).
/// The hotspot stays inside the safe area so the rounded screen corner and the
/// Notification Center swipe area don't swallow the touches.
private struct OperatorAccess: View {
    let showGear: Bool
    let open: () -> Void
    @State private var taps: [Date] = []

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: 120, height: 120)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 1.5) { open() }
                .simultaneousGesture(TapGesture().onEnded {
                    let now = Date()
                    taps = taps.filter { now.timeIntervalSince($0) < 3 } + [now]
                    if taps.count >= 5 {
                        taps.removeAll()
                        open()
                    }
                })
                .accessibilityHidden(true)
            if showGear {
                Button(action: open) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(width: 56, height: 56)
                        .contentShape(Rectangle())
                }
                .padding(8)
                .accessibilityLabel("Operator settings")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
