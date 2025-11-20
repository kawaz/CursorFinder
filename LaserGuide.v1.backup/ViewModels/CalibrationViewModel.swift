// CalibrationViewModel.swift
import SwiftUI
import Cocoa

class CalibrationViewModel: ObservableObject {
    @Published var logicalDisplays: [LogicalDisplay] = []
    @Published var physicalDisplays: [PhysicalDisplay] = []
    @Published var currentConfigKey: String?
    @Published var hasExistingCalibration: Bool = false
    @Published var scaleInfo: String = "Scale: 1:2 (1px = 2mm)"
    @Published var canvasSize = CGSize(width: 500, height: 400)  // Physical canvas size, updated by view
    @Published var flashingDisplayNumber: Int? = nil  // Currently flashing display number (only one at a time)
    @Published var edgeZones: [EdgeZone] = []  // Edge zones for navigation
    @Published var edgeZonePairs: [EdgeZonePair] = []  // Zone pairings
    @Published var dragOffsets: [UUID: CGSize] = [:]  // Track drag offsets for each display
    @Published var selectedEdgeZoneIds: Set<UUID> = []  // Currently selected edge zones (shows handles for all)
    @Published var showingOriginalZones: Bool = false  // True when showing original (default) zones for comparison

    // Default edge zones (generated from physical layout, for comparison)
    private var defaultEdgeZones: [EdgeZone] = []
    private var defaultEdgeZonePairs: [EdgeZonePair] = []

    // Computed properties to get the zones to display
    var displayedEdgeZones: [EdgeZone] {
        showingOriginalZones ? defaultEdgeZones : edgeZones
    }

    var displayedEdgeZonePairs: [EdgeZonePair] {
        showingOriginalZones ? defaultEdgeZonePairs : edgeZonePairs
    }

    private let calibrationManager = CalibrationDataManager.shared
    private var logicalCanvasSize = CGSize(width: 300, height: 300)  // Logical canvas size
    private var currentScale: CGFloat = 0.5  // Current scale factor (1px = 2mm at 0.5)
    private var savedConfiguration: DisplayConfiguration?  // For restoring on cancel/close
    private var flashTimer: DispatchWorkItem? = nil  // Timer for hiding flash

    init() {
        // Monitor display configuration changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func screensDidChange() {
        NSLog("🔄 Screen parameters changed, reloading configuration...")
        loadConfiguration()
    }

    func loadConfiguration() {
        let (logical, physical) = calibrationManager.getCurrentDisplayConfiguration()
        currentConfigKey = calibrationManager.getCurrentConfigurationKey()
        hasExistingCalibration = calibrationManager.hasCalibration()

        // Save current configuration for restoration
        savedConfiguration = calibrationManager.loadCalibration()

        // Load logical displays
        loadLogicalDisplays(logical)

        // Load physical displays (from calibration or default)
        if let savedConfig = savedConfiguration {
            loadPhysicalDisplaysFromCalibration(savedConfig, screenInfos: physical)
            // Load edge zones and pairs from saved configuration
            edgeZones = savedConfig.edgeZones
            edgeZonePairs = savedConfig.edgeZonePairs

            // If no edge zones, auto-generate them
            if edgeZones.isEmpty {
                NSLog("📍 No edge zones in saved config - generating default zones")
                let layouts = savedConfig.displays
                let screens = NSScreen.screens
                let (zones, pairs) = calibrationManager.generateDefaultEdgeZonePairs(displays: layouts, screens: screens)
                edgeZones = zones
                edgeZonePairs = pairs
                // Store as default zones for comparison
                defaultEdgeZones = zones
                defaultEdgeZonePairs = pairs
                NSLog("📍 Generated \(edgeZones.count) zones and \(edgeZonePairs.count) pairs")
            } else {
                NSLog("📍 Loaded \(edgeZones.count) zones and \(edgeZonePairs.count) pairs from saved config")
                // Generate default zones for comparison (using same layouts)
                let layouts = savedConfig.displays
                let screens = NSScreen.screens
                let (zones, pairs) = calibrationManager.generateDefaultEdgeZonePairs(displays: layouts, screens: screens)
                defaultEdgeZones = zones
                defaultEdgeZonePairs = pairs
                NSLog("📍 Generated default zones for comparison: \(defaultEdgeZones.count) zones and \(defaultEdgeZonePairs.count) pairs")
            }
        } else {
            loadDefaultPhysicalDisplays(physical)
            // Generate default edge zones
            NSLog("📍 No saved config - generating default zones from physical displays")
            let layouts = physicalDisplays.map { display in
                PhysicalDisplayLayout(
                    identifier: display.identifier,
                    position: PhysicalDisplayLayout.PhysicalPoint(x: display.physicalPosition.x, y: display.physicalPosition.y),
                    size: PhysicalDisplayLayout.PhysicalSize(width: display.physicalSize.width, height: display.physicalSize.height)
                )
            }
            let screens = NSScreen.screens
            let (zones, pairs) = calibrationManager.generateDefaultEdgeZonePairs(displays: layouts, screens: screens)
            edgeZones = zones
            edgeZonePairs = pairs
            // Store as default zones for comparison
            defaultEdgeZones = zones
            defaultEdgeZonePairs = pairs
            NSLog("📍 Generated \(edgeZones.count) zones and \(edgeZonePairs.count) pairs")
        }
    }

