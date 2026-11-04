import AppKit
import SSTPCore

/// The status icon in the menu bar, 15% larger than the default symbol size
/// (the menu bar font) so the connection state is easy to spot.
enum MenuBarIcon {
    static let scale: CGFloat = 1.15

    static func image(for state: ConnectionState) -> NSImage {
        let pointSize = (NSFont.menuBarFont(ofSize: 0).pointSize * scale).rounded()
        // semibold: lines 20% thicker than regular (1.50 vs 1.25 pt at 15 pt)
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: state.symbol, accessibilityDescription: state.title)?
            .withSymbolConfiguration(config) else { return NSImage() }
        // Redrawn into a plain image: the menu bar label crops a symbol image
        // to its alignment rect (10.5 of 17 pt here), which cut the top and
        // bottom off the shield and left "[ ]".
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            return true
        }
        image.accessibilityDescription = state.title
        // template: macOS tints it for light and dark menu bars
        image.isTemplate = true
        return image
    }
}
