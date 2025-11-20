// DisplayIdentifier.swift
import Cocoa

/// Unique identifier for a display based on hardware properties
struct DisplayIdentifier: Hashable, Codable {
    let vendorID: UInt32
    let modelID: UInt32
    let serialNumber: UInt32

    init(displayID: CGDirectDisplayID) {
        self.vendorID = CGDisplayVendorNumber(displayID)
        self.modelID = CGDisplayModelNumber(displayID)
        self.serialNumber = CGDisplaySerialNumber(displayID)
    }

    /// String representation for use in configuration keys
    var stringRepresentation: String {
        return "\(vendorID)-\(modelID)-\(serialNumber)"
    }
}

/// Physical position and size of a display in millimeters
struct PhysicalDisplayLayout: Codable {
    let identifier: DisplayIdentifier
    let position: PhysicalPoint  // Bottom-left corner in mm
    let size: PhysicalSize       // Width and height in mm

    struct PhysicalPoint: Codable {
        let x: Double  // mm
        let y: Double  // mm
    }

    struct PhysicalSize: Codable {
        let width: Double   // mm
        let height: Double  // mm
    }
}

/// Edge direction of a display
enum EdgeDirection: String, Codable, CaseIterable {
    case top
    case bottom
    case left
    case right
}

/// A range on a display edge (normalized 0-1 coordinates)
struct EdgeZone: Codable, Identifiable, Hashable {
    let id: UUID
    let displayId: String         // DisplayIdentifier string representation
    let edge: EdgeDirection
    var rangeStart: Double        // 0.0 - 1.0 (normalized position)
    var rangeEnd: Double          // 0.0 - 1.0 (normalized position)

    init(id: UUID = UUID(), displayId: String, edge: EdgeDirection, rangeStart: Double, rangeEnd: Double) {
        self.id = id
        self.displayId = displayId
        self.edge = edge
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
    }
}

/// Pair of edge zones that allow mouse crossing
struct EdgeZonePair: Codable, Identifiable, Hashable {
    let id: UUID
    let sourceZoneId: UUID
    let targetZoneId: UUID

    init(id: UUID = UUID(), sourceZoneId: UUID, targetZoneId: UUID) {
        self.id = id
        self.sourceZoneId = sourceZoneId
        self.targetZoneId = targetZoneId
    }
}

/// Complete display configuration including all connected displays
struct DisplayConfiguration: Codable {
    let displays: [PhysicalDisplayLayout]
    let timestamp: Date
    var edgeZones: [EdgeZone]           // Edge ranges on displays
    var edgeZonePairs: [EdgeZonePair]   // Pairs allowing mouse crossing

    init(displays: [PhysicalDisplayLayout], timestamp: Date = Date(), edgeZones: [EdgeZone] = [], edgeZonePairs: [EdgeZonePair] = []) {
        self.displays = displays
        self.timestamp = timestamp
        self.edgeZones = edgeZones
        self.edgeZonePairs = edgeZonePairs
    }

    /// Generate unique configuration key based on connected displays
    /// Key format: "config_vendorID-modelID-serial_vendorID-modelID-serial_..."
    var configurationKey: String {
        let identifiers = displays
            .map { $0.identifier.stringRepresentation }
            .sorted()  // Sort to ensure consistent key regardless of display order
            .joined(separator: "_")
        return "config_\(identifiers)"
    }
}
