import SwiftUI

/// Session review: show the shots, offer a retake, auto-accept after a timeout.
struct ReviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let booth = model.booth
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            VStack(spacing: 20) {
                Text("Looking great!")
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                let layout = landscape ? AnyLayout(HStackLayout(spacing: 16)) : AnyLayout(VStackLayout(spacing: 12))
                layout {
                    ForEach(Array(booth.thumbnails.enumerated()), id: \.offset) { _, img in
                        Image(decorative: img, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(radius: 8)
                    }
                }
                .frame(maxHeight: .infinity)
                .padding(.horizontal, 24)

                HStack(spacing: 20) {
                    if model.settings.allowRetake {
                        Button {
                            booth.retake()
                        } label: {
                            Label("Retake", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(BigButtonStyle(prominent: false))
                    }
                    Button {
                        booth.accept()
                    } label: {
                        Label("Looks great!", systemImage: "checkmark")
                    }
                    .buttonStyle(BigButtonStyle())
                }
                if let left = booth.autoAdvanceRemaining {
                    Text("Continuing automatically in \(left)s")
                        .font(.callout)
                        .opacity(0.7)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(.white)
            .padding(.vertical, 24)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black.ignoresSafeArea())
        .simultaneousGesture(TapGesture().onEnded { booth.noteActivity() })
    }
}
