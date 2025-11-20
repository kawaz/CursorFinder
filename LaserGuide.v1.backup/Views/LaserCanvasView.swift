// LaserCanvasView.swift
import SwiftUI
import simd

struct LaserCanvasView: View {
    @ObservedObject var viewModel: LaserViewModel
    private let screen: NSScreen
    private let screenBounds: CGRect
    private let screenSize: CGSize
    private let corners: [SIMD2<Float>]
    private let displayID: CGDirectDisplayID

    private enum Constants {
        static let cornerWidth: CGFloat = 8.0
        static let targetWidth: CGFloat = 0.5
        static let indicatorOffset: CGFloat = 30.0
        static let indicatorFontSize: CGFloat = 16.0
        static let maxPercentage: Double = 999.0
        static let minimumDistance: CGFloat = 1.0
    }

    init(viewModel: LaserViewModel, screen: NSScreen) {
        self.viewModel = viewModel
        self.screen = screen
        self.screenBounds = screen.frame
        self.screenSize = screen.frame.size

        // Get display ID
        let deviceDescription = screen.deviceDescription
        self.displayID = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID

        // 事前計算されたコーナー座標
        self.corners = [
            SIMD2(0, 0),
            SIMD2(Float(screenSize.width), 0),
            SIMD2(0, Float(screenSize.height)),
            SIMD2(Float(screenSize.width), Float(screenSize.height))
        ]
    }

    var body: some View {
        Canvas { context, size in
            // グラデーション事前作成
            let gradient = Gradient(stops: Config.Visual.gradientStops)

            // Physical calibration を使用するか判定
            if viewModel.usePhysicalLayout,
               let config = viewModel.physicalConfiguration,
               let mousePhysical = globalToPhysical(viewModel.currentMouseLocation, config: config) {
                // 物理座標系で描画
                drawAllLasersWithPhysical(
                    context: context,
                    mousePhysical: mousePhysical,
                    config: config,
                    gradient: gradient,
                    size: size
                )
            } else {
                // 論理座標系で描画（従来通り）
                let targetPoint = convertToLocalCoordinates(viewModel.currentMouseLocation)
                let targetSIMD = SIMD2<Float>(Float(targetPoint.x), Float(targetPoint.y))

                drawAllLasers(
                    context: context,
                    target: targetPoint,
                    targetSIMD: targetSIMD,
                    gradient: gradient
                )

                // 画面外の場合のみインジケータ描画
                if isOffScreen(targetPoint, size: size) {
                    drawDistanceIndicators(
                        context: context,
                        target: targetPoint,
                        targetSIMD: targetSIMD,
                        size: size
                    )
                }
            }
        }
        .drawingGroup(opaque: false, colorMode: .nonLinear) // Metal最適化
    }

    @inline(__always)
    private func convertToLocalCoordinates(_ globalLocation: NSPoint) -> CGPoint {
        // Fallback to logical coordinates (used when no physical calibration)
        let localX = globalLocation.x - screenBounds.minX
        let localY = globalLocation.y - screenBounds.minY
        let convertedY = screenSize.height - localY
        return CGPoint(x: localX, y: convertedY)
    }

    /// Check if a point is contained in a rectangle using half-open interval semantics.
    ///
    /// This uses [minX, maxX) × [minY, maxY) instead of CGRect.contains() which uses closed intervals.
    /// This is critical for multi-display setups where adjacent displays share boundary coordinates.
    ///
    /// **Why not use CGRect.contains()?**
    /// CGRect.contains() uses closed interval [minX, maxX] × [minY, maxY], which causes boundary
    /// points to belong to multiple displays. For example, if Display A ends at x=1000 and Display B
    /// starts at x=1000, point (1000, y) would match BOTH displays, causing incorrect laser rendering.
    ///
    /// Half-open intervals ensure each point belongs to exactly one display, preventing this ambiguity.
    ///
    /// - Parameters:
    ///   - point: The point to test
    ///   - rect: The rectangle to test against
    /// - Returns: True if point is in [rect.minX, rect.maxX) × [rect.minY, rect.maxY)
    @inline(__always)
    private func containsPointHalfOpen(_ point: CGPoint, in rect: CGRect) -> Bool {
        return point.x >= rect.minX && point.x < rect.maxX &&
               point.y >= rect.minY && point.y < rect.maxY
    }

