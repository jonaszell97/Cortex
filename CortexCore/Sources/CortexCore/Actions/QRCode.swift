import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// QR codes with CoreImage, rendered as a crisp PNG.
public enum QRCode {
    /// - Parameter moduleSize: Pixels per QR module.
    public static func png(for text: String, moduleSize: Int = 12) throws -> Data {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            throw QuickActionError("CoreImage has no QR code generator")
        }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let code = filter.outputImage else {
            throw QuickActionError("Too much text for a QR code (\(text.utf8.count) bytes, at most about 2,300)")
        }
        // A quiet zone of four modules, as the standard asks for.
        let scaled = code.transformed(by: CGAffineTransform(scaleX: CGFloat(moduleSize), y: CGFloat(moduleSize)))
        let margin = CGFloat(4 * moduleSize)
        let extent = scaled.extent.insetBy(dx: -margin, dy: -margin)
        let white = CIImage(color: .white).cropped(to: extent)
        let image = scaled.composited(over: white)

        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(image, from: extent) else {
            throw QuickActionError("Could not render the QR code")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw QuickActionError("Could not encode the QR code")
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw QuickActionError("Could not encode the QR code") }
        return output as Data
    }
}
