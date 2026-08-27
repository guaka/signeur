// Generates a QR code PNG for a nostrconnect:// pairing link, for manual scanner testing.
// Usage: swift Tools/make_pairing_qr.swift "nostrconnect://..." out.png

import AppKit
import CoreImage
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: swift Tools/make_pairing_qr.swift <payload> <output.png>")
    exit(1)
}

let payload = arguments[1]
let outputPath = arguments[2]

guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
    print("CIQRCodeGenerator unavailable")
    exit(1)
}
filter.setValue(Data(payload.utf8), forKey: "inputMessage")
filter.setValue("M", forKey: "inputCorrectionLevel")

guard let output = filter.outputImage else {
    print("could not render QR code")
    exit(1)
}

let scale: CGFloat = 12
let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
let representation = NSCIImageRep(ciImage: scaled)
let image = NSImage(size: representation.size)
image.addRepresentation(representation)

guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    print("could not encode PNG")
    exit(1)
}

try png.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath) for \(payload)")
