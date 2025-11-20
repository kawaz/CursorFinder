// CalibrationDataManager.swift
import Foundation
import Cocoa

/// Manages storage and retrieval of physical display layout calibration data
class CalibrationDataManager {
    static let shared = CalibrationDataManager()

    private let userDefaults = UserDefaults.standard
    private let calibrationKeyPrefix = "LaserGuide.Calibration."

    private init() {}

    /// Get current display configuration (logical coordinates and physical specs)
    func getCurrentDisplayConfiguration() -> (logical: [LogicalDisplayInfo], physical: [ScreenInfo]) {
        let screens = NSScreen.screens
        let logical = screens.map { screen -> LogicalDisplayInfo in
            let deviceDescription = screen.deviceDescription
            let displayID = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
            return LogicalDisplayInfo(
                displayID: displayID,
                identifier: DisplayIdentifier(displayID: displayID),
                frame: screen.frame
            )
        }
        let physical = screens.compactMap { ScreenInfo(screen: $0) }
        return (logical, physical)
    }

    /// Generate configuration key for current display setup
    func getCurrentConfigurationKey() -> String {
        let (_, physical) = getCurrentDisplayConfiguration()
        let identifiers = physical
            .map { DisplayIdentifier(displayID: $0.displayID).stringRepresentation }
            .sorted()
            .joined(separator: "_")
        return "config_\(identifiers)"
    }

    /// Save calibration data for current display configuration
    func saveCalibration(_ configuration: DisplayConfiguration) {
        let key = calibrationKeyPrefix + configuration.configurationKey
        if let encoded = try? JSONEncoder().encode(configuration) {
            userDefaults.set(encoded, forKey: key)
            print("✅ Saved calibration for: \(configuration.configurationKey)")
        }
    }

    /// Save temporary calibration data for real-time preview (not persisted permanently)
    func saveCalibrationTemporary(_ configuration: DisplayConfiguration) {
        let key = calibrationKeyPrefix + getCurrentConfigurationKey() + ".temporary"
        if let encoded = try? JSONEncoder().encode(configuration) {
            userDefaults.set(encoded, forKey: key)
        }
    }

    /// Load calibration data for current display configuration
    func loadCalibration() -> DisplayConfiguration? {
        // Check for temporary configuration first (for real-time preview)
        let tempKey = calibrationKeyPrefix + getCurrentConfigurationKey() + ".temporary"
        if let tempData = userDefaults.data(forKey: tempKey),
           let tempConfiguration = try? JSONDecoder().decode(DisplayConfiguration.self, from: tempData) {
            return tempConfiguration
        }

        // Fall back to saved configuration
        let key = calibrationKeyPrefix + getCurrentConfigurationKey()
        guard let data = userDefaults.data(forKey: key),
              let configuration = try? JSONDecoder().decode(DisplayConfiguration.self, from: data) else {
            return nil
        }
        return configuration
    }

    /// Clear temporary calibration data
    func clearTemporaryCalibration() {
        let tempKey = calibrationKeyPrefix + getCurrentConfigurationKey() + ".temporary"
        userDefaults.removeObject(forKey: tempKey)
    }

    /// Check if calibration exists for current configuration
    func hasCalibration() -> Bool {
        return loadCalibration() != nil
    }

    /// Delete calibration data for current configuration
    func deleteCalibration() {
        let key = calibrationKeyPrefix + getCurrentConfigurationKey()
        userDefaults.removeObject(forKey: key)
    }

    /// List all saved calibration configurations
    func listAllCalibrations() -> [String] {
        let allKeys = userDefaults.dictionaryRepresentation().keys
        return allKeys
            .filter { $0.hasPrefix(calibrationKeyPrefix) }
            .map { String($0.dropFirst(calibrationKeyPrefix.count)) }
    }

    // MARK: - Edge Zone Auto-Generation

