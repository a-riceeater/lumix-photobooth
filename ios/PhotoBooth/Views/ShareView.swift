import SwiftUI

/// QR code + instructions + optional email, then back to the welcome screen.
struct ShareView: View {
    @Environment(AppModel.self) private var model
    @State private var showEmail = false

    var body: some View {
        let booth = model.booth
        let session = booth.currentSession
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let qrSide = min(min(geo.size.width, geo.size.height) * (landscape ? 0.62 : 0.5), 520)
            let layout = landscape ? AnyLayout(HStackLayout(spacing: 48)) : AnyLayout(VStackLayout(spacing: 28))
            layout {
                QRCodeView(text: session?.galleryURL?.absoluteString ?? "")
                    .frame(width: qrSide, height: qrSide)
                    .accessibilityLabel("QR code linking to your photos")

                VStack(alignment: landscape ? .leading : .center, spacing: 18) {
                    Text("Get your photos!")
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                    Text("Scan the code with your phone's camera to view and download your photos and photo strip.")
                        .font(.title3)
                        .multilineTextAlignment(landscape ? .leading : .center)
                        .fixedSize(horizontal: false, vertical: true)
                    UploadStatusLine(session: session, online: model.uploads.isOnline)
                    ForEach(session?.emails ?? []) { e in
                        Label("We'll email the link to \(e.masked)", systemImage: "envelope.fill")
                            .font(.callout)
                    }
                    HStack(spacing: 16) {
                        if model.settings.offerEmail {
                            Button {
                                showEmail = true
                                booth.noteActivity()
                            } label: {
                                Label("Email me", systemImage: "envelope")
                            }
                            .buttonStyle(BigButtonStyle(prominent: false))
                        }
                        Button("Done") { booth.finish() }
                            .buttonStyle(BigButtonStyle())
                    }
                    if let left = booth.autoAdvanceRemaining {
                        Text("Returning to the start in \(left)s")
                            .font(.callout).opacity(0.7).monospacedDigit()
                    }
                }
                .frame(maxWidth: 560)
            }
            .foregroundStyle(.white)
            .padding(32)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black.ignoresSafeArea())
        .simultaneousGesture(TapGesture().onEnded { booth.noteActivity() })
        .sheet(isPresented: $showEmail) {
            EmailEntryView { address in
                booth.noteActivity()
                return booth.submitEmail(address)
            }
            .presentationDetents([.medium, .large])
        }
    }
}

private struct UploadStatusLine: View {
    let session: LocalSession?
    let online: Bool

    var body: some View {
        let (icon, text): (String, String) = {
            guard let s = session else { return ("hourglass", "Preparing your photos…") }
            switch s.state {
            case .synced: return ("checkmark.circle.fill", "Your photos are online and ready.")
            case .capturing, .ready, .failed:
                if !online { return ("wifi.slash", "We're offline right now — your photos are saved and will appear at this link as soon as we're back online.") }
                return ("arrow.up.circle", "Uploading \(s.uploadedCount) of \(s.photoCount)… If the page says \"on their way\", give it a minute.")
            }
        }()
        Label(text, systemImage: icon)
            .font(.callout.weight(.medium))
            .padding(12)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct QRCodeView: View {
    let text: String

    var body: some View {
        if let img = QRCode.image(for: text) {
            Image(decorative: img, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(24)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 24))
        } else {
            RoundedRectangle(cornerRadius: 24).fill(.white.opacity(0.1))
        }
    }
}

/// Email capture sheet. Validates locally; delivery happens server-side.
struct EmailEntryView: View {
    let submit: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("We'll send you a link to your photos. Your address is only used for this email.")
                    .font(.title3)
                TextField("you@example.com", text: $address)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .font(.title2)
                    .padding(16)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    .focused($focused)
                    .onSubmit(send)
                if invalid {
                    Text("That doesn't look like an email address.").foregroundStyle(.red)
                }
                Button(action: send) {
                    Text("Send me the link").frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.borderedProminent)
                .font(.title3.weight(.semibold))
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
            }
            .padding(24)
            .navigationTitle("Email my photos")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { focused = true }
        }
    }

    private func send() {
        if submit(address) {
            dismiss()
        } else {
            invalid = true
        }
    }
}
