import AppKit
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ImageEncoder {
    static func data(_ image: CGImage, type: UTType) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

enum OutputError: LocalizedError {
    case encodingFailed

    var errorDescription: String? { "The image couldn’t be encoded." }
}

enum Clipboard {
    static func copy(_ image: CGImage) async throws {
        // PNG for modern apps, TIFF for the ones that only read the legacy type.
        let (png, tiff) = await Task.detached(priority: .userInitiated) {
            (ImageEncoder.data(image, type: .png), ImageEncoder.data(image, type: .tiff))
        }.value
        guard let png else { throw OutputError.encodingFailed }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        if let tiff { pasteboard.setData(tiff, forType: .tiff) }
    }
}

enum ImageFile {
    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func saveNew(_ image: CGImage, in folder: URL, date: Date = .now) async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = uniqueURL(in: folder, date: date)
        try await write(image, to: url)
        return url
    }

    static func write(_ image: CGImage, to url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            guard let data = ImageEncoder.data(image, type: .png) else { throw OutputError.encodingFailed }
            try data.write(to: url, options: .atomic)
        }.value
    }

    static func uniqueURL(in folder: URL, date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stem = "Screenshot \(formatter.string(from: date))"

        var url = folder.appendingPathComponent(stem).appendingPathExtension("png")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(stem) \(counter)").appendingPathExtension("png")
            counter += 1
        }
        return url
    }
}
