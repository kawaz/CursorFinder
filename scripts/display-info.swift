#!/usr/bin/env swift

import Cocoa

print("=== macOS Display Information ===\n")

let screens = NSScreen.screens

print("Total screens: \(screens.count)")
print("Main screen index: \(screens.firstIndex(of: NSScreen.main!) ?? -1)\n")

for (index, screen) in screens.enumerated() {
    let deviceDescription = screen.deviceDescription
    let displayID = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID

    print("--- Screen \(index) ---")
    print("Display ID: \(displayID)")
    print("Localized Name: \(screen.localizedName)")
    print("Is Main: \(screen == NSScreen.main)")
    print("Is Built-in: \(CGDisplayIsBuiltin(displayID) != 0)")

    print("\nLogical Coordinates:")
    print("  frame: \(screen.frame)")
    print("    origin: (\(screen.frame.origin.x), \(screen.frame.origin.y))")
    print("    size: (\(screen.frame.size.width) x \(screen.frame.size.height))")
    print("  visibleFrame: \(screen.visibleFrame)")

    print("\nPhysical Information:")
    let physicalSize = CGDisplayScreenSize(displayID)
    print("  Physical size (mm): \(physicalSize.width) x \(physicalSize.height)")

    print("\nResolution:")
    print("  Points: \(screen.frame.size.width) x \(screen.frame.size.height)")
    print("  Backing scale: \(screen.backingScaleFactor)x")
    let pixelWidth = screen.frame.size.width * screen.backingScaleFactor
    let pixelHeight = screen.frame.size.height * screen.backingScaleFactor
    print("  Pixels: \(pixelWidth) x \(pixelHeight)")

    if physicalSize.width > 0 {
        let ppi = pixelWidth / (physicalSize.width / 25.4)
        print("  PPI: \(ppi)")
    }

    print("\nHardware IDs:")
    print("  Vendor: \(CGDisplayVendorNumber(displayID))")
    print("  Model: \(CGDisplayModelNumber(displayID))")
    print("  Serial: \(CGDisplaySerialNumber(displayID))")

    print("\nEdge Coordinates:")
    let frame = screen.frame
    print("  Left edge: x = \(frame.minX), y range: [\(frame.minY), \(frame.maxY)]")
    print("  Right edge: x = \(frame.maxX), y range: [\(frame.minY), \(frame.maxY)]")
    print("  Bottom edge: y = \(frame.minY), x range: [\(frame.minX), \(frame.maxX)]")
    print("  Top edge: y = \(frame.maxY), x range: [\(frame.minX), \(frame.maxX)]")

    print("\n")
}

// Check adjacency between screens
print("=== Edge Adjacency Analysis ===\n")

for (i, screen1) in screens.enumerated() {
    for (j, screen2) in screens.enumerated() {
        if i >= j { continue }

        let f1 = screen1.frame
        let f2 = screen2.frame
        let epsilon: CGFloat = 1.0

        print("Screen \(i) <-> Screen \(j):")

        if abs(f1.maxX - f2.minX) < epsilon {
            let overlapStart = max(f1.minY, f2.minY)
            let overlapEnd = min(f1.maxY, f2.maxY)
            print("  Screen \(i) right edge touches Screen \(j) left edge")
            print("  Overlap Y range: [\(overlapStart), \(overlapEnd)]")
        }
        if abs(f1.minX - f2.maxX) < epsilon {
            let overlapStart = max(f1.minY, f2.minY)
            let overlapEnd = min(f1.maxY, f2.maxY)
            print("  Screen \(i) left edge touches Screen \(j) right edge")
            print("  Overlap Y range: [\(overlapStart), \(overlapEnd)]")
        }
        if abs(f1.maxY - f2.minY) < epsilon {
            let overlapStart = max(f1.minX, f2.minX)
            let overlapEnd = min(f1.maxX, f2.maxX)
            print("  Screen \(i) top edge touches Screen \(j) bottom edge")
            print("  Overlap X range: [\(overlapStart), \(overlapEnd)]")
        }
        if abs(f1.minY - f2.maxY) < epsilon {
            let overlapStart = max(f1.minX, f2.minX)
            let overlapEnd = min(f1.maxX, f2.maxX)
            print("  Screen \(i) bottom edge touches Screen \(j) top edge")
            print("  Overlap X range: [\(overlapStart), \(overlapEnd)]")
        }

        print("")
    }
}