    /// Convert global mouse location to physical coordinates (mm)
    private func globalToPhysical(_ globalLocation: NSPoint, config: DisplayConfiguration) -> CGPoint? {
        // Find which display the mouse is on using half-open interval containment
        let allScreens = NSScreen.screens
        let mouseScreen = allScreens.first(where: { screen in
            containsPointHalfOpen(globalLocation, in: screen.frame)
        }) ?? allScreens.min(by: { screen1, screen2 in
            // Fallback: If point is exactly on maxX or maxY boundary, choose nearest display
            let dist1 = hypot(globalLocation.x - screen1.frame.midX, globalLocation.y - screen1.frame.midY)
            let dist2 = hypot(globalLocation.x - screen2.frame.midX, globalLocation.y - screen2.frame.midY)
            return dist1 < dist2
        })

        guard let mouseScreen = mouseScreen else {
            return nil
        }

        let mouseScreenDesc = mouseScreen.deviceDescription
        let mouseDisplayID = mouseScreenDesc[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
        let mouseIdentifier = DisplayIdentifier(displayID: mouseDisplayID)

        guard let mouseLayout = config.displays.first(where: { $0.identifier == mouseIdentifier }) else {
            return nil
        }

        // Mouse position relative to its screen (logical coordinates)
        let mouseLocalX = globalLocation.x - mouseScreen.frame.minX
        let mouseLocalY = globalLocation.y - mouseScreen.frame.minY

        // Convert to physical coordinates (mm)
        let mouseScreenSize = mouseScreen.frame.size
        let physicalX = mouseLayout.position.x + (mouseLocalX / mouseScreenSize.width) * mouseLayout.size.width
        let physicalY = mouseLayout.position.y + (mouseLocalY / mouseScreenSize.height) * mouseLayout.size.height

        return CGPoint(x: physicalX, y: physicalY)
    }

    /// Convert physical coordinates (mm) to local screen coordinates (pixels)
    private func physicalToLocal(_ physicalPoint: CGPoint, currentLayout: PhysicalDisplayLayout) -> CGPoint {
        // Relative physical position
        let relativeX = physicalPoint.x - currentLayout.position.x
        let relativeY = physicalPoint.y - currentLayout.position.y

        // Convert from mm to pixels
        let localX = (relativeX / currentLayout.size.width) * screenSize.width
        let localY = (relativeY / currentLayout.size.height) * screenSize.height

        // Convert Y coordinate (SwiftUI canvas uses top-left origin)
        let convertedY = screenSize.height - localY

        return CGPoint(x: localX, y: convertedY)
    }

    @inline(__always)
    private func isOffScreen(_ point: CGPoint, size: CGSize) -> Bool {
        point.x < 0 || point.x > size.width ||
        point.y < 0 || point.y > size.height
    }

    private func drawAllLasersWithPhysical(
        context: GraphicsContext,
        mousePhysical: CGPoint,
        config: DisplayConfiguration,
        gradient: Gradient,
        size: CGSize
    ) {
        // Get current display's physical layout
        let currentIdentifier = DisplayIdentifier(displayID: displayID)
        guard let currentLayout = config.displays.first(where: { $0.identifier == currentIdentifier }) else {
            return
        }

        // Calculate physical corners of current display (in mm)
        let physicalCorners = [
            CGPoint(x: currentLayout.position.x, y: currentLayout.position.y),  // bottom-left
            CGPoint(x: currentLayout.position.x + currentLayout.size.width, y: currentLayout.position.y),  // bottom-right
            CGPoint(x: currentLayout.position.x, y: currentLayout.position.y + currentLayout.size.height),  // top-left
            CGPoint(x: currentLayout.position.x + currentLayout.size.width, y: currentLayout.position.y + currentLayout.size.height)  // top-right
        ]

        // Draw laser from each physical corner to mouse physical position
        for physicalCorner in physicalCorners {
            // Convert to local coordinates
            let cornerLocal = physicalToLocal(physicalCorner, currentLayout: currentLayout)
            let targetLocal = physicalToLocal(mousePhysical, currentLayout: currentLayout)

            let cornerSIMD = SIMD2<Float>(Float(cornerLocal.x), Float(cornerLocal.y))
            let targetSIMD = SIMD2<Float>(Float(targetLocal.x), Float(targetLocal.y))

            let delta = targetSIMD - cornerSIMD
            let distance = length(delta)

            // 最小距離チェック
            guard distance > Float(Constants.minimumDistance) else { continue }

            // パス作成
            let path = createOptimizedLaserPath(
                from: cornerSIMD,
                to: targetSIMD,
                delta: delta,
                distance: distance
            )

            // グラデーション描画
            context.fill(
                path,
                with: .linearGradient(
                    gradient,
                    startPoint: cornerLocal,
                    endPoint: targetLocal
                )
            )
        }

        // TODO: Implement distance indicators for physical coordinates if needed
    }

    private func drawAllLasers(
        context: GraphicsContext,
        target: CGPoint,
        targetSIMD: SIMD2<Float>,
        gradient: Gradient
    ) {
        for corner in corners {
            let delta = targetSIMD - corner
            let distance = length(delta)

            // 最小距離チェック
            guard distance > Float(Constants.minimumDistance) else { continue }

            // パス作成（SIMD最適化）
            let path = createOptimizedLaserPath(
                from: corner,
                to: targetSIMD,
                delta: delta,
                distance: distance
            )

            // グラデーション描画
            context.fill(
                path,
                with: .linearGradient(
                    gradient,
                    startPoint: CGPoint(x: CGFloat(corner.x), y: CGFloat(corner.y)),
                    endPoint: target
                )
            )
        }
    }

    @inline(__always)
    private func createOptimizedLaserPath(
        from corner: SIMD2<Float>,
        to target: SIMD2<Float>,
        delta: SIMD2<Float>,
        distance: Float
    ) -> Path {
        Path { path in
            // 正規化された垂直ベクトル
            let normalized = delta / distance
            let perpendicular = SIMD2<Float>(-normalized.y, normalized.x)

            // 幅の計算
            let cornerWidth = Float(Constants.cornerWidth)
            let targetWidth = Float(Constants.targetWidth)

            // 台形の頂点計算（SIMD演算）
            let c1 = corner + perpendicular * cornerWidth
            let c2 = corner - perpendicular * cornerWidth
            let t1 = target + perpendicular * targetWidth
            let t2 = target - perpendicular * targetWidth

            // パス構築
            path.move(to: CGPoint(x: CGFloat(c1.x), y: CGFloat(c1.y)))
            path.addLine(to: CGPoint(x: CGFloat(t1.x), y: CGFloat(t1.y)))
            path.addLine(to: CGPoint(x: CGFloat(t2.x), y: CGFloat(t2.y)))
            path.addLine(to: CGPoint(x: CGFloat(c2.x), y: CGFloat(c2.y)))
            path.closeSubpath()
        }
    }

    private func drawDistanceIndicators(
        context: GraphicsContext,
        target: CGPoint,
        targetSIMD: SIMD2<Float>,
        size: CGSize
    ) {
        let indicators = calculateIndicators(
            target: target,
            targetSIMD: targetSIMD,
            size: size
        )

        for indicator in indicators {
            // Shadow効果付きテキスト描画
            let text = context.resolve(
                Text("\(Int(indicator.percentage))%")
                    .font(.system(
                        size: Constants.indicatorFontSize,
                        weight: .bold,
                        design: .monospaced
                    ))
                    .foregroundColor(.white)
            )

            // 影を追加
            context.drawLayer { ctx in
                // 黒い影
                ctx.opacity = 0.5
                ctx.draw(text, at: CGPoint(
                    x: indicator.position.x + 1,
                    y: indicator.position.y + 1
                ))
            }

            // 本体のテキスト
            context.draw(text, at: indicator.position)
        }
    }

    private func calculateIndicators(
        target: CGPoint,
        targetSIMD: SIMD2<Float>,
        size: CGSize
    ) -> [DistanceIndicator] {
        var indicators: [DistanceIndicator] = []

        for corner in corners {
            if let intersection = calculateScreenEdgeIntersection(
                from: corner,
                to: targetSIMD,
                screenSize: size
            ) {
                // 距離計算
                let visibleDistance = length(intersection - corner)  // 画面内の距離
                let totalDistance = length(targetSIMD - corner)  // 全体の距離

                // 画面内の距離 ÷ 全体の距離
                let percentage = Double(visibleDistance / totalDistance) * 100

                // テキスト位置計算
                let textPosition = calculateTextPosition(
                    intersection: CGPoint(x: CGFloat(intersection.x), y: CGFloat(intersection.y)),
                    size: size
                )

                indicators.append(DistanceIndicator(
                    corner: CGPoint(x: CGFloat(corner.x), y: CGFloat(corner.y)),
                    position: textPosition,
                    percentage: min(percentage, Constants.maxPercentage)
                ))
            }
        }

        return indicators
    }

    @inline(__always)
    private func calculateScreenEdgeIntersection(
        from: SIMD2<Float>,
        to: SIMD2<Float>,
        screenSize: CGSize
    ) -> SIMD2<Float>? {
        let delta = to - from

        // 移動なしの場合
        if length_squared(delta) < 0.001 { return nil }

        var tMin: Float = 0
        var tMax: Float = 1

        let screenWidth = Float(screenSize.width)
        let screenHeight = Float(screenSize.height)

        // X軸の交差チェック
        if delta.x != 0 {
            let t1 = (0 - from.x) / delta.x
            let t2 = (screenWidth - from.x) / delta.x

            tMin = max(tMin, min(t1, t2))
            tMax = min(tMax, max(t1, t2))
        }

        // Y軸の交差チェック
        if delta.y != 0 {
            let t1 = (0 - from.y) / delta.y
            let t2 = (screenHeight - from.y) / delta.y

            tMin = max(tMin, min(t1, t2))
            tMax = min(tMax, max(t1, t2))
        }

        // 交差なし
        if tMin > tMax { return nil }

        // 交点を返す
        if tMax >= 0 && tMax <= 1 {
            return from + delta * tMax
        }

        return nil
    }

    @inline(__always)
    private func calculateTextPosition(intersection: CGPoint, size: CGSize) -> CGPoint {
        var position = intersection
        let offset = Constants.indicatorOffset

        // エッジからオフセット
        if intersection.x <= 0 {
            position.x = offset
        } else if intersection.x >= size.width {
            position.x = size.width - offset
        }

        if intersection.y <= 0 {
            position.y = offset
        } else if intersection.y >= size.height {
            position.y = size.height - offset
        }

        return position
    }

    struct DistanceIndicator {
        let corner: CGPoint
        let position: CGPoint
        let percentage: Double
    }
}
