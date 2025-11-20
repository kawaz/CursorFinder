// ScreenInfo.swift
import Cocoa

/// Display information including PPI for multi-display correction
struct ScreenInfo {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let ppi: CGFloat
    let physicalSize: CGSize  // in millimeters

    init?(screen: NSScreen) {
        self.screen = screen

        let deviceDescription = screen.deviceDescription as [NSDeviceDescriptionKey: Any]
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }

        self.displayID = screenNumber

        // Get physical size in millimeters
        let size = CGDisplayScreenSize(screenNumber)
        self.physicalSize = size

        // Calculate PPI
        if size.width > 0 {
            let points = screen.frame.size
            let pixels = CGSize(
                width: points.width * screen.backingScaleFactor,
                height: points.height * screen.backingScaleFactor
            )

            // PPI = pixels / (physical size in inches)
            let ppiX = pixels.width / (size.width / 25.4)
            let ppiY = pixels.height / (size.height / 25.4)

            // Use average PPI (typically they're the same)
            self.ppi = (ppiX + ppiY) / 2.0
        } else {
            // Fallback: assume standard PPI if physical size unavailable
            self.ppi = 72.0 * screen.backingScaleFactor
        }
    }

    /// Get correction factor when drawing on this screen with cursor on another screen
    /// - Parameter cursorScreen: The screen where the cursor is located
    /// - Returns: Correction factor to apply to distances
    func correctionFactor(cursorScreen: ScreenInfo) -> CGFloat {
        return self.ppi / cursorScreen.ppi
    }
}

extension ScreenInfo {
    var isBuiltIn: Bool {
        CGDisplayIsBuiltin(displayID) != 0
    }

    var name: String {
        // Use screen's localized name
        let localizedName = screen.localizedName
        if !localizedName.isEmpty {
            return localizedName
        }
        return isBuiltIn ? "Built-in Display" : "External Display"
    }
}