    func updateLogicalCanvasSize(_ newSize: CGSize) {
        guard newSize.width > 0 && newSize.height > 0 else { return }
        let oldSize = logicalCanvasSize
        logicalCanvasSize = newSize

        // Force recalculation if canvas size changed
        if oldSize != newSize {
            // Reload logical displays with new canvas size
            let (logical, _) = calibrationManager.getCurrentDisplayConfiguration()
            loadLogicalDisplays(logical)
        }
    }

    func updateCanvasSize(_ newSize: CGSize) {
        guard newSize.width > 0 && newSize.height > 0 else { return }
        let oldSize = canvasSize
        canvasSize = newSize

        // Force recalculation if canvas size changed
        if oldSize != newSize {
            // Recalculate optimal scale and update all positions
            refitToCanvas(force: true)
        }
    }

    private func loadLogicalDisplays(_ displays: [LogicalDisplayInfo]) {
        guard !displays.isEmpty else { return }

        // Calculate bounds
        let allFrames = displays.map { $0.frame }
        let minX = allFrames.map { $0.minX }.min() ?? 0
        let maxX = allFrames.map { $0.maxX }.max() ?? 0
        let minY = allFrames.map { $0.minY }.min() ?? 0
        let maxY = allFrames.map { $0.maxY }.max() ?? 0

        let totalWidth = maxX - minX
        let totalHeight = maxY - minY

        // Calculate scale to fit in canvas
        let scaleX = (logicalCanvasSize.width * 0.9) / totalWidth
        let scaleY = (logicalCanvasSize.height * 0.9) / totalHeight
        let scale = min(scaleX, scaleY)

        // Assign color indices: Built-in = 0, External = 1, 2, 3...
        var externalIndex = 1

        logicalDisplays = displays.enumerated().map { index, info in
            // Simple approach: just scale and flip Y
            // Input: info.frame in logical coords (Y=0 is bottom)
            // Output: scaledFrame in canvas coords (Y=0 is top)

            let scaledWidth = info.frame.width * scale
            let scaledHeight = info.frame.height * scale

            // Position relative to minX, minY
            let relativeX = info.frame.minX - minX
            let relativeY = info.frame.minY - minY

            // Scale the position
            let scaledX = relativeX * scale
            let scaledY = relativeY * scale

            // Flip Y axis: logical bottom (Y=0) becomes canvas bottom (Y=max)
            // logical top (Y=max) becomes canvas top (Y=0)
            let totalScaledHeight = totalHeight * scale
            let flippedY = totalScaledHeight - scaledY - scaledHeight

            // Add margin to center
            let marginX = (logicalCanvasSize.width - totalWidth * scale) / 2
            let marginY = (logicalCanvasSize.height - totalHeight * scale) / 2

            let scaledFrame = CGRect(
                x: marginX + scaledX,
                y: marginY + flippedY,
                width: scaledWidth,
                height: scaledHeight
            )

            let isBuiltIn = CGDisplayIsBuiltin(info.displayID) != 0
            let colorIndex: Int
            if isBuiltIn {
                colorIndex = 0
            } else {
                colorIndex = externalIndex
                externalIndex += 1
            }

            return LogicalDisplay(
                id: UUID(),
                displayID: info.displayID,
                identifier: info.identifier,
                name: NSScreen.screens.first(where: {
                    let desc = $0.deviceDescription
                    return desc[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == info.displayID
                })?.localizedName ?? "Display \(index + 1)",
                frame: info.frame,
                scaledFrame: scaledFrame,
                isBuiltIn: isBuiltIn,
                colorIndex: colorIndex
            )
        }
    }

    private func loadDefaultPhysicalDisplays(_ screenInfos: [ScreenInfo]) {
        // BFS algorithm to calculate physical positions based on logical adjacency
        guard !screenInfos.isEmpty else { return }

        // Get logical arrangement
        let (logical, _) = calibrationManager.getCurrentDisplayConfiguration()

        // Build a map: displayID -> (logicalInfo, screenInfo)
        var displayMap: [CGDirectDisplayID: (logical: LogicalDisplayInfo, screen: ScreenInfo)] = [:]
        for logicalInfo in logical {
            if let screenInfo = screenInfos.first(where: { $0.displayID == logicalInfo.displayID }) {
                displayMap[logicalInfo.displayID] = (logicalInfo, screenInfo)
            }
        }

        // Find the origin display (contains logical point (0, 0))
        guard let originID = logical.first(where: { $0.frame.contains(CGPoint(x: 0, y: 0)) })?.displayID,
              let _ = displayMap[originID] else {
            return
        }

        // Physical positions in mm (can be negative)
        var physicalPositions: [CGDirectDisplayID: CGPoint] = [:]
        physicalPositions[originID] = CGPoint(x: 0, y: 0)

        // BFS queue
        var queue: [CGDirectDisplayID] = [originID]
        var processed: Set<CGDirectDisplayID> = [originID]

        while !queue.isEmpty {
            let currentID = queue.removeFirst()
            guard let currentData = displayMap[currentID],
                  let currentPhysicalPos = physicalPositions[currentID] else {
                continue
            }

            let currentLogical = currentData.logical.frame
            let currentPhysical = currentData.screen.physicalSize

            // Find adjacent displays
            for (candidateID, candidateData) in displayMap {
                if processed.contains(candidateID) { continue }

                let candidateLogical = candidateData.logical.frame
                let candidatePhysical = candidateData.screen.physicalSize

                var newPhysicalPos: CGPoint? = nil

                // Check if adjacent (borders touch)
                let epsilon: CGFloat = 1.0

                // Top: current.maxY == candidate.minY
                if abs(currentLogical.maxY - candidateLogical.minY) < epsilon {
                    newPhysicalPos = CGPoint(
                        x: currentPhysicalPos.x + (candidateLogical.minX - currentLogical.minX) / currentLogical.width * currentPhysical.width,
                        y: currentPhysicalPos.y + currentPhysical.height
                    )
                }
                // Bottom: current.minY == candidate.maxY
                else if abs(currentLogical.minY - candidateLogical.maxY) < epsilon {
                    newPhysicalPos = CGPoint(
                        x: currentPhysicalPos.x + (candidateLogical.minX - currentLogical.minX) / currentLogical.width * currentPhysical.width,
                        y: currentPhysicalPos.y - candidatePhysical.height
                    )
                }
                // Right: current.maxX == candidate.minX
                else if abs(currentLogical.maxX - candidateLogical.minX) < epsilon {
                    newPhysicalPos = CGPoint(
                        x: currentPhysicalPos.x + currentPhysical.width,
                        y: currentPhysicalPos.y + (candidateLogical.minY - currentLogical.minY) / currentLogical.height * currentPhysical.height
                    )
                }
                // Left: current.minX == candidate.maxX
                else if abs(currentLogical.minX - candidateLogical.maxX) < epsilon {
                    newPhysicalPos = CGPoint(
                        x: currentPhysicalPos.x - candidatePhysical.width,
                        y: currentPhysicalPos.y + (candidateLogical.minY - currentLogical.minY) / currentLogical.height * currentPhysical.height
                    )
                }

                if let pos = newPhysicalPos {
                    physicalPositions[candidateID] = pos
                    processed.insert(candidateID)
                    queue.append(candidateID)
                }
            }
        }

        // Calculate bounds of physical positions
        let allPhysicalX = physicalPositions.values.map { $0.x }
        let allPhysicalY = physicalPositions.values.map { $0.y }
        let minPhysicalX = allPhysicalX.min() ?? 0
        let maxPhysicalX = (physicalPositions.map { id, pos in
            pos.x + (displayMap[id]?.screen.physicalSize.width ?? 0)
        }).max() ?? 1000
        let minPhysicalY = allPhysicalY.min() ?? 0
        let maxPhysicalY = (physicalPositions.map { id, pos in
            pos.y + (displayMap[id]?.screen.physicalSize.height ?? 0)
        }).max() ?? 1000

        let totalPhysicalWidth = maxPhysicalX - minPhysicalX
        let totalPhysicalHeight = maxPhysicalY - minPhysicalY

        // Calculate scale to fit in canvas
        let scaleX = (canvasSize.width * 0.9) / totalPhysicalWidth
        let scaleY = (canvasSize.height * 0.9) / totalPhysicalHeight
        let fitScale = min(scaleX, scaleY, 0.5)
        currentScale = fitScale
        updateScaleInfo()

        // Create displayID -> colorIndex mapping from logical displays
        let colorIndexMap = Dictionary(uniqueKeysWithValues: logicalDisplays.map { ($0.displayID, $0.colorIndex) })

        // Build physical displays
        physicalDisplays = screenInfos.compactMap { info in
            guard let physicalPos = physicalPositions[info.displayID] else {
                return nil
            }

            // Convert physical mm to canvas coordinates
            let relativeX = physicalPos.x - minPhysicalX
            let relativeY = physicalPos.y - minPhysicalY

            let scaledX = relativeX * fitScale
            let scaledY = relativeY * fitScale
            let scaledWidth = info.physicalSize.width * fitScale
            let scaledHeight = info.physicalSize.height * fitScale

            // Flip Y axis: physical bottom (Y=0) becomes canvas bottom (Y=max)
            let totalScaledHeight = totalPhysicalHeight * fitScale
            let flippedY = totalScaledHeight - scaledY - scaledHeight

            // Add margin to center
            let marginX = (canvasSize.width - totalPhysicalWidth * fitScale) / 2
            let marginY = (canvasSize.height - totalPhysicalHeight * fitScale) / 2

            let canvasX = marginX + scaledX
            let canvasY = marginY + flippedY

            // Calculate position similar to logical displays (for .offset)
            let scaledFrame = CGRect(x: canvasX, y: canvasY, width: scaledWidth, height: scaledHeight)

            let result = PhysicalDisplay(
                id: UUID(),
                displayID: info.displayID,
                identifier: DisplayIdentifier(displayID: info.displayID),
                name: info.name,
                physicalPosition: physicalPos,
                physicalSize: info.physicalSize,
                scaledPosition: CGPoint(x: scaledFrame.minX, y: scaledFrame.minY),
                scaledSize: CGSize(width: scaledWidth, height: scaledHeight),
                isBuiltIn: info.isBuiltIn,
                resolution: CGSize(width: info.screen.frame.width * info.screen.backingScaleFactor,
                                 height: info.screen.frame.height * info.screen.backingScaleFactor),
                ppi: info.ppi,
                colorIndex: colorIndexMap[info.displayID] ?? 0
            )


            return result
        }
    }

    private func loadPhysicalDisplaysFromCalibration(_ config: DisplayConfiguration, screenInfos: [ScreenInfo]) {
        // Create displayID -> colorIndex mapping from logical displays
        let colorIndexMap = Dictionary(uniqueKeysWithValues: logicalDisplays.map { ($0.displayID, $0.colorIndex) })

        // Load physical positions from saved config, but defer scaled position calculation to refitToCanvas
        physicalDisplays = config.displays.compactMap { layout in
            guard let info = screenInfos.first(where: {
                DisplayIdentifier(displayID: $0.displayID) == layout.identifier
            }) else {
                return nil
            }

            NSLog("📦 Loading saved physical display: \(info.name) at physical (\(layout.position.x), \(layout.position.y)) size \(layout.size.width)x\(layout.size.height) mm")

            // Use placeholder scaled positions - these will be recalculated by refitToCanvas
            return PhysicalDisplay(
                id: UUID(),
                displayID: info.displayID,
                identifier: layout.identifier,
                name: info.name,
                physicalPosition: CGPoint(x: layout.position.x, y: layout.position.y),
                physicalSize: CGSize(width: layout.size.width, height: layout.size.height),
                scaledPosition: CGPoint(x: 0, y: 0),  // Will be recalculated
                scaledSize: CGSize(width: 0, height: 0),  // Will be recalculated
                isBuiltIn: info.isBuiltIn,
                resolution: CGSize(width: info.screen.frame.width * info.screen.backingScaleFactor,
                                 height: info.screen.frame.height * info.screen.backingScaleFactor),
                ppi: info.ppi,
                colorIndex: colorIndexMap[info.displayID] ?? 0
            )
        }

        // Trigger immediate refit with current canvas size (will be called again with correct size later)
        refitToCanvas(force: true)
    }

    func updatePosition(for id: UUID, offset: CGSize) {
        guard let index = physicalDisplays.firstIndex(where: { $0.id == id }) else { return }

        var display = physicalDisplays[index]
        var newScaledX = display.scaledPosition.x + offset.width
        var newScaledY = display.scaledPosition.y + offset.height

        // Check collision with other displays
        let newRect = CGRect(x: newScaledX, y: newScaledY, width: display.scaledSize.width, height: display.scaledSize.height)

        // Collect all overlapping rectangles
        var overlappingRects: [(rect: CGRect, index: Int)] = []
        for (otherIndex, other) in physicalDisplays.enumerated() {
            if otherIndex == index { continue }
            let otherRect = CGRect(x: other.scaledPosition.x, y: other.scaledPosition.y,
                                  width: other.scaledSize.width, height: other.scaledSize.height)
            if newRect.intersects(otherRect) {
                overlappingRects.append((otherRect, otherIndex))
            }
        }

        if overlappingRects.count == 1 {
            // Single overlap: find minimum overlap direction among all 4 directions
            let otherRect = overlappingRects[0].rect

            let overlapLeft = otherRect.maxX - newRect.minX
            let overlapRight = newRect.maxX - otherRect.minX
            let overlapTop = otherRect.maxY - newRect.minY
            let overlapBottom = newRect.maxY - otherRect.minY

            let minOverlap = min(overlapLeft, overlapRight, overlapTop, overlapBottom)

            if minOverlap == overlapLeft {
                newScaledX = otherRect.maxX
            } else if minOverlap == overlapRight {
                newScaledX = otherRect.minX - display.scaledSize.width
            } else if minOverlap == overlapTop {
                newScaledY = otherRect.maxY
            } else {
                newScaledY = otherRect.minY - display.scaledSize.height
            }
        } else if overlappingRects.count > 1 {
            // Multiple overlaps: adjust X and Y independently
            var minXAdjustment: (amount: CGFloat, newX: CGFloat)? = nil
            var minYAdjustment: (amount: CGFloat, newY: CGFloat)? = nil

            for (otherRect, _) in overlappingRects {
                let overlapLeft = otherRect.maxX - newRect.minX
                let overlapRight = newRect.maxX - otherRect.minX
                let overlapTop = otherRect.maxY - newRect.minY
                let overlapBottom = newRect.maxY - otherRect.minY

                // Find minimum X-axis adjustment
                let leftAdjustment = abs(overlapLeft)
                let rightAdjustment = abs(overlapRight)

                if leftAdjustment < rightAdjustment {
                    let candidateX = otherRect.maxX
                    if minXAdjustment == nil || leftAdjustment < minXAdjustment!.amount {
                        minXAdjustment = (leftAdjustment, candidateX)
                    }
                } else {
                    let candidateX = otherRect.minX - display.scaledSize.width
                    if minXAdjustment == nil || rightAdjustment < minXAdjustment!.amount {
                        minXAdjustment = (rightAdjustment, candidateX)
                    }
                }

                // Find minimum Y-axis adjustment
                let topAdjustment = abs(overlapTop)
                let bottomAdjustment = abs(overlapBottom)

                if topAdjustment < bottomAdjustment {
                    let candidateY = otherRect.maxY
                    if minYAdjustment == nil || topAdjustment < minYAdjustment!.amount {
                        minYAdjustment = (topAdjustment, candidateY)
                    }
                } else {
                    let candidateY = otherRect.minY - display.scaledSize.height
                    if minYAdjustment == nil || bottomAdjustment < minYAdjustment!.amount {
                        minYAdjustment = (bottomAdjustment, candidateY)
                    }
                }
            }

            // Apply adjustments for both axes
            if let xAdj = minXAdjustment {
                newScaledX = xAdj.newX
            }
            if let yAdj = minYAdjustment {
                newScaledY = yAdj.newY
            }
        }

        // Calculate change in scaled position
        let deltaScaledX = newScaledX - display.scaledPosition.x
        let deltaScaledY = newScaledY - display.scaledPosition.y

        // Update scaled position
        display.scaledPosition = CGPoint(x: newScaledX, y: newScaledY)

        // Update physical position using delta (preserves relative positions)
        // Physical Y-axis is inverted (increases upward), so we subtract deltaScaledY
        let deltaPhysicalX = deltaScaledX / currentScale
        let deltaPhysicalY = -deltaScaledY / currentScale  // Y-axis inversion

        display.physicalPosition = CGPoint(
            x: display.physicalPosition.x + deltaPhysicalX,
            y: display.physicalPosition.y + deltaPhysicalY
        )

        physicalDisplays[index] = display

        // Normalize physical positions to keep origin display at (0, 0)
        // This must be done BEFORE refitToCanvas so that the canvas calculation
        // uses the normalized physical positions
        normalizePhysicalPositions()

        // Refit to canvas after normalization to ensure proper scaling and centering
        // This recalculates scaled positions from the normalized physical positions
        refitToCanvas(force: true)

        // Notify laser display for real-time preview
        notifyCalibrationChange()
    }

    /// Normalize physical positions so that the origin display is at (0, 0)
    /// The origin display is the one containing logical point (0, 0)
    private func normalizePhysicalPositions() {
        let (logical, _) = calibrationManager.getCurrentDisplayConfiguration()
        guard let originDisplay = logical.first(where: { $0.frame.contains(CGPoint(x: 0, y: 0)) }),
              let originPhysical = physicalDisplays.first(where: {
                  DisplayIdentifier(displayID: $0.displayID) == originDisplay.identifier
              }) else {
            return
        }

        let offsetX = originPhysical.physicalPosition.x
        let offsetY = originPhysical.physicalPosition.y

        // Skip if already normalized
        if offsetX == 0 && offsetY == 0 {
            return
        }

        // Apply offset to all displays
        for i in 0..<physicalDisplays.count {
            physicalDisplays[i].physicalPosition = CGPoint(
                x: physicalDisplays[i].physicalPosition.x - offsetX,
                y: physicalDisplays[i].physicalPosition.y - offsetY
            )
        }
    }

    private func updatePhysicalPositionsFromCanvas() {
        // This function is called after drag to update physical positions
        // We don't need to do anything here because physical positions
        // will be recalculated properly when saving
        // For now, just keep the old physical positions unchanged
    }

    private func refitToCanvas(force: Bool = false) {
        // Calculate physical bounds (in mm)
        let allPhysicalMinX = physicalDisplays.map { $0.physicalPosition.x }.min() ?? 0
        let allPhysicalMinY = physicalDisplays.map { $0.physicalPosition.y }.min() ?? 0
        let allPhysicalMaxX = physicalDisplays.map { $0.physicalPosition.x + $0.physicalSize.width }.max() ?? 1000
        let allPhysicalMaxY = physicalDisplays.map { $0.physicalPosition.y + $0.physicalSize.height }.max() ?? 1000

        let physicalWidth = allPhysicalMaxX - allPhysicalMinX
        let physicalHeight = allPhysicalMaxY - allPhysicalMinY

        // Calculate optimal scale to fit in canvas (allow both zoom in and zoom out)
        let scaleX = (canvasSize.width * 0.9) / physicalWidth
        let scaleY = (canvasSize.height * 0.9) / physicalHeight
        let newScale = min(scaleX, scaleY)  // Remove 0.5 limit to allow zoom in

        // Check if scale needs update (allow 5% tolerance, unless forced)
        if !force {
            let scaleTolerance: CGFloat = 0.05
            let scaleRatio = abs(newScale - currentScale) / currentScale

            if scaleRatio <= scaleTolerance {
                return
            }
        }

        // Update scale and recalculate all canvas positions from physical positions
        currentScale = newScale
        updateScaleInfo()

        var updatedDisplays = physicalDisplays

        for i in 0..<updatedDisplays.count {
            let physicalPos = updatedDisplays[i].physicalPosition
            let physicalSize = updatedDisplays[i].physicalSize

            // Convert physical mm to canvas coordinates
            let relativeX = physicalPos.x - allPhysicalMinX
            let relativeY = physicalPos.y - allPhysicalMinY

            let scaledX = relativeX * newScale
            let scaledY = relativeY * newScale
            let scaledWidth = physicalSize.width * newScale
            let scaledHeight = physicalSize.height * newScale

            // Flip Y axis: physical bottom (Y=0) becomes canvas bottom (Y=max)
            let totalScaledHeight = physicalHeight * newScale
            let flippedY = totalScaledHeight - scaledY - scaledHeight

            // Add margin to center
            let marginX = (canvasSize.width - physicalWidth * newScale) / 2
            let marginY = (canvasSize.height - physicalHeight * newScale) / 2

            let canvasX = marginX + scaledX
            let canvasY = marginY + flippedY

            updatedDisplays[i].scaledPosition = CGPoint(x: canvasX, y: canvasY)
            updatedDisplays[i].scaledSize = CGSize(width: scaledWidth, height: scaledHeight)
        }

        // Trigger UI update by reassigning the array
        physicalDisplays = updatedDisplays
    }

    func resetToDefault() {
        let (_, physical) = calibrationManager.getCurrentDisplayConfiguration()
        loadDefaultPhysicalDisplays(physical)

        // Regenerate default edge zones
        let layouts = physicalDisplays.map { display in
            PhysicalDisplayLayout(
                identifier: display.identifier,
                position: PhysicalDisplayLayout.PhysicalPoint(x: display.physicalPosition.x, y: display.physicalPosition.y),
                size: PhysicalDisplayLayout.PhysicalSize(width: display.physicalSize.width, height: display.physicalSize.height)
            )
        }
        let screens = NSScreen.screens
        let (zones, pairs) = calibrationManager.generateDefaultEdgeZonePairs(displays: layouts, screens: screens)
        edgeZones = zones
        edgeZonePairs = pairs
        // Store as default zones for comparison
        defaultEdgeZones = zones
        defaultEdgeZonePairs = pairs
        selectedEdgeZoneIds = []  // Clear selection
        NSLog("📍 Reset edge zones: \(edgeZones.count) zones and \(edgeZonePairs.count) pairs")

        // Notify laser display for real-time preview
        notifyCalibrationChange()
    }

    func saveCalibration() {
        NSLog("💾 saveCalibration called")

        // Log current physical positions before saving
        for display in physicalDisplays {
            NSLog("💾 Saving display: \(display.name) at physical (\(display.physicalPosition.x), \(display.physicalPosition.y))")
        }

        // Physical positions are already normalized by normalizePhysicalPositions()
        // (called after every drag operation)
        let layouts = physicalDisplays.map { display in
            PhysicalDisplayLayout(
                identifier: display.identifier,
                position: PhysicalDisplayLayout.PhysicalPoint(
                    x: display.physicalPosition.x,
                    y: display.physicalPosition.y
                ),
                size: PhysicalDisplayLayout.PhysicalSize(
                    width: display.physicalSize.width,
                    height: display.physicalSize.height
                )
            )
        }

        let configuration = DisplayConfiguration(
            displays: layouts,
            timestamp: Date(),
            edgeZones: edgeZones,
            edgeZonePairs: edgeZonePairs
        )

        calibrationManager.saveCalibration(configuration)
        hasExistingCalibration = true

        NSLog("💾 Configuration saved successfully")

        // Update saved configuration to new save point
        savedConfiguration = configuration

        // Clear temporary configuration
        calibrationManager.clearTemporaryCalibration()

        // Notify laser display to reload physical configuration
        NotificationCenter.default.post(name: .calibrationDidSave, object: nil)

        NSLog("💾 Calibration save complete")
    }

    func restoreOriginal() {
        guard let saved = savedConfiguration else {
            return
        }

        // Clear temporary configuration
        calibrationManager.clearTemporaryCalibration()

        // Reload from saved configuration
        let (_, physical) = calibrationManager.getCurrentDisplayConfiguration()
        loadPhysicalDisplaysFromCalibration(saved, screenInfos: physical)

        // Notify laser display to restore original configuration
        NotificationCenter.default.post(name: .calibrationDidChange, object: nil)
    }

    private func notifyCalibrationChange() {
        // Build temporary configuration from current physical displays
        let layouts = physicalDisplays.map { display in
            PhysicalDisplayLayout(
                identifier: display.identifier,
                position: PhysicalDisplayLayout.PhysicalPoint(
                    x: display.physicalPosition.x,
                    y: display.physicalPosition.y
                ),
                size: PhysicalDisplayLayout.PhysicalSize(
                    width: display.physicalSize.width,
                    height: display.physicalSize.height
                )
            )
        }

        let tempConfiguration = DisplayConfiguration(
            displays: layouts,
            timestamp: Date()
        )

        // Temporarily save to allow laser display to load it
        calibrationManager.saveCalibrationTemporary(tempConfiguration)

        // Notify laser display for real-time preview
        NotificationCenter.default.post(name: .calibrationDidChange, object: nil)
    }

    private func updateScaleInfo() {
        let ratio = 1.0 / currentScale
        scaleInfo = String(format: "Scale: 1:%.1f (1px = %.1fmm)", ratio, ratio)
    }

    // Calculate physical position from canvas position (for real-time display during drag)
    func calculatePhysicalPosition(from canvasPosition: CGPoint, scaledSize: CGSize) -> CGPoint {
        let allCanvasX = physicalDisplays.map { $0.scaledPosition.x }
        let allCanvasY = physicalDisplays.map { $0.scaledPosition.y }
        let minCanvasX = allCanvasX.min() ?? 0
        let minCanvasY = allCanvasY.min() ?? 0

        let maxCanvasX = (physicalDisplays.map { $0.scaledPosition.x + $0.scaledSize.width }).max() ?? canvasSize.width
        let maxCanvasY = (physicalDisplays.map { $0.scaledPosition.y + $0.scaledSize.height }).max() ?? canvasSize.height

        let totalCanvasWidth = maxCanvasX - minCanvasX
        let totalCanvasHeight = maxCanvasY - minCanvasY

        let marginX = (canvasSize.width - totalCanvasWidth) / 2
        let marginY = (canvasSize.height - totalCanvasHeight) / 2

        let relativeX = canvasPosition.x - marginX
        let relativeY = canvasPosition.y - marginY

        // Unflip Y axis
        let unflippedY = totalCanvasHeight - relativeY - scaledSize.height

        let physicalX = relativeX / currentScale
        let physicalY = unflippedY / currentScale

        return CGPoint(x: physicalX, y: physicalY)
    }

    // MARK: - Flash Control

    /// Start flashing a display number (2 seconds auto-hide)
    func startFlash(displayNumber: Int) {
        // Cancel previous timer
        flashTimer?.cancel()

        // Set flashing number
        flashingDisplayNumber = displayNumber

        // Notify all observers (including LaserViewModel instances)
        NotificationCenter.default.post(
            name: .flashingDisplayNumberDidChange,
            object: displayNumber
        )

        // Auto-hide after 2 seconds
        let hideTask = DispatchWorkItem { [weak self] in
            self?.flashingDisplayNumber = nil
            // Notify with nil to hide all flashes
            NotificationCenter.default.post(
                name: .flashingDisplayNumberDidChange,
                object: nil as Int?
            )
        }
        flashTimer = hideTask
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: hideTask)
    }