    /// Generate default edge zone pairs from logical display adjacency
    /// - Parameters:
    ///   - displays: Physical display layouts
    ///   - screens: Current NSScreen array
    /// - Returns: Tuple of (zones, pairs)
    func generateDefaultEdgeZonePairs(displays: [PhysicalDisplayLayout], screens: [NSScreen]) -> (zones: [EdgeZone], pairs: [EdgeZonePair]) {
        var zones: [EdgeZone] = []
        var pairs: [EdgeZonePair] = []
        var processedPairs: Set<Set<String>> = []  // Track processed display-edge pairs

        // Build screen lookup by DisplayIdentifier
        let screenByDisplayId: [String: NSScreen] = Dictionary(uniqueKeysWithValues:
            screens.compactMap { screen in
                let desc = screen.deviceDescription
                guard let displayID = desc[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                    return nil
                }
                let identifier = DisplayIdentifier(displayID: displayID).stringRepresentation
                return (identifier, screen)
            }
        )

        // Check each display and each edge
        for display in displays {
            let displayId = display.identifier.stringRepresentation
            guard let screen = screenByDisplayId[displayId] else {
                continue  // Skip disconnected displays
            }

            for edge in EdgeDirection.allCases {
                // Find logically adjacent displays for this edge
                let adjacencies = findLogicallyAdjacentDisplays(
                    display: display,
                    screen: screen,
                    edge: edge,
                    allDisplays: displays,
                    allScreens: screenByDisplayId
                )

                for adjacency in adjacencies {
                    let adjacencyKey1 = "\(displayId).\(edge)"
                    let adjacencyKey2 = "\(adjacency.display.identifier.stringRepresentation).\(adjacency.edge)"
                    let pairKey: Set<String> = [adjacencyKey1, adjacencyKey2]

                    // Skip if we've already processed this pair (in reverse direction)
                    if processedPairs.contains(pairKey) {
                        continue
                    }
                    processedPairs.insert(pairKey)

                    // Calculate overlapping range in both edges
                    let (range1, range2) = calculateOverlapRanges(
                        display1: (display, screen),
                        edge1: edge,
                        display2: (adjacency.display, adjacency.screen),
                        edge2: adjacency.edge
                    )

                    // Create zones for overlapping regions
                    let zone1 = EdgeZone(
                        displayId: displayId,
                        edge: edge,
                        rangeStart: range1.lowerBound,
                        rangeEnd: range1.upperBound
                    )
                    let zone2 = EdgeZone(
                        displayId: adjacency.display.identifier.stringRepresentation,
                        edge: adjacency.edge,
                        rangeStart: range2.lowerBound,
                        rangeEnd: range2.upperBound
                    )

                    zones.append(zone1)
                    zones.append(zone2)

                    // Create pair
                    let pair = EdgeZonePair(sourceZoneId: zone1.id, targetZoneId: zone2.id)
                    pairs.append(pair)

                    NSLog("📐 Auto-generated edge pair: \(displayId).\(edge) ↔ \(zone2.displayId).\(adjacency.edge)")
                }
            }
        }

        NSLog("✅ Generated \(zones.count) zones and \(pairs.count) pairs")
        return (zones, pairs)
    }

    private struct Adjacency {
        let display: PhysicalDisplayLayout
        let screen: NSScreen
        let edge: EdgeDirection
    }

