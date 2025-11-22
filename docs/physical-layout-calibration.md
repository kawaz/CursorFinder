# Physical Layout Calibration

## Overview

LaserGuide uses a **physical layout calibration** system to accurately handle multi-display environments. Instead of relying on automatic PPI-based corrections, users manually configure the actual physical positions of their displays.

## Why Physical Calibration?

### Problems with Automatic PPI Correction

Initially, LaserGuide attempted to automatically correct for displays with different PPIs (Pixels Per Inch). This approach had several fundamental limitations:

**1. Inaccurate Coordinate Transformation**
- Automatic scaling between different PPI displays introduced rounding errors
- Laser lines didn't point precisely to cursor positions
- The mismatch accumulated with distance

**2. Assumption of Perfect Alignment**
- PPI correction assumed displays were perfectly aligned horizontally or vertically
- Real-world setups often have:
  - Rotated displays (portrait mode)
  - Angled displays (ergonomic positioning)
  - Vertically stacked displays with horizontal offsets
  - Complex arrangements (L-shape, U-shape, etc.)

**3. Limited Flexibility**
- No way to account for bezels and gaps between monitors
- Couldn't handle unusual configurations
- No user control over precision

### Benefits of Physical Calibration

**1. User-Controlled Accuracy**
- Users position displays exactly as they appear physically
- Direct mapping from logical (macOS) coordinates to physical positions
- Perfect precision without automatic guesswork

**2. Flexible Configuration**
- Supports any display arrangement
- Handles rotations, offsets, and gaps
- Works with mixed display sizes and orientations

**3. Persistent Per-Configuration**
- Calibration saved per display combination (identified by hardware IDs)
- Automatic detection when display configuration changes
- Each setup (home, office, etc.) can have its own calibration

**4. Optional and Fallback**
- Calibration is optional - LaserGuide works with logical coordinates by default
- If calibration exists, it's used for enhanced accuracy
- Falls back to logical coordinates if no calibration available

## How It Works

### Display Identification

Each display is identified by its hardware properties:
- Vendor ID
- Model ID
- Serial Number

This ensures calibration data persists correctly even if:
- Display connection order changes
- DisplayID numbers change after sleep/wake
- Displays are disconnected and reconnected

### Calibration Data Structure

```swift
struct PhysicalDisplayLayout: Codable {
    let identifier: DisplayIdentifier     // Hardware-based ID
    let position: PhysicalPoint           // Bottom-left corner (mm)
    let size: PhysicalSize                // Width and height (mm)
}

struct DisplayConfiguration: Codable {
    let displays: [PhysicalDisplayLayout]
    let timestamp: Date
    var configurationKey: String          // Unique key for this display combo
}
```

All physical measurements are in millimeters for consistency and precision.

### Configuration Key Format

```
config_vendorID-modelID-serial_vendorID-modelID-serial_...
```

Example:
```
config_1552-16385-0_1452-42086-0
```

The identifiers are sorted to ensure the same key is generated regardless of display connection order.

## Calibration UI

### Opening the Calibration Tool

Access via menu bar: **LaserGuide** > **Calibrate Physical Layout...**

### The Calibration Window

**Left Side: Logical Coordinates (macOS)**
- Shows how macOS sees your displays
- Read-only visualization
- Based on System Settings > Displays arrangement
- Click "Open Display Settings..." to modify logical layout

**Right Side: Physical Layout (Draggable)**
- Represents the actual physical positions
- Initially matches logical layout
- Drag displays to match your real desk setup
- Collision detection prevents overlapping
- Automatically rescales to fit canvas

### Calibration Process

1. **Initial State**: Physical layout starts matching the logical layout
2. **Adjust Physical Positions**: Drag displays on the right side to match reality
   - Consider actual bezel widths
   - Account for physical gaps or offsets
   - Match height differences on desk
3. **Visual Feedback**: Coordinate labels update in real-time during dragging
4. **Save**: Click "Save Calibration" to persist the configuration
5. **Reset**: "Reset to Default" returns physical layout to match logical

### Window Features

- **Resizable**: Drag window edges for more workspace
- **Adjustable Split**: Drag the center divider to resize left/right panels
- **Scale Info**: Shows current display scale ratio (e.g., "1:2 = 1px = 2mm")
- **Configuration Display**: Shows the current configuration key
- **Status Indicator**: "✓ Calibration saved" when saved configuration exists

## CalibrationDataManager

### Role

Centralized manager for calibration data persistence and retrieval.

### Key Methods

```swift
class CalibrationDataManager {
    static let shared = CalibrationDataManager()

    // Get current display configuration
    func getCurrentDisplayConfiguration() -> (
        logical: [LogicalDisplayInfo],
        physical: [ScreenInfo]
    )

    // Generate configuration key for current setup
    func getCurrentConfigurationKey() -> String

    // Save calibration data
    func saveCalibration(_ configuration: DisplayConfiguration)

    // Load calibration data for current configuration
    func loadCalibration() -> DisplayConfiguration?

    // Check if calibration exists
    func hasCalibration() -> Bool

    // Delete calibration for current configuration
    func deleteCalibration()

    // List all saved configurations
    func listAllCalibrations() -> [String]
}
```

### Storage

Calibration data is stored in `UserDefaults` with keys:
```
LaserGuide.Calibration.config_<configuration-key>
```

### Usage Example

```swift
let manager = CalibrationDataManager.shared

// Check if current setup has calibration
if manager.hasCalibration() {
    if let config = manager.loadCalibration() {
        // Use physical positions from config
        for layout in config.displays {
            print("\(layout.identifier): (\(layout.position.x), \(layout.position.y))")
        }
    }
} else {
    // Fall back to logical coordinates
    let (logical, _) = manager.getCurrentDisplayConfiguration()
    for display in logical {
        print("\(display.displayID): \(display.frame)")
    }
}
```

## Integration with Laser Display

When displaying laser lines:

1. **Cursor Position Detection**: Determine which display contains the cursor
2. **Coordinate System Check**: Check if physical calibration exists
3. **Coordinate Transformation**:
   - If calibration exists: Convert from logical to physical coordinates
   - If no calibration: Use logical coordinates directly
4. **Laser Rendering**: Draw lines using the selected coordinate system

This ensures laser lines always point accurately, regardless of display arrangement complexity.

## Best Practices

### When to Calibrate

Calibrate when:
- Setting up LaserGuide for the first time
- Adding or removing displays
- Rearranging display positions physically or in macOS settings
- Laser lines don't point accurately to cursor

### Calibration Tips

1. **Start with macOS Settings**: Set up logical arrangement first
2. **Match Reality**: Calibration should reflect your actual desk setup
3. **Consider Bezels**: Account for physical gaps between displays
4. **Verify with Laser**: After calibrating, move cursor around to verify accuracy
5. **Re-calibrate if Needed**: You can always adjust and re-save

### Multiple Locations

If you use your Mac in different locations (home, office, etc.):
- Each location's display configuration gets its own calibration
- LaserGuide automatically detects and loads the appropriate calibration
- No manual switching needed

## Future Enhancements

Potential improvements to the calibration system:

- Export/import calibration data
- Cloud sync for calibration across devices
- Guided calibration wizard with test patterns
- Auto-detection using camera/AR (ambitious!)

## See Also

- [Smart Edge Navigation](smart-edge-navigation.md) - Feature that uses calibration data
- [v2 Data Model Design](v2-data-model-design.ja.md) - Unified coordinate system and PassSegment pairing
