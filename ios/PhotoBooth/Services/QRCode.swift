import CoreImage
import CoreImage.CIFilterBuiltins

enum QRCode {
    private static let context = CIContext()

    /// A crisp QR code (1 module = 1 pixel; scale it with interpolation off).
    static func image(for text: String, correction: String = "M") -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = correction
        guard let output = filter.outputImage else { return nil }
        return context.createCGImage(output, from: output.extent)
    }
}