    private func findLogicallyAdjacentDisplays(
        display: PhysicalDisplayLayout,
        screen: NSScreen,
        edge: EdgeDirection,
        allDisplays: [PhysicalDisplayLayout],
        allScreens: [String: NSScreen]
    ) -> [Adjacency] {
        var adjacencies: [Adjacency] = []
        let frame = screen.frame
        let epsilon: CGFloat = 1.0  // Tolerance for floating point comparison

        for otherDisplay in allDisplays {
            let otherId = otherDisplay.identifier.stringRepresentation
            guard otherId != display.identifier.stringRepresentation,
                  let otherScreen = allScreens[otherId] else {
                continue
            }

            let otherFrame = otherScreen.frame

            // Check if adjacent based on edge
            switch edge {
            case .top:
                // Top edge: current.maxY == other.minY
                if abs(frame.maxY - otherFrame.minY) < epsilon {
                    adjacencies.append(Adjacency(display: otherDisplay, screen: otherScreen, edge: .bottom))
                }
            case .bottom:
                // Bottom edge: current.minY == other.maxY
                if abs(frame.minY - otherFrame.maxY) < epsilon {
                    adjacencies.append(Adjacency(display: otherDisplay, screen: otherScreen, edge: .top))
                }
            case .right:
                // Right edge: current.maxX == other.minX
                if abs(frame.maxX - otherFrame.minX) < epsilon {
                    adjacencies.append(Adjacency(display: otherDisplay, screen: otherScreen, edge: .left))
                }
            case .left:
                // Left edge: current.minX == other.maxX
                if abs(frame.minX - otherFrame.maxX) < epsilon {
                    adjacencies.append(Adjacency(display: otherDisplay, screen: otherScreen, edge: .right))
                }
            }
        }

        return adjacencies
    }

    private func calculateOverlapRanges(
        display1: (display: PhysicalDisplayLayout, screen: NSScreen),
        edge1: EdgeDirection,
        display2: (display: PhysicalDisplayLayout, screen: NSScreen),
        edge2: EdgeDirection
    ) -> (ClosedRange<Double>, ClosedRange<Double>) {
        let frame1 = display1.screen.frame
        let frame2 = display2.screen.frame

        switch (edge1, edge2) {
        case (.top, .bottom), (.bottom, .top):
            // Horizontal edges - check X overlap
            let overlapStart = max(frame1.minX, frame2.minX)
            let overlapEnd = min(frame1.maxX, frame2.maxX)

            // Normalize to [0,1] for each display
            let normalized1Start = (overlapStart - frame1.minX) / frame1.width
            let normalized1End = (overlapEnd - frame1.minX) / frame1.width
            let normalized2Start = (overlapStart - frame2.minX) / frame2.width
            let normalized2End = (overlapEnd - frame2.minX) / frame2.width

            return (Double(normalized1Start)...Double(normalized1End),
                    Double(normalized2Start)...Double(normalized2End))

        case (.left, .right), (.right, .left):
            // Vertical edges - check Y overlap
            // macOS logical coordinates: Y increases upward, origin at bottom-left
            let overlapStart = max(frame1.minY, frame2.minY)
            let overlapEnd = min(frame1.maxY, frame2.maxY)

            // Normalize to [0,1] for each display, but flip Y to match SwiftUI (origin at top)
            // In macOS coords: minY=bottom, maxY=top
            // In SwiftUI coords: 0=top, 1=bottom
            let normalized1Start = (frame1.maxY - overlapEnd) / frame1.height  // Flip: top of overlap
            let normalized1End = (frame1.maxY - overlapStart) / frame1.height  // Flip: bottom of overlap
            let normalized2Start = (frame2.maxY - overlapEnd) / frame2.height
            let normalized2End = (frame2.maxY - overlapStart) / frame2.height

            return (Double(normalized1Start)...Double(normalized1End),
                    Double(normalized2Start)...Double(normalized2End))

        default:
            // Should not happen - edges must be opposite
            return (0.0...1.0, 0.0...1.0)
        }
    }

    private func deduplicatePairs(_ pairs: [EdgeZonePair], zones: [EdgeZone]) -> [EdgeZonePair] {
        var seen: Set<Set<UUID>> = []
        var unique: [EdgeZonePair] = []

        for pair in pairs {
            let pairSet: Set<UUID> = [pair.sourceZoneId, pair.targetZoneId]
            if !seen.contains(pairSet) {
                seen.insert(pairSet)
                unique.append(pair)
            }
        }

        return unique
    }
}

/// Logical display information (macOS coordinate system)
struct LogicalDisplayInfo {
    let displayID: CGDirectDisplayID
    let identifier: DisplayIdentifier
    let frame: CGRect  // Logical coordinates
}
