// EdgeNavigationCache.swift
import Cocoa

/// Runtime cache for fast edge navigation lookups
/// Converts normalized edge zones to logical pixel coordinates
class EdgeNavigationCache {
    /// Runtime representation of an edge zone with pixel coordinates
    struct ZoneRuntime {
        let id: UUID
        let range: ClosedRange<CGFloat>   // Logical coordinates (pixels)
        var targetZoneId: UUID?            // ID of paired zone (resolved via lookup)
        var targetScreen: NSScreen?        // Target screen for this zone's pair
    }

    // Cache: Screen ID (localized name) → Direction → Zone List
    private var zones: [String: [EdgeDirection: [ZoneRuntime]]] = [:]

    // Lookup table: Zone ID → ZoneRuntime (for setting target references)
    private var zoneById: [UUID: ZoneRuntime] = [:]

    /// Initialize cache from display configuration
    /// - Parameters:
    ///   - configuration: Display configuration with edge zones and pairs
    ///   - screens: Current NSScreen array
    func initialize(from configuration: DisplayConfiguration, screens: [NSScreen]) {
        zones.removeAll()
        zoneById.removeAll()

        // Build zone ID to DisplayIdentifier mapping (unused but kept for future use)
        // let displayIdMap = Dictionary(uniqueKeysWithValues: configuration.displays.map {
        //     ($0.identifier.stringRepresentation, $0)
        // })

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

        // First pass: Create ZoneRuntime for each EdgeZone
        for zone in configuration.edgeZones {
            guard let screen = screenByDisplayId[zone.displayId] else {
                continue  // Skip zones for disconnected displays
            }

            let pixelRange = convertToPixelRange(
                normalizedStart: zone.rangeStart,
                normalizedEnd: zone.rangeEnd,
                edge: zone.edge,
                screenFrame: screen.frame
            )

            let runtime = ZoneRuntime(
                id: zone.id,
                range: pixelRange,
                targetZoneId: nil,  // Set in second pass
                targetScreen: nil   // Set in second pass
            )

            zoneById[zone.id] = runtime

            // Group by screen and direction
            let screenId = screen.localizedName
            if zones[screenId] == nil {
                zones[screenId] = [:]
            }
            if zones[screenId]![zone.edge] == nil {
                zones[screenId]![zone.edge] = []
            }
            zones[screenId]![zone.edge]!.append(runtime)
        }

        // Second pass: Set target zone ID references from pairs
        for pair in configuration.edgeZonePairs {
            guard var sourceZone = zoneById[pair.sourceZoneId],
                  var targetZone = zoneById[pair.targetZoneId] else {
                continue  // Skip pairs with missing zones
            }

            // Find target screen
            let targetScreen = screens.first { screen in
                screen.localizedName == findScreenId(for: targetZone.id)
            }

            // Update source zone with target ID reference
            sourceZone.targetZoneId = targetZone.id
            sourceZone.targetScreen = targetScreen
            zoneById[pair.sourceZoneId] = sourceZone

            // Update in zones dictionary
            if let screenId = findScreenId(for: sourceZone.id),
               let edge = findEdge(for: sourceZone.id),
               var zoneList = zones[screenId]?[edge],
               let index = zoneList.firstIndex(where: { $0.id == sourceZone.id }) {
                zoneList[index] = sourceZone
                zones[screenId]![edge] = zoneList
            }

            // Create reverse pair (bidirectional)
            let sourceScreen = screens.first { screen in
                screen.localizedName == findScreenId(for: sourceZone.id)
            }
            targetZone.targetZoneId = sourceZone.id
            targetZone.targetScreen = sourceScreen
            zoneById[pair.targetZoneId] = targetZone

            // Update in zones dictionary
            if let screenId = findScreenId(for: targetZone.id),
               let edge = findEdge(for: targetZone.id),
               var zoneList = zones[screenId]?[edge],
               let index = zoneList.firstIndex(where: { $0.id == targetZone.id }) {
                zoneList[index] = targetZone
                zones[screenId]![edge] = zoneList
            }
        }

        NSLog("✅ EdgeNavigationCache initialized with \(zoneById.count) zones and \(configuration.edgeZonePairs.count) pairs")
    }

    /// Get zones for a specific screen and edge direction
    func zonesForEdge(screenId: String, direction: EdgeDirection) -> [ZoneRuntime]? {
        return zones[screenId]?[direction]
    }

    /// Get target zone by ID
    func getTargetZone(for zoneId: UUID) -> ZoneRuntime? {
        return zoneById[zoneId]
    }

    // MARK: - Helper Methods

    private func convertToPixelRange(normalizedStart: Double, normalizedEnd: Double, edge: EdgeDirection, screenFrame: CGRect) -> ClosedRange<CGFloat> {
        let edgeLength: CGFloat
        switch edge {
        case .top, .bottom:
            edgeLength = screenFrame.width
        case .left, .right:
            edgeLength = screenFrame.height
        }

        let pixelStart = CGFloat(normalizedStart) * edgeLength
        let pixelEnd = CGFloat(normalizedEnd) * edgeLength

        return pixelStart...pixelEnd
    }

    private func findScreenId(for zoneId: UUID) -> String? {
        for (screenId, edgeDict) in zones {
            for (_, zoneList) in edgeDict {
                if zoneList.contains(where: { $0.id == zoneId }) {
                    return screenId
                }
            }
        }
        return nil
    }

    private func findEdge(for zoneId: UUID) -> EdgeDirection? {
        for (_, edgeDict) in zones {
            for (edge, zoneList) in edgeDict {
                if zoneList.contains(where: { $0.id == zoneId }) {
                    return edge
                }
            }
        }
        return nil
    }
}
