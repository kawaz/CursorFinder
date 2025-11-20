// CalibrationWindow.swift
import SwiftUI

// MARK: - Display Color Helper

extension Color {
    /// Generate display color based on color index
    /// - colorIndex 0: Blue (built-in display)
    /// - colorIndex 1+: Distinct colors for external displays
    static func displayColor(for colorIndex: Int) -> Color {
        switch colorIndex {
        case 0: return .blue      // Built-in
        case 1: return .orange
        case 2: return .green
        case 3: return .purple
        case 4: return .red
        case 5: return .cyan
        case 6: return .yellow
        case 7: return .pink
        default:
            // Generate color from hue for 8+ displays
            let hue = Double((colorIndex - 8) % 12) / 12.0
            return Color(hue: hue, saturation: 0.7, brightness: 0.9)
        }
    }
}

struct CalibrationView: View {
    @StateObject private var viewModel = CalibrationViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var logicalWidth: CGFloat = 350

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            // Main content: Logical vs Physical comparison
            GeometryReader { containerGeometry in
                HStack(alignment: .top, spacing: 20) {
                    // Left: Logical coordinate system (resizable)
                    logicalDisplayView()
                        .frame(width: logicalWidth)

                    // Resizable divider
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 6)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    let containerWidth = containerGeometry.size.width
                                    let minSideWidth: CGFloat = 50  // Minimum width for both sides (just enough for UI)
                                    let dividerWidth: CGFloat = 6
                                    let spacing: CGFloat = 20
                                    let maxLogicalWidth = containerWidth - minSideWidth - dividerWidth - spacing * 2

                                    let newWidth = logicalWidth + value.translation.width
                                    logicalWidth = min(max(newWidth, minSideWidth), maxLogicalWidth)
                                }
                        )
                        .onHover { hovering in
                            if hovering {
                                NSCursor.resizeLeftRight.push()
                            } else {
                                NSCursor.pop()
                            }
                        }

                    // Right: Physical coordinate system (takes remaining space)
                    physicalDisplayView()
                }
            }
            .padding()

            Divider()

            // Footer: Controls
            footerView
        }
        .frame(minWidth: 900, minHeight: 600)
        .contentShape(Rectangle())
        .onTapGesture {
            // Clear all selections when tapping anywhere in the window (outside interactive elements)
            if !viewModel.selectedEdgeZoneIds.isEmpty {
                NSLog("🔵 Clearing all edge zone selections (window-wide tap)")
                viewModel.selectedEdgeZoneIds = []
            }
        }
        .onAppear {
            viewModel.loadConfiguration()
        }
    }

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("Physical Display Layout Calibration")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Drag displays on the right to match your actual physical setup")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let key = viewModel.currentConfigKey {
                    Text("Configuration: \(key)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.blue)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func logicalDisplayView() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Logical Coordinates (macOS)")
                .font(.headline)

            GeometryReader { geometry in
                ZStack {
                    Rectangle()
                        .fill(Color.black.opacity(0.1))
                        .border(Color.gray, width: 1)

                    // Draw logical displays
                    ForEach(viewModel.logicalDisplays) { display in
                        LogicalDisplayRect(display: display, canvasSize: geometry.size, viewModel: viewModel)
                    }
                }
                .onChange(of: geometry.size) { _, newSize in
                    viewModel.updateLogicalCanvasSize(newSize)
                }
                .onAppear {
                    viewModel.updateLogicalCanvasSize(geometry.size)
                }
            }

            HStack {
                Text("This is how macOS sees your displays")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button("Open Display Settings...") {
                    openDisplaySettings()
                }
                .font(.caption)
                .buttonStyle(.link)
            }
            .frame(height: 20)
        }
    }

    private func openDisplaySettings() {
        // Try macOS 13+ first
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.displays") {
            // Fallback for macOS 12 and earlier
            NSWorkspace.shared.open(url)
        }
    }

    private func physicalDisplayView() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Physical Layout (Drag to Arrange)")
                .font(.headline)

            GeometryReader { geometry in
                ZStack {
                    Rectangle()
                        .fill(Color.black.opacity(0.1))
                        .border(Color.gray, width: 1)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Clear all selections when tapping canvas background
                            if !viewModel.selectedEdgeZoneIds.isEmpty {
                                NSLog("🔵 Clearing all edge zone selections")
                                viewModel.selectedEdgeZoneIds = []
                            }
                        }

                    // Draw physical displays (draggable)
                    ForEach(viewModel.physicalDisplays) { display in
                        PhysicalDisplayRect(
                            display: display,
                            canvasSize: geometry.size,
                            viewModel: viewModel,
                            onDrag: { offset in
                                viewModel.updatePosition(for: display.id, offset: offset)
                            }
                        )
                    }

                    // Draw edge zone overlay
                    EdgeZoneOverlay(
                        edgeZones: viewModel.displayedEdgeZones,
                        edgeZonePairs: viewModel.displayedEdgeZonePairs,
                        physicalDisplays: viewModel.physicalDisplays,
                        canvasSize: geometry.size,
                        viewModel: viewModel
                    )
                }
                .onChange(of: geometry.size) { _, newSize in
                    viewModel.updateCanvasSize(newSize)
                }
                .onAppear {
                    viewModel.updateCanvasSize(geometry.size)
                }
            }

            HStack {
                Spacer()

                Button(action: {
                    viewModel.copyDebugInfo()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.clipboard")
                            .imageScale(.small)
                        Text("Copy Debug Info")
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Text("Show Original Zones")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(viewModel.showingOriginalZones ? Color.blue : Color.gray.opacity(0.2))
                    .foregroundColor(viewModel.showingOriginalZones ? .white : .primary)
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                viewModel.showingOriginalZones = true
                            }
                            .onEnded { _ in
                                viewModel.showingOriginalZones = false
                            }
                    )
            }
            .frame(height: 20)
        }
    }

    private var footerView: some View {
        HStack {
            Spacer()

            Button("Reset to Default") {
                viewModel.resetToDefault()
            }

            Button("Cancel") {
                viewModel.restoreOriginal()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button("Save Calibration") {
                viewModel.saveCalibration()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

// MARK: - Display Rectangle Views

struct LogicalDisplayRect: View {
    let display: LogicalDisplay
    let canvasSize: CGSize
    @ObservedObject var viewModel: CalibrationViewModel

    var body: some View {
        let displayColor = Color.displayColor(for: display.colorIndex)
        let displayNumber = NSScreen.screens.firstIndex(where: { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == display.displayID }).map { $0 + 1 } ?? 0
        let isFlashing = viewModel.flashingDisplayNumber == displayNumber

        ZStack {
            Rectangle()
                .fill(displayColor.opacity(0.2))
                .border(displayColor, width: 2)

            if isFlashing {
                // Flash: Number sized to fit the display rectangle
                let size = min(display.scaledFrame.width, display.scaledFrame.height) * 0.6
                Text("\(displayNumber)")
                    .font(.system(size: size, weight: .bold, design: .rounded))
                    .foregroundColor(displayColor)
            } else {
                // Normal: Display info (center) - adaptively scaled
                displayInfoView(
                    name: display.name,
                    dimensions: "\(Int(display.frame.width))×\(Int(display.frame.height)) px",
                    displaySize: display.scaledFrame.size
                )
            }

            // Bottom-left coordinate
            coordinateLabel(
                text: "(\(Int(display.frame.minX)), \(Int(display.frame.minY)))",
                alignment: .bottomLeading,
                offset: CGPoint(x: 2, y: -2)
            )

            // Top-right coordinate
            coordinateLabel(
                text: "(\(Int(display.frame.maxX)), \(Int(display.frame.maxY)))",
                alignment: .topTrailing,
                offset: CGPoint(x: -2, y: 2)
            )
        }
        .frame(width: display.scaledFrame.width, height: display.scaledFrame.height)
        .position(
            x: display.scaledFrame.minX + display.scaledFrame.width / 2,
            y: display.scaledFrame.minY + display.scaledFrame.height / 2
        )
        .onTapGesture {
            // Flash the display number
            viewModel.startFlash(displayNumber: displayNumber)

            // Select all edge zones on this display AND their paired zones
            let displayId = display.identifier.stringRepresentation
            let zonesOnThisDisplay = viewModel.edgeZones.filter { $0.displayId == displayId }

            // For each zone on this display, find its paired zone(s)
            var zonesToSelect: Set<UUID> = []
            for zone in zonesOnThisDisplay {
                zonesToSelect.insert(zone.id)

                // Find paired zones via edge zone pairs
                for pair in viewModel.edgeZonePairs {
                    if pair.sourceZoneId == zone.id, let targetZone = viewModel.edgeZones.first(where: { $0.id == pair.targetZoneId }) {
                        zonesToSelect.insert(targetZone.id)
                    } else if pair.targetZoneId == zone.id, let sourceZone = viewModel.edgeZones.first(where: { $0.id == pair.sourceZoneId }) {
                        zonesToSelect.insert(sourceZone.id)
                    }
                }
            }

            NSLog("🟦 [DisplayRect] tap: selecting \(zonesToSelect.count) zones (including pairs)")
            viewModel.selectedEdgeZoneIds = zonesToSelect
        }
    }

    /// Display info with clipping to stay within display bounds
    @ViewBuilder
    private func displayInfoView(name: String, dimensions: String, displaySize: CGSize) -> some View {
        // Reserve minimal margin from border (just inside the border line)
        let margin: CGFloat = 2
        let maxWidth = displaySize.width - margin * 2
        let maxHeight = displaySize.height - margin * 2

        // Only show if there's enough space
        if maxWidth > 20 && maxHeight > 20 {
            VStack(alignment: .center, spacing: 2) {
                Text(name)
                    .font(.caption)
                    .fontWeight(.bold)
                    .lineLimit(1)
                Text(verbatim: dimensions)
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(1)
            }
            .padding(6)
            .background(Color.black.opacity(0.6))
            .foregroundColor(.white)
            .cornerRadius(4)
            .frame(maxWidth: maxWidth, maxHeight: maxHeight)
            .clipped()
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func coordinateLabel(text: String, alignment: Alignment, offset: CGPoint) -> some View {
        Text(text)
            .font(.system(size: 9, design: .monospaced))
            .padding(2)
            .foregroundColor(.white)
            .cornerRadius(2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .offset(x: offset.x, y: offset.y)
    }
}

struct PhysicalDisplayRect: View {
    let display: PhysicalDisplay
    let canvasSize: CGSize
    @ObservedObject var viewModel: CalibrationViewModel
    let onDrag: (CGSize) -> Void

    @State private var isDragging = false
    @GestureState private var dragOffset = CGSize.zero

    // Calculate current physical position (considering drag offset)
    // During drag: show raw physical position (lets user see how much they moved)
    // After drop: normalizePhysicalPositions() will reset origin display to (0,0)
    private var currentPhysicalPosition: CGPoint {
        if dragOffset == .zero {
            return display.physicalPosition
        }

        // Calculate raw physical position from canvas position
        let currentCanvasPosition = CGPoint(
            x: display.scaledPosition.x + dragOffset.width,
            y: display.scaledPosition.y + dragOffset.height
        )
        return viewModel.calculatePhysicalPosition(from: currentCanvasPosition, scaledSize: display.scaledSize)
    }

    var body: some View {
        let displayColor = Color.displayColor(for: display.colorIndex)
        let displayNumber = NSScreen.screens.firstIndex(where: { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == display.displayID }).map { $0 + 1 } ?? 0
        let isFlashing = viewModel.flashingDisplayNumber == displayNumber

        ZStack {
            Rectangle()
                .fill(displayColor.opacity(0.2))
                .border(displayColor, width: 2)

            // Edge zones for this display
            let displayZones = viewModel.displayedEdgeZones.filter { $0.displayId == display.identifier.stringRepresentation }

            // Draw block zones (border color lines for non-navigable areas)
            ForEach([EdgeDirection.top, .bottom, .left, .right], id: \.self) { edge in
                BlockZonesForEdge(edge: edge, zones: displayZones, displaySize: display.scaledSize, borderColor: displayColor)
            }

            // Draw edge zones (cyan lines for navigable areas)
            ForEach(displayZones) { zone in
                EdgeZoneInset(zone: zone, displaySize: display.scaledSize, viewModel: viewModel)
            }

            // Handles are now drawn at canvas level in EdgeZoneOverlay to avoid gesture conflicts

            if isFlashing {
                // Flash: Number sized to fit the display rectangle
                let size = min(display.scaledSize.width, display.scaledSize.height) * 0.6
                Text("\(displayNumber)")
                    .font(.system(size: size, weight: .bold, design: .rounded))
                    .foregroundColor(displayColor)
            } else {
                // Normal: Display info (center) - adaptively scaled
                displayInfoView(
                    name: display.name,
                    dimensions: "\(Int(display.physicalSize.width))×\(Int(display.physicalSize.height)) mm",
                    displaySize: display.scaledSize
                )
            }

            // Bottom-left coordinate (updates during drag)
            coordinateLabel(
                text: "(\(Int(currentPhysicalPosition.x)), \(Int(currentPhysicalPosition.y)))",
                alignment: .bottomLeading,
                offset: CGPoint(x: 2, y: -2)
            )

            // Top-right coordinate (updates during drag)
            coordinateLabel(
                text: "(\(Int(currentPhysicalPosition.x + display.physicalSize.width)), \(Int(currentPhysicalPosition.y + display.physicalSize.height)))",
                alignment: .topTrailing,
                offset: CGPoint(x: -2, y: 2)
            )
        }
        .frame(width: display.scaledSize.width, height: display.scaledSize.height)
        .position(
            x: display.scaledPosition.x + dragOffset.width + display.scaledSize.width / 2,
            y: display.scaledPosition.y + dragOffset.height + display.scaledSize.height / 2
        )
        .shadow(color: isDragging ? Color.blue.opacity(0.5) : Color.clear, radius: 10)
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($dragOffset) { value, state, _ in
                    state = value.translation
                    // Update drag offset in viewModel for connection lines
                    viewModel.dragOffsets[display.id] = value.translation
                }
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        // Stop any existing flash immediately when drag starts
                        viewModel.stopContinuousFlash()
                    }
                }
                .onEnded { value in
                    isDragging = false

                    // Clear drag offset
                    viewModel.dragOffsets[display.id] = .zero

                    // If barely moved, treat as tap
                    if abs(value.translation.width) < 3 && abs(value.translation.height) < 3 {
                        viewModel.startFlash(displayNumber: displayNumber)
                    } else {
                        onDrag(value.translation)
                    }
                }
        )
    }

    /// Display info with clipping to stay within display bounds
    @ViewBuilder
    private func displayInfoView(name: String, dimensions: String, displaySize: CGSize) -> some View {
        // Reserve minimal margin from border (just inside the border line)
        let margin: CGFloat = 2
        let maxWidth = displaySize.width - margin * 2
        let maxHeight = displaySize.height - margin * 2

        // Only show if there's enough space
        if maxWidth > 20 && maxHeight > 20 {
            VStack(alignment: .center, spacing: 2) {
                Text(name)
                    .font(.caption)
                    .fontWeight(.bold)
                    .lineLimit(1)
                Text(verbatim: dimensions)
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(1)
            }
            .padding(6)
            .background(Color.black.opacity(0.7))
            .foregroundColor(.white)
            .cornerRadius(4)
            .frame(maxWidth: maxWidth, maxHeight: maxHeight)
            .clipped()
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func coordinateLabel(text: String, alignment: Alignment, offset: CGPoint) -> some View {
        Text(text)
            .font(.system(size: 9, design: .monospaced))
            .padding(2)
            .foregroundColor(.white)
            .cornerRadius(2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .offset(x: offset.x, y: offset.y)
    }
}

// MARK: - Edge Zone Overlay

struct EdgeZoneOverlay: View {
    let edgeZones: [EdgeZone]
    let edgeZonePairs: [EdgeZonePair]
    let physicalDisplays: [PhysicalDisplay]
    let canvasSize: CGSize
    @ObservedObject var viewModel: CalibrationViewModel

    var body: some View {
        let isDraggingDisplay = viewModel.dragOffsets.values.contains(where: { $0 != .zero })

        return ZStack {
            // Draw connection lines between paired zones
            ForEach(edgeZonePairs) { pair in
                if let sourceZone = edgeZones.first(where: { $0.id == pair.sourceZoneId }),
                   let targetZone = edgeZones.first(where: { $0.id == pair.targetZoneId }) {
                    EdgeZonePairLine(
                        sourceZone: sourceZone,
                        targetZone: targetZone,
                        sourceDisplay: displayFor(zone: sourceZone),
                        targetDisplay: displayFor(zone: targetZone),
                        viewModel: viewModel
                    )
                }
            }

            // Draw handles for selected zones at canvas level (avoids gesture conflicts with display rectangles)
            if !isDraggingDisplay {
                ForEach(edgeZones.filter { viewModel.selectedEdgeZoneIds.contains($0.id) }) { zone in
                    if let display = displayFor(zone: zone) {
                        // Draw end handle (isStart=false) first
                        EdgeZoneHandleOverlay(
                            zone: zone,
                            display: display,
                            isStart: false,
                            viewModel: viewModel,
                            canvasHeight: canvasSize.height,
                            canvasWidth: canvasSize.width
                        )
                        // Draw start handle (isStart=true) on top
                        EdgeZoneHandleOverlay(
                            zone: zone,
                            display: display,
                            isStart: true,
                            viewModel: viewModel,
                            canvasHeight: canvasSize.height,
                            canvasWidth: canvasSize.width
                        )
                        .zIndex(1)
                    }
                }
            }
        }
    }

    private func displayFor(zone: EdgeZone) -> PhysicalDisplay? {
        return physicalDisplays.first { $0.identifier.stringRepresentation == zone.displayId }
    }
}

struct EdgeZoneView: View {
    let zone: EdgeZone
    let display: PhysicalDisplay?
    @ObservedObject var viewModel: CalibrationViewModel

    var body: some View {
        guard let display = display else { return AnyView(EmptyView()) }

        let zoneRect = calculateZoneRect(zone: zone, display: display)

        return AnyView(
            Rectangle()
                .fill(Color.cyan.opacity(0.6))
                .frame(width: zoneRect.width, height: zoneRect.height)
                .position(x: zoneRect.midX, y: zoneRect.midY)
        )
    }

    private func calculateZoneRect(zone: EdgeZone, display: PhysicalDisplay) -> CGRect {
        let scaledPos = display.scaledPosition
        let scaledSize = display.scaledSize
        let inset: CGFloat = 1  // Very close to border
        let thickness: CGFloat = 2  // Thin line

        switch zone.edge {
        case .top:
            let startX = scaledPos.x + scaledSize.width * zone.rangeStart
            let endX = scaledPos.x + scaledSize.width * zone.rangeEnd
            return CGRect(x: startX, y: scaledPos.y + inset, width: endX - startX, height: thickness)
        case .bottom:
            let startX = scaledPos.x + scaledSize.width * zone.rangeStart
            let endX = scaledPos.x + scaledSize.width * zone.rangeEnd
            return CGRect(x: startX, y: scaledPos.y + scaledSize.height - inset - thickness, width: endX - startX, height: thickness)
        case .left:
            let startY = scaledPos.y + scaledSize.height * zone.rangeStart
            let endY = scaledPos.y + scaledSize.height * zone.rangeEnd
            return CGRect(x: scaledPos.x + inset, y: startY, width: thickness, height: endY - startY)
        case .right:
            let startY = scaledPos.y + scaledSize.height * zone.rangeStart
            let endY = scaledPos.y + scaledSize.height * zone.rangeEnd
            return CGRect(x: scaledPos.x + scaledSize.width - inset - thickness, y: startY, width: thickness, height: endY - startY)
        }
    }
}

struct EdgeZonePairLine: View {
    let sourceZone: EdgeZone
    let targetZone: EdgeZone
    let sourceDisplay: PhysicalDisplay?
    let targetDisplay: PhysicalDisplay?
    @ObservedObject var viewModel: CalibrationViewModel

    var body: some View {
        guard let sourceDisplay = sourceDisplay,
              let targetDisplay = targetDisplay else {
            return AnyView(EmptyView())
        }

        // Get edge endpoints (start and end of the zone range)
        let sourceStart = zoneEdgePoint(zone: sourceZone, display: sourceDisplay, atStart: true)
        let sourceEnd = zoneEdgePoint(zone: sourceZone, display: sourceDisplay, atStart: false)
        let targetStart = zoneEdgePoint(zone: targetZone, display: targetDisplay, atStart: true)
        let targetEnd = zoneEdgePoint(zone: targetZone, display: targetDisplay, atStart: false)

        // Don't draw if displays are touching (distance < 10px)
        let sourceMid = CGPoint(x: (sourceStart.x + sourceEnd.x) / 2, y: (sourceStart.y + sourceEnd.y) / 2)
        let targetMid = CGPoint(x: (targetStart.x + targetEnd.x) / 2, y: (targetStart.y + targetEnd.y) / 2)
        let distance = hypot(targetMid.x - sourceMid.x, targetMid.y - sourceMid.y)

        if distance < 10 {
            return AnyView(EmptyView())
        }

        // Draw trapezoid connecting the two edge zones
        return AnyView(
            Path { path in
                path.move(to: sourceStart)
                path.addLine(to: targetStart)
                path.addLine(to: targetEnd)
                path.addLine(to: sourceEnd)
                path.closeSubpath()
            }
            .fill(Color.blue.opacity(0.15))  // Light fill to show movement area
            .contentShape(Path { path in
                path.move(to: sourceStart)
                path.addLine(to: targetStart)
                path.addLine(to: targetEnd)
                path.addLine(to: sourceEnd)
                path.closeSubpath()
            })
            .onTapGesture {
                // Select both edge zones in this pair
                let pairZoneIds: Set<UUID> = [sourceZone.id, targetZone.id]

                // Toggle: if both zones are already selected (and ONLY these), deselect; otherwise clear and select both
                if pairZoneIds.isSubset(of: viewModel.selectedEdgeZoneIds) && viewModel.selectedEdgeZoneIds == pairZoneIds {
                    NSLog("🔵 Deselecting edge zone pair: \(sourceZone.id) <-> \(targetZone.id)")
                    viewModel.selectedEdgeZoneIds = []
                } else {
                    NSLog("🔵 Selecting edge zone pair: \(sourceZone.id) <-> \(targetZone.id)")
                    viewModel.selectedEdgeZoneIds = pairZoneIds
                }
            }
        )
    }

    private func zoneEdgePoint(zone: EdgeZone, display: PhysicalDisplay, atStart: Bool) -> CGPoint {
        let scaledPos = display.scaledPosition
        let scaledSize = display.scaledSize
        let position = atStart ? zone.rangeStart : zone.rangeEnd

        // Apply drag offset if dragging
        let dragOffset = viewModel.dragOffsets[display.id] ?? .zero

        switch zone.edge {
        case .top:
            return CGPoint(x: scaledPos.x + dragOffset.width + scaledSize.width * position, y: scaledPos.y + dragOffset.height)
        case .bottom:
            return CGPoint(x: scaledPos.x + dragOffset.width + scaledSize.width * position, y: scaledPos.y + dragOffset.height + scaledSize.height)
        case .left:
            return CGPoint(x: scaledPos.x + dragOffset.width, y: scaledPos.y + dragOffset.height + scaledSize.height * position)
        case .right:
            return CGPoint(x: scaledPos.x + dragOffset.width + scaledSize.width, y: scaledPos.y + dragOffset.height + scaledSize.height * position)
        }
    }
}

// MARK: - Edge Zone Inset (for inside PhysicalDisplayRect)

/// Edge zone view that uses relative coordinates (follows parent display during drag)
struct EdgeZoneInset: View {
    let zone: EdgeZone
    let displaySize: CGSize
    @ObservedObject var viewModel: CalibrationViewModel

    var body: some View {
        let inset: CGFloat = 0  // Align exactly with border
        let thickness: CGFloat = 2  // Match border thickness
        let zoneRect = calculateZoneRect(edge: zone.edge, rangeStart: zone.rangeStart, rangeEnd: zone.rangeEnd, displaySize: displaySize, inset: inset, thickness: thickness)
        let isSelected = viewModel.selectedEdgeZoneIds.contains(zone.id)

        return ZStack(alignment: .topLeading) {
            // Edge zone line (visible, opaque to be visible on any background color)
            Rectangle()
                .fill(Color.cyan)
                .frame(width: zoneRect.width, height: zoneRect.height)
                .position(x: zoneRect.midX, y: zoneRect.midY)
                .allowsHitTesting(false)  // Hit testing handled by wider invisible layer

            // Slightly wider hit area for easier clicking (tap only, not drag)
            // Completely disable hit testing when handles are shown to avoid ANY interference
            Rectangle()
                .fill(Color.clear)
                .frame(width: max(zoneRect.width, 6), height: max(zoneRect.height, 6))
                .position(x: zoneRect.midX, y: zoneRect.midY)
                .contentShape(Rectangle())
                .allowsHitTesting(!isSelected)  // Only allow when NOT selected
                .onTapGesture {
                    let displayName = viewModel.physicalDisplays.first(where: { $0.identifier.stringRepresentation == zone.displayId })?.name ?? "Unknown"
                    NSLog("🟦 [EdgeZoneInset] tap: display=\(displayName) edge=\(zone.edge)")
                    // Select all edge zones on this edge of this display
                    let zonesOnThisEdge = viewModel.edgeZones.filter {
                        $0.displayId == zone.displayId && $0.edge == zone.edge
                    }
                    let zoneIds = Set(zonesOnThisEdge.map { $0.id })

                    // Toggle: if all zones on this edge are already selected (and ONLY these), deselect; otherwise clear and select all
                    if zoneIds.isSubset(of: viewModel.selectedEdgeZoneIds) && viewModel.selectedEdgeZoneIds == zoneIds {
                        NSLog("🔵 Deselecting all zones on edge \(zone.edge) of display \(zone.displayId)")
                        viewModel.selectedEdgeZoneIds = []
                    } else {
                        NSLog("🔵 Selecting all zones on edge \(zone.edge) of display \(zone.displayId)")
                        viewModel.selectedEdgeZoneIds = zoneIds
                    }
                }

            // Handles are now rendered separately at PhysicalDisplayRect level
        }
        .frame(width: displaySize.width, height: displaySize.height, alignment: .topLeading)
    }

    private func calculateZoneRect(edge: EdgeDirection, rangeStart: Double, rangeEnd: Double, displaySize: CGSize, inset: CGFloat, thickness: CGFloat) -> CGRect {
        // Calculate relative to display bounds (0,0 to displaySize.width, displaySize.height)
        // This will move with the parent ZStack's position transform

        switch edge {
        case .top:
            let startX = displaySize.width * rangeStart
            let endX = displaySize.width * rangeEnd
            // Top edge: align with top border
            return CGRect(x: startX, y: inset, width: endX - startX, height: thickness)
        case .bottom:
            let startX = displaySize.width * rangeStart
            let endX = displaySize.width * rangeEnd
            // Bottom edge: align with bottom border
            return CGRect(x: startX, y: displaySize.height - inset - thickness, width: endX - startX, height: thickness)
        case .left:
            let startY = displaySize.height * rangeStart
            let endY = displaySize.height * rangeEnd
            // Left edge: align with left border
            return CGRect(x: inset, y: startY, width: thickness, height: endY - startY)
        case .right:
            let startY = displaySize.height * rangeStart
            let endY = displaySize.height * rangeEnd
            // Right edge: align with right border
            return CGRect(x: displaySize.width - inset - thickness, y: startY, width: thickness, height: endY - startY)
        }
    }
}

// MARK: - Edge Zone Handle Overlay (Canvas level)

/// Handle at canvas level using NSView for precise hit testing
struct EdgeZoneHandleOverlay: NSViewRepresentable {
    let zone: EdgeZone
    let display: PhysicalDisplay
    let isStart: Bool
    @ObservedObject var viewModel: CalibrationViewModel
    let canvasHeight: CGFloat
    let canvasWidth: CGFloat

    func makeNSView(context: Context) -> NSView {
        // Create container view with full canvas size (but it won't intercept mouse events)
        let container = PassthroughNSView(frame: CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))

        // Create handle view
        let handleView = EdgeZoneHandleNSView()
        handleView.zone = zone
        handleView.display = display
        handleView.isStart = isStart
        handleView.viewModel = viewModel
        handleView.canvasHeight = canvasHeight

        // Position handle within container
        let handlePos = getHandleAbsolutePosition()
        let hitAreaSize: CGFloat = 20
        let nsViewY = canvasHeight - handlePos.y
        handleView.frame = CGRect(
            x: handlePos.x - hitAreaSize/2,
            y: nsViewY - hitAreaSize/2,
            width: hitAreaSize,
            height: hitAreaSize
        )

        container.addSubview(handleView)
        context.coordinator.handleView = handleView

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let handleView = context.coordinator.handleView else { return }

        handleView.zone = zone
        handleView.display = display
        handleView.isStart = isStart
        handleView.viewModel = viewModel
        handleView.canvasHeight = canvasHeight
        handleView.needsDisplay = true

        // Update position (convert SwiftUI Y to NSView Y)
        let handlePos = getHandleAbsolutePosition()
        let hitAreaSize: CGFloat = 20
        let nsViewY = canvasHeight - handlePos.y  // Flip Y coordinate
        handleView.frame = CGRect(
            x: handlePos.x - hitAreaSize/2,
            y: nsViewY - hitAreaSize/2,
            width: hitAreaSize,
            height: hitAreaSize
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        weak var handleView: EdgeZoneHandleNSView?
    }

    private func getHandleAbsolutePosition() -> CGPoint {
        let scaledPos = display.scaledPosition
        let scaledSize = display.scaledSize
        let position = isStart ? zone.rangeStart : zone.rangeEnd

        switch zone.edge {
        case .top:
            // Top edge: position 0=left, 1=right
            return CGPoint(x: scaledPos.x + scaledSize.width * position, y: scaledPos.y)
        case .bottom:
            // Bottom edge: position 0=left, 1=right
            return CGPoint(x: scaledPos.x + scaledSize.width * position, y: scaledPos.y + scaledSize.height)
        case .left:
            // Left edge: position 0=top, 1=bottom (SwiftUI Y increases downward)
            return CGPoint(x: scaledPos.x, y: scaledPos.y + scaledSize.height * position)
        case .right:
            // Right edge: position 0=top, 1=bottom (SwiftUI Y increases downward)
            return CGPoint(x: scaledPos.x + scaledSize.width, y: scaledPos.y + scaledSize.height * position)
        }
    }
}

/// Container view that only intercepts mouse events within its subviews' bounds
class PassthroughNSView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Check if point is within any subview's frame
        for subview in subviews.reversed() {
            if subview.frame.contains(point) {
                // Let the subview handle the hit test
                let pointInSubview = convert(point, to: subview)
                return subview.hitTest(pointInSubview)
            }
        }
        // If no subview contains this point, return nil to pass through
        return nil
    }
}

class EdgeZoneHandleNSView: NSView {
    var zone: EdgeZone?
    var display: PhysicalDisplay?
    var isStart: Bool = false
    weak var viewModel: CalibrationViewModel?
    var canvasHeight: CGFloat = 0

    private var isHovered = false
    private var isDragging = false
    private var dragStartValue: Double = 0
    private var dragStartLocation: CGPoint = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTrackingArea()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupTrackingArea() {
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Return self if point is within bounds, otherwise nil
        return bounds.contains(point) ? self : nil
    }

    override var acceptsFirstResponder: Bool {
        return true
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let zone = zone else { return }
        isDragging = true
        dragStartValue = isStart ? zone.rangeStart : zone.rangeEnd
        dragStartLocation = event.locationInWindow  // Use window coordinates directly
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let zone = zone, let display = display, let viewModel = viewModel else { return }

        let currentLocation = event.locationInWindow  // Use window coordinates directly
        let translation = CGSize(
            width: currentLocation.x - dragStartLocation.x,
            height: -(currentLocation.y - dragStartLocation.y)  // Flip Y for NSView coordinate system
        )

        let edgeLength: CGFloat
        let offset: CGFloat
        switch zone.edge {
        case .top, .bottom:
            edgeLength = display.scaledSize.width
            offset = translation.width
        case .left, .right:
            edgeLength = display.scaledSize.height
            offset = translation.height  // Y is already flipped above
        }

        let normalizedOffset = offset / edgeLength
        let newValue = max(0.0, min(1.0, dragStartValue + normalizedOffset))

        if let index = viewModel.edgeZones.firstIndex(where: { $0.id == zone.id }) {
            var updatedZone = viewModel.edgeZones[index]

            // Find other zones on the same display and edge
            let otherZones = viewModel.edgeZones.filter {
                $0.id != zone.id &&
                $0.displayId == zone.displayId &&
                $0.edge == zone.edge
            }

            if isStart {
                var clampedValue = newValue

                // Check for collision with other zones on the same edge first
                for otherZone in otherZones {
                    // Prevent entering or crossing another zone's range
                    if clampedValue >= otherZone.rangeStart && clampedValue <= otherZone.rangeEnd {
                        // If trying to move into another zone, stop at the boundary
                        if dragStartValue < otherZone.rangeStart {
                            clampedValue = otherZone.rangeStart
                        } else {
                            clampedValue = otherZone.rangeEnd
                        }
                    }
                }

                // Then apply own zone's end constraint (always enforce start <= end)
                if clampedValue > updatedZone.rangeEnd {
                    clampedValue = updatedZone.rangeEnd
                }

                updatedZone.rangeStart = clampedValue
            } else {
                var clampedValue = newValue

                // Check for collision with other zones on the same edge first
                for otherZone in otherZones {
                    // Prevent entering or crossing another zone's range
                    if clampedValue >= otherZone.rangeStart && clampedValue <= otherZone.rangeEnd {
                        // If trying to move into another zone, stop at the boundary
                        if dragStartValue > otherZone.rangeEnd {
                            clampedValue = otherZone.rangeEnd
                        } else {
                            clampedValue = otherZone.rangeStart
                        }
                    }
                }

                // Then apply own zone's start constraint (always enforce start <= end)
                if clampedValue < updatedZone.rangeStart {
                    clampedValue = updatedZone.rangeStart
                }

                updatedZone.rangeEnd = clampedValue
            }
            viewModel.edgeZones[index] = updatedZone
        }
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let zone = zone, let viewModel = viewModel else { return }

        // Determine if this side has a block zone
        let currentValue = isStart ? zone.rangeStart : zone.rangeEnd
        let isAtBoundary = currentValue == 0.0 || currentValue == 1.0

        let adjacentZones = viewModel.edgeZones.filter {
            $0.displayId == zone.displayId &&
            $0.edge == zone.edge &&
            $0.id != zone.id
        }

        let hasAdjacentZone = isStart
            ? adjacentZones.contains { $0.rangeEnd == zone.rangeStart }
            : adjacentZones.contains { $0.rangeStart == zone.rangeEnd }

        let isBlocked = !isAtBoundary && !hasAdjacentZone

        // Draw handle
        let handleSize: CGFloat = 8
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let handleRect = CGRect(
            x: center.x - handleSize/2,
            y: center.y - handleSize/2,
            width: handleSize,
            height: handleSize
        )

        let color: NSColor
        if isBlocked {
            color = NSColor.red.withAlphaComponent(0.7)
        } else if isHovered {
            color = NSColor.cyan
        } else {
            color = NSColor.cyan.withAlphaComponent(0.8)
        }

        color.setFill()
        NSColor.white.setStroke()

        let path = NSBezierPath(ovalIn: handleRect)
        path.lineWidth = 1.5
        path.fill()
        path.stroke()

        // Add shadow
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.set()
    }
}

// MARK: - Simple Edge Zone Handle

/// Draggable handle for adjusting edge zone boundaries (display-relative coordinates)
struct SimpleEdgeZoneHandle: View {
    let zone: EdgeZone
    let displaySize: CGSize
    let isStart: Bool
    @ObservedObject var viewModel: CalibrationViewModel
    let displayName: String

    @State private var isHovered = false
    @State private var initialValue: Double = 0

    var body: some View {
        let handleSize: CGFloat = 8
        let hitAreaSize: CGFloat = 20  // Larger hit area
        let handlePos = getHandlePositionInDisplay()

        // Determine if this side has a block zone
        let currentValue = isStart ? zone.rangeStart : zone.rangeEnd
        let isAtBoundary = currentValue == 0.0 || currentValue == 1.0

        let adjacentZones = viewModel.edgeZones.filter {
            $0.displayId == zone.displayId &&
            $0.edge == zone.edge &&
            $0.id != zone.id
        }

        let hasAdjacentZone = isStart
            ? adjacentZones.contains { $0.rangeEnd == zone.rangeStart }
            : adjacentZones.contains { $0.rangeStart == zone.rangeEnd }

        let isBlocked = !isAtBoundary && !hasAdjacentZone

        // Single small view positioned at the handle location
        // This prevents the handle from blocking the entire display rectangle
        return ZStack {
            // Invisible hit area
            Circle()
                .fill(Color.clear)
                .frame(width: hitAreaSize, height: hitAreaSize)
                .contentShape(Circle())

            // Visible handle
            Circle()
                .fill(isBlocked ? Color.red.opacity(0.7) : (isHovered ? Color.cyan : Color.cyan.opacity(0.8)))
                .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
                .frame(width: handleSize, height: handleSize)
                .shadow(radius: 2)
        }
        .frame(width: hitAreaSize, height: hitAreaSize)
        .position(x: handlePos.x, y: handlePos.y)
        .onHover { hovering in
            isHovered = hovering
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let offset = getOffsetAlongEdge(translation: value.translation)
                    updateZoneRange(offset: offset, isInitial: value.translation == .zero)
                }
        )
        .zIndex(100)  // Ensure handles are always on top
        .allowsHitTesting(true)
    }

    private func getHandlePositionInDisplay() -> CGPoint {
        let position = isStart ? zone.rangeStart : zone.rangeEnd

        switch zone.edge {
        case .top:
            return CGPoint(x: displaySize.width * position, y: 0)
        case .bottom:
            return CGPoint(x: displaySize.width * position, y: displaySize.height)
        case .left:
            return CGPoint(x: 0, y: displaySize.height * position)
        case .right:
            return CGPoint(x: displaySize.width, y: displaySize.height * position)
        }
    }

    private func getOffsetAlongEdge(translation: CGSize) -> CGFloat {
        switch zone.edge {
        case .top, .bottom:
            return translation.width
        case .left, .right:
            return translation.height
        }
    }

    private func updateZoneRange(offset: CGFloat, isInitial: Bool) {
        if isInitial {
            initialValue = isStart ? zone.rangeStart : zone.rangeEnd
            return
        }

        let edgeLength: CGFloat
        switch zone.edge {
        case .top, .bottom:
            edgeLength = displaySize.width
        case .left, .right:
            edgeLength = displaySize.height
        }

        let normalizedOffset = offset / edgeLength
        let newValue = max(0.0, min(1.0, initialValue + normalizedOffset))

        if let index = viewModel.edgeZones.firstIndex(where: { $0.id == zone.id }) {
            var updatedZone = viewModel.edgeZones[index]

            // Find other zones on the same display and edge
            let otherZones = viewModel.edgeZones.filter {
                $0.id != zone.id &&
                $0.displayId == zone.displayId &&
                $0.edge == zone.edge
            }

            if isStart {
                var clampedValue = newValue

                // Check for collision with other zones on the same edge first
                for otherZone in otherZones {
                    // Prevent entering or crossing another zone's range
                    if clampedValue >= otherZone.rangeStart && clampedValue <= otherZone.rangeEnd {
                        // If trying to move into another zone, stop at the boundary
                        if initialValue < otherZone.rangeStart {
                            clampedValue = otherZone.rangeStart
                        } else {
                            clampedValue = otherZone.rangeEnd
                        }
                    }
                }

                // Then apply own zone's end constraint (always enforce start <= end)
                if clampedValue > updatedZone.rangeEnd {
                    clampedValue = updatedZone.rangeEnd
                }

                updatedZone.rangeStart = clampedValue
            } else {
                var clampedValue = newValue

                // Check for collision with other zones on the same edge first
                for otherZone in otherZones {
                    // Prevent entering or crossing another zone's range
                    if clampedValue >= otherZone.rangeStart && clampedValue <= otherZone.rangeEnd {
                        // If trying to move into another zone, stop at the boundary
                        if initialValue > otherZone.rangeEnd {
                            clampedValue = otherZone.rangeEnd
                        } else {
                            clampedValue = otherZone.rangeStart
                        }
                    }
                }

                // Then apply own zone's start constraint (always enforce start <= end)
                if clampedValue < updatedZone.rangeStart {
                    clampedValue = updatedZone.rangeStart
                }

                updatedZone.rangeEnd = clampedValue
            }
            viewModel.edgeZones[index] = updatedZone
        }
    }
}

// MARK: - Block Zones (Border color lines for non-navigable areas)

/// Draws border color lines for block zones (areas outside edge zones on a display edge)
struct BlockZonesForEdge: View {
    let edge: EdgeDirection
    let zones: [EdgeZone]
    let displaySize: CGSize
    let borderColor: Color

    var body: some View {
        let thickness: CGFloat = 2
        let inset: CGFloat = 0

        // Get all zones on this edge, sorted by position
        let edgeZones = zones.filter { $0.edge == edge }.sorted { $0.rangeStart < $1.rangeStart }

        // If no edge zones on this edge, don't draw any block zones
        if edgeZones.isEmpty {
            return AnyView(EmptyView())
        }

        // Calculate block zones (gaps between edge zones and boundaries)
        var blockRanges: [(start: Double, end: Double)] = []

        // Check start to first zone
        if edgeZones[0].rangeStart > 0.0 {
            blockRanges.append((0.0, edgeZones[0].rangeStart))
        }

        // Check gaps between zones
        for i in 0..<(edgeZones.count - 1) {
            let currentEnd = edgeZones[i].rangeEnd
            let nextStart = edgeZones[i + 1].rangeStart
            if nextStart > currentEnd {
                blockRanges.append((currentEnd, nextStart))
            }
        }

        // Check last zone to end
        if let lastZone = edgeZones.last, lastZone.rangeEnd < 1.0 {
            blockRanges.append((lastZone.rangeEnd, 1.0))
        }

        return AnyView(
            ForEach(Array(blockRanges.enumerated()), id: \.offset) { _, range in
                let blockRect = calculateBlockRect(edge: edge, rangeStart: range.start, rangeEnd: range.end, displaySize: displaySize, inset: inset, thickness: thickness)

                Rectangle()
                    .fill(borderColor)
                    .frame(width: blockRect.width, height: blockRect.height)
                    .position(x: blockRect.midX, y: blockRect.midY)
                    .allowsHitTesting(false)
            }
        )
    }

    private func calculateBlockRect(edge: EdgeDirection, rangeStart: Double, rangeEnd: Double, displaySize: CGSize, inset: CGFloat, thickness: CGFloat) -> CGRect {
        switch edge {
        case .top:
            let startX = displaySize.width * rangeStart
            let endX = displaySize.width * rangeEnd
            return CGRect(x: startX, y: inset, width: endX - startX, height: thickness)
        case .bottom:
            let startX = displaySize.width * rangeStart
            let endX = displaySize.width * rangeEnd
            return CGRect(x: startX, y: displaySize.height - inset - thickness, width: endX - startX, height: thickness)
        case .left:
            let startY = displaySize.height * rangeStart
            let endY = displaySize.height * rangeEnd
            return CGRect(x: inset, y: startY, width: thickness, height: endY - startY)
        case .right:
            let startY = displaySize.height * rangeStart
            let endY = displaySize.height * rangeEnd
            return CGRect(x: displaySize.width - inset - thickness, y: startY, width: thickness, height: endY - startY)
        }
    }
}

#Preview {
    CalibrationView()
}