    /// Start flashing and keep it visible (for drag)
    func startContinuousFlash(displayNumber: Int) {
        // If already flashing this number, do nothing
        guard flashingDisplayNumber != displayNumber else { return }

        // Cancel previous timer
        flashTimer?.cancel()

        // Set flashing number
        flashingDisplayNumber = displayNumber

        // Notify all observers
        NotificationCenter.default.post(
            name: .flashingDisplayNumberDidChange,
            object: displayNumber
        )
    }

    /// Stop continuous flash and cancel any pending timers
    func stopContinuousFlash() {
        // Cancel any pending auto-hide timer
        flashTimer?.cancel()
        flashTimer = nil

        flashingDisplayNumber = nil
        // Notify with nil to hide all flashes
        NotificationCenter.default.post(
            name: .flashingDisplayNumberDidChange,
            object: nil as Int?
        )
    }

    /// Generate debug information and copy to clipboard
    func copyDebugInfo() {
        NSLog("🔍 copyDebugInfo() called")

        // Capture state on main thread (quick snapshot)
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let screens = NSScreen.screens
        let physicalDisplaysCopy = self.physicalDisplays
        let edgeZonesCopy = self.edgeZones
        let edgeZonePairsCopy = self.edgeZonePairs
        let configKey = self.currentConfigKey
        let savedConfig = calibrationManager.loadCalibration()
        let canvasSizeCopy = self.canvasSize
        let currentScaleCopy = self.currentScale

        // Move heavy JSON generation to background thread
        DispatchQueue.global(qos: .userInitiated).async {
            var debugInfo: [String: Any] = [:]

            // App version
            if let version = appVersion {
                debugInfo["app_version"] = version
            }

            // macOS version
            debugInfo["macos_version"] = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"

            // Canvas and scale info
            debugInfo["canvas_size"] = ["width": canvasSizeCopy.width, "height": canvasSizeCopy.height]
            debugInfo["current_scale"] = currentScaleCopy

            // Screen information
            var screensInfo: [[String: Any]] = []
            for screen in screens {
                var screenInfo: [String: Any] = [:]
                screenInfo["frame"] = [
                    "x": screen.frame.origin.x,
                    "y": screen.frame.origin.y,
                    "width": screen.frame.size.width,
                    "height": screen.frame.size.height
                ]
                if let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                    screenInfo["display_id"] = displayID
                }
                screensInfo.append(screenInfo)
            }
            debugInfo["screens"] = screensInfo

            // Physical displays
            var physicalDisplaysInfo: [[String: Any]] = []
            for display in physicalDisplaysCopy {
                var displayInfo: [String: Any] = [:]
                displayInfo["name"] = display.name
                displayInfo["is_built_in"] = display.isBuiltIn
                displayInfo["physical_position"] = ["x": display.physicalPosition.x, "y": display.physicalPosition.y]
                displayInfo["physical_size"] = ["width": display.physicalSize.width, "height": display.physicalSize.height]
                displayInfo["scaled_position"] = ["x": display.scaledPosition.x, "y": display.scaledPosition.y]
                displayInfo["scaled_size"] = ["width": display.scaledSize.width, "height": display.scaledSize.height]
                displayInfo["resolution"] = ["width": display.resolution.width, "height": display.resolution.height]
                displayInfo["ppi"] = display.ppi
                physicalDisplaysInfo.append(displayInfo)
            }
            debugInfo["physical_displays"] = physicalDisplaysInfo

            // Edge zones
            var edgeZonesInfo: [[String: Any]] = []
            for zone in edgeZonesCopy {
                var zoneInfo: [String: Any] = [:]
                zoneInfo["id"] = zone.id.uuidString
                zoneInfo["edge"] = "\(zone.edge)"
                zoneInfo["display_id"] = zone.displayId
                zoneInfo["range_start"] = zone.rangeStart
                zoneInfo["range_end"] = zone.rangeEnd
                edgeZonesInfo.append(zoneInfo)
            }
            debugInfo["edge_zones"] = edgeZonesInfo

            // Edge zone pairs
            var pairsInfo: [[String: Any]] = []
            for pair in edgeZonePairsCopy {
                var pairInfo: [String: Any] = [:]
                pairInfo["source_zone_id"] = pair.sourceZoneId.uuidString
                pairInfo["target_zone_id"] = pair.targetZoneId.uuidString
                pairsInfo.append(pairInfo)
            }
            debugInfo["edge_zone_pairs"] = pairsInfo

            // Settings
            var settings: [String: Any] = [:]
            settings["use_physical_layout"] = UserDefaults.standard.object(forKey: "UsePhysicalLayout") as? Bool ?? true
            settings["show_edge_zones"] = UserDefaults.standard.object(forKey: "ShowEdgeZones") as? Bool ?? false
            settings["smart_edge_navigation"] = UserDefaults.standard.object(forKey: "SmartEdgeNavigationEnabled") as? Bool ?? true
            settings["guard_edge"] = UserDefaults.standard.object(forKey: "GuardEdgeEnabled") as? Bool ?? true
            debugInfo["settings"] = settings

            // Saved configuration (if exists)
            if let config = savedConfig {
                var savedConfigInfo: [String: Any] = [:]
                savedConfigInfo["config_key"] = configKey ?? "unknown"
                savedConfigInfo["timestamp"] = config.timestamp.description

                // Saved displays
                var savedDisplaysInfo: [[String: Any]] = []
                for display in config.displays {
                    var displayInfo: [String: Any] = [:]
                    displayInfo["identifier"] = display.identifier.stringRepresentation
                    displayInfo["position"] = ["x": display.position.x, "y": display.position.y]
                    displayInfo["size"] = ["width": display.size.width, "height": display.size.height]
                    savedDisplaysInfo.append(displayInfo)
                }
                savedConfigInfo["saved_displays"] = savedDisplaysInfo

                // Saved edge zones
                var savedEdgeZonesInfo: [[String: Any]] = []
                for zone in config.edgeZones {
                    var zoneInfo: [String: Any] = [:]
                    zoneInfo["id"] = zone.id.uuidString
                    zoneInfo["edge"] = "\(zone.edge)"
                    zoneInfo["display_id"] = zone.displayId
                    zoneInfo["range_start"] = zone.rangeStart
                    zoneInfo["range_end"] = zone.rangeEnd
                    savedEdgeZonesInfo.append(zoneInfo)
                }
                savedConfigInfo["saved_edge_zones"] = savedEdgeZonesInfo

                // Saved edge zone pairs
                var savedPairsInfo: [[String: Any]] = []
                for pair in config.edgeZonePairs {
                    var pairInfo: [String: Any] = [:]
                    pairInfo["source_zone_id"] = pair.sourceZoneId.uuidString
                    pairInfo["target_zone_id"] = pair.targetZoneId.uuidString
                    savedPairsInfo.append(pairInfo)
                }
                savedConfigInfo["saved_edge_zone_pairs"] = savedPairsInfo

                debugInfo["saved_configuration"] = savedConfigInfo
            } else {
                debugInfo["saved_configuration"] = nil
            }

            // Convert to JSON
            do {
                let jsonData = try JSONSerialization.data(withJSONObject: debugInfo, options: [.prettyPrinted, .sortedKeys])

                if let jsonString = String(data: jsonData, encoding: .utf8) {
                    // Copy to clipboard on main thread
                    DispatchQueue.main.async {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        _ = pasteboard.setString(jsonString, forType: .string)
                    }
                } else {
                    NSLog("❌ Failed to convert JSON data to string")
                }
            } catch {
                NSLog("❌ Failed to generate debug info: \(error)")
            }
        }
    }
}

// MARK: - Display Models

struct LogicalDisplay: Identifiable {
    let id: UUID
    let displayID: CGDirectDisplayID
    let identifier: DisplayIdentifier
    let name: String
    let frame: CGRect  // Original logical coordinates
    let scaledFrame: CGRect  // Scaled for display in UI
    let isBuiltIn: Bool
    let colorIndex: Int  // For color differentiation
}

struct PhysicalDisplay: Identifiable {
    let id: UUID
    let displayID: CGDirectDisplayID
    let identifier: DisplayIdentifier
    let name: String
    var physicalPosition: CGPoint  // In mm
    var physicalSize: CGSize  // In mm
    var scaledPosition: CGPoint  // For SwiftUI .position (center point)
    var scaledSize: CGSize  // For SwiftUI .frame
    let isBuiltIn: Bool
    let resolution: CGSize  // Pixel resolution
    let ppi: CGFloat
    let colorIndex: Int  // For color differentiation
}
