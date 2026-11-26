import SwiftUI

/// Fullscreen liveview. The camera image stays in its native 3:2 landscape
/// orientation; the device may be in any orientation. Mirroring affects only
/// this preview, never saved photos.
struct CameraPreviewView: View {
    let feed: PreviewFeed
    var mirrored: Bool
    var fill: Bool
    var showGuides: Bool

    var body: some View {
        GeometryReader { geo in
            if let image = feed.image {
                let aspect = CGFloat(image.width) / CGFloat(max(1, image.height))
                let rect = Self.imageRect(container: geo.size, aspect: aspect, fill: fill)
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: rect.width, height: rect.height)
                        .scaleEffect(x: mirrored ? -1 : 1, y: 1)
                        .offset(x: rect.minX, y: rect.minY)
                    if showGuides {
                        FramingGuides()
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
            } else {
                VStack(spacing: 16) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text("Getting the camera ready…")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black)
        .accessibilityHidden(true)
    }

    /// Where the camera frame is drawn: fitted (whole capture visible) or filled (cropped edges).
    static func imageRect(container: CGSize, aspect: CGFloat, fill: Bool) -> CGRect {
        guard container.width > 0, container.height > 0 else { return .zero }
        let containerAspect = container.width / container.height
        let widthLimited = fill ? (containerAspect > aspect) : (containerAspect < aspect)
        let size = widthLimited
            ? CGSize(width: container.width, height: container.width / aspect)
            : CGSize(width: container.height * aspect, height: container.height)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

/// Rule-of-thirds lines and corner brackets marking the capture area.
struct FramingGuides: View {
    var body: some View {
        Canvas { ctx, size in
            var thirds = Path()
            for i in 1...2 {
                let x = size.width * CGFloat(i) / 3
                let y = size.height * CGFloat(i) / 3
                thirds.move(to: CGPoint(x: x, y: 0)); thirds.addLine(to: CGPoint(x: x, y: size.height))
                thirds.move(to: CGPoint(x: 0, y: y)); thirds.addLine(to: CGPoint(x: size.width, y: y))
            }
            ctx.stroke(thirds, with: .color(.white.opacity(0.22)), lineWidth: 1)

            let inset: CGFloat = min(size.width, size.height) * 0.04
            let len: CGFloat = min(size.width, size.height) * 0.08
            var corners = Path()
            let r = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
            for (p, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                                (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0)] {
                corners.move(to: CGPoint(x: p.x + dx * len, y: p.y))
                corners.addLine(to: p)
                corners.addLine(to: CGPoint(x: p.x, y: p.y + dy * len))
            }
            ctx.stroke(corners, with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        }
    }
}

/// White flash on every capture.
struct FlashOverlay: View {
    let counter: Int
    @State private var opacity = 0.0

    var body: some View {
        Color.white
            .opacity(opacity)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .onChange(of: counter) {
                opacity = 0.95
                withAnimation(.easeOut(duration: 0.6)) { opacity = 0 }
            }
    }
}

/// Large, high-contrast button for guests.
struct BigButtonStyle: ButtonStyle {
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 28, weight: .bold, design: .rounded))
            .padding(.horizontal, 44)
            .frame(minHeight: 84)
            .background(prominent ? Color.white : Color.white.opacity(0.18), in: Capsule())
            .foregroundStyle(prominent ? Color.black : Color.white)
            .overlay(Capsule().stroke(Color.white.opacity(prominent ? 0 : 0.6), lineWidth: 2))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}
