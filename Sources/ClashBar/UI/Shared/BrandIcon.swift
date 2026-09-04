import AppKit

enum BrandIconState {
    case running
    case stopped
}

@MainActor
enum BrandIcon {
    private static let resourceSubdirectory = "Brand"
    private static let resourceExtension = "png"
    private static let templateRenderScales: [CGFloat] = [1, 2, 3]

    static let image: NSImage? = loadImage(named: "clashbar-icon")

    static func templateStatusImage(for state: BrandIconState, pointSize: CGFloat) -> NSImage? {
        let cacheKey = CacheKey(state: state, pointSize: pointSize)
        if let cached = self.templateStatusImages.object(forKey: cacheKey) {
            return cached
        }

        guard let source = self.sourceImage(for: state) else { return nil }
        let targetSize = NSSize(width: pointSize, height: pointSize)
        let rendered = NSImage(size: targetSize)

        for scale in self.templateRenderScales {
            guard let representation = self.makeTemplateRepresentation(
                source: source,
                pointSize: targetSize,
                scale: scale)
            else {
                continue
            }
            rendered.addRepresentation(representation)
        }

        guard rendered.representations.isEmpty == false else { return nil }
        rendered.isTemplate = true
        self.templateStatusImages.setObject(rendered, forKey: cacheKey)
        return rendered
    }

    private static let templateStatusImages = NSCache<CacheKey, NSImage>()

    private static func sourceImage(for state: BrandIconState) -> NSImage? {
        let resourceName: String = switch state {
        case .running:
            "running"
        case .stopped:
            "stopped"
        }

        for bundle in AppResourceBundleLocator.candidateBundles() {
            if let url = bundle.url(
                forResource: resourceName,
                withExtension: resourceExtension,
                subdirectory: resourceSubdirectory),
               let image = NSImage(contentsOf: url)
            {
                return image
            }

            if let url = bundle.url(forResource: resourceName, withExtension: resourceExtension),
               let image = NSImage(contentsOf: url)
            {
                return image
            }
        }

        return nil
    }

    private static func loadImage(named resourceName: String) -> NSImage? {
        for bundle in AppResourceBundleLocator.candidateBundles() {
            if let url = bundle.url(
                forResource: resourceName,
                withExtension: resourceExtension,
                subdirectory: resourceSubdirectory),
               let image = NSImage(contentsOf: url)
            {
                return image
            }

            if let url = bundle.url(forResource: resourceName, withExtension: resourceExtension),
               let image = NSImage(contentsOf: url)
            {
                return image
            }
        }

        return nil
    }

    private static func makeTemplateRepresentation(
        source: NSImage,
        pointSize: NSSize,
        scale: CGFloat) -> NSBitmapImageRep?
    {
        let pixelWidth = max(1, Int((pointSize.width * scale).rounded(.up)))
        let pixelHeight = max(1, Int((pointSize.height * scale).rounded(.up)))

        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
        else {
            return nil
        }

        representation.size = pointSize

        guard let context = NSGraphicsContext(bitmapImageRep: representation) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(
            in: NSRect(origin: .zero, size: pointSize),
            from: .zero,
            operation: .copy,
            fraction: 1.0,
            respectFlipped: true,
            hints: nil)
        context.cgContext.setBlendMode(.sourceIn)
        context.cgContext.setFillColor(NSColor.black.cgColor)
        context.cgContext.fill(CGRect(origin: .zero, size: pointSize))
        NSGraphicsContext.restoreGraphicsState()
        return representation
    }
}

private final class CacheKey: NSObject {
    let state: BrandIconState
    let pointSize: CGFloat

    init(state: BrandIconState, pointSize: CGFloat) {
        self.state = state
        self.pointSize = pointSize
    }

    override var hash: Int {
        var hasher = Hasher()
        switch self.state {
        case .running:
            hasher.combine(1)
        case .stopped:
            hasher.combine(2)
        }
        hasher.combine(self.pointSize)
        return hasher.finalize()
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? CacheKey else { return false }
        return self.state == other.state && self.pointSize == other.pointSize
    }
}
