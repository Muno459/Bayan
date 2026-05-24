import UIKit

/// Renders a 1024×1024 chapter cover for the Lock Screen / Control
/// Center / AirPods Now Playing card. Pure Core Graphics so there's no
/// bundle-asset dependency and the image scales cleanly per chapter.
///
/// Layout: brand-green gradient background, decorative octagram star
/// in cream + gold (matching the app icon), the chapter's Arabic name
/// centred large, chapter number + Latin name beneath.
enum NowPlayingArtworkRenderer {

    /// Cache keyed on chapter id so we don't redraw the same image when
    /// the user pauses/resumes within a chapter — `updateNowPlayingInfo`
    /// gets called often and creating a 1024×1024 UIImage every tick
    /// would chew the CPU. `nonisolated(unsafe)` is OK here because all
    /// accesses go through the `cacheLock`.
    private nonisolated(unsafe) static var cache: [Int: UIImage] = [:]
    private nonisolated(unsafe) static let cacheLock = NSLock()

    @MainActor
    static func render(chapter: Chapter) -> UIImage {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache[chapter.id] {
            return cached
        }
        let img = draw(chapter: chapter)
        cache[chapter.id] = img
        return img
    }

    private static func draw(chapter: Chapter) -> UIImage {
        let size = CGSize(width: 1024, height: 1024)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            let rect = CGRect(origin: .zero, size: size)

            // Background gradient — same green family as the app icon.
            let cs = CGColorSpaceCreateDeviceRGB()
            let topColor   = CGColor(red: 0.078, green: 0.396, blue: 0.298, alpha: 1.0) // #145F4C
            let botColor   = CGColor(red: 0.055, green: 0.196, blue: 0.149, alpha: 1.0) // #0E3226
            let gradient = CGGradient(colorsSpace: cs,
                                      colors: [topColor, botColor] as CFArray,
                                      locations: [0.0, 1.0])!
            cg.drawLinearGradient(gradient,
                                  start: .zero,
                                  end: CGPoint(x: 0, y: size.height),
                                  options: [])

            // Octagram (8-pointed star) — geometric pattern from the app
            // icon. Cream fill, faint gold dot in centre.
            let star = octagramPath(center: CGPoint(x: size.width / 2, y: size.height * 0.42),
                                    radius: 320)
            UIColor(red: 0.96, green: 0.91, blue: 0.80, alpha: 1.0).setFill()  // #F5E9CC
            star.fill()
            let dot = UIBezierPath(
                ovalIn: CGRect(x: size.width / 2 - 32, y: size.height * 0.42 - 32, width: 64, height: 64)
            )
            UIColor(red: 0.83, green: 0.65, blue: 0.46, alpha: 1.0).setFill()  // #D4A574
            dot.fill()

            // Chapter Arabic name — large, centered above the Latin info.
            let arabic = chapter.nameArabic
            let arabicAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 132, weight: .bold),
                .foregroundColor: UIColor(red: 0.96, green: 0.91, blue: 0.80, alpha: 1.0),
                .paragraphStyle: centered,
            ]
            let arabicSize = (arabic as NSString).size(withAttributes: arabicAttrs)
            (arabic as NSString).draw(
                in: CGRect(x: 0,
                           y: size.height * 0.66,
                           width: size.width,
                           height: arabicSize.height + 20),
                withAttributes: arabicAttrs
            )

            // Chapter number + Latin name beneath, smaller, gold accent.
            let subtitle = "\(chapter.id). \(chapter.nameSimple)"
            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 48, weight: .semibold),
                .foregroundColor: UIColor(red: 0.83, green: 0.65, blue: 0.46, alpha: 1.0),
                .paragraphStyle: centered,
            ]
            (subtitle as NSString).draw(
                in: CGRect(x: 0,
                           y: size.height * 0.82,
                           width: size.width,
                           height: 80),
                withAttributes: subAttrs
            )
        }
    }

    // NSParagraphStyle isn't Sendable, but this instance is set once
    // at first access and never mutated, so the unsafe annotation is
    // accurate. Used only on the main thread via `render`.
    private nonisolated(unsafe) static let centered: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        return p
    }()

    /// Draws a regular 8-pointed star (octagram), the same geometric
    /// shape used in the app's launch logo.
    private static func octagramPath(center: CGPoint, radius: CGFloat) -> UIBezierPath {
        let path = UIBezierPath()
        let outer = radius
        let inner = radius * 0.7071  // sin(45°)
        let points = 8
        for i in 0..<(points * 2) {
            let r = (i % 2 == 0) ? outer : inner
            // Rotate so the top point sits straight up.
            let angle = (CGFloat(i) * .pi / CGFloat(points)) - .pi / 2
            let x = center.x + r * cos(angle)
            let y = center.y + r * sin(angle)
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        path.close()
        return path
    }
}
