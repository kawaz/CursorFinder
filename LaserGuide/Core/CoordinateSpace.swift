// CoordinateSpace.swift
import Foundation

/// 座標空間（2種類のみ、SpriteKitと統一）
enum CoordinateSpace {
    case logical    // macOS論理座標（左下原点、Y上向き）
    case physical   // 物理座標mm（左下原点、Y上向き、正規化済み）
}

/// 座標変換コンテキスト
struct CoordinateConversionContext {
    /// 論理座標系の情報
    let logicalBounds: CGRect  // 全ディスプレイの論理座標範囲

    /// 物理座標系の情報
    let physicalBounds: PhysicalBounds  // 全ディスプレイの物理座標範囲

    /// ディスプレイのマッピング
    let displays: [DisplayMapping]

    struct PhysicalBounds {
        let minX: Double
        let maxX: Double
        let minY: Double
        let maxY: Double

        var width: Double { maxX - minX }
        var height: Double { maxY - minY }
    }

    struct DisplayMapping {
        let logicalFrame: CGRect
        let physicalPosition: Point2D
        let physicalSize: Size2D
    }
}

extension CoordinateSpace {
    /// 座標変換
    /// - Parameters:
    ///   - point: 変換元の座標
    ///   - from: 変換元の座標空間
    ///   - to: 変換先の座標空間
    ///   - context: 変換コンテキスト
    /// - Returns: 変換後の座標
    static func convert(
        _ point: CGPoint,
        from: CoordinateSpace,
        to: CoordinateSpace,
        context: CoordinateConversionContext
    ) -> CGPoint {
        // 同じ座標空間の場合はそのまま返す
        if from == to {
            return point
        }

        switch (from, to) {
        case (.logical, .physical):
            return logicalToPhysical(point, context: context)
        case (.physical, .logical):
            return physicalToLogical(point, context: context)
        }
    }

    /// 論理座標 → 物理座標
    private static func logicalToPhysical(
        _ point: CGPoint,
        context: CoordinateConversionContext
    ) -> CGPoint {
        // どのディスプレイに含まれるか判定
        guard let display = context.displays.first(where: {
            $0.logicalFrame.contains(point)
        }) else {
            // どのディスプレイにも含まれない場合は最も近いディスプレイを使用
            let nearest = context.displays.min(by: { d1, d2 in
                let dist1 = distanceToRect(point, rect: d1.logicalFrame)
                let dist2 = distanceToRect(point, rect: d2.logicalFrame)
                return dist1 < dist2
            })
            guard let display = nearest else {
                return .zero
            }
            return convertWithinDisplay(point, display: display, toPhysical: true)
        }

        return convertWithinDisplay(point, display: display, toPhysical: true)
    }

    /// 物理座標 → 論理座標
    private static func physicalToLogical(
        _ point: CGPoint,
        context: CoordinateConversionContext
    ) -> CGPoint {
        let physicalPoint = Point2D(point)

        // どのディスプレイに含まれるか判定
        guard let display = context.displays.first(where: { display in
            let minX = display.physicalPosition.x
            let maxX = display.physicalPosition.x + display.physicalSize.width
            let minY = display.physicalPosition.y
            let maxY = display.physicalPosition.y + display.physicalSize.height

            return physicalPoint.x >= minX && physicalPoint.x < maxX &&
                   physicalPoint.y >= minY && physicalPoint.y < maxY
        }) else {
            // どのディスプレイにも含まれない場合は最も近いディスプレイを使用
            let nearest = context.displays.min(by: { d1, d2 in
                let center1 = Point2D(
                    x: d1.physicalPosition.x + d1.physicalSize.width / 2,
                    y: d1.physicalPosition.y + d1.physicalSize.height / 2
                )
                let center2 = Point2D(
                    x: d2.physicalPosition.x + d2.physicalSize.width / 2,
                    y: d2.physicalPosition.y + d2.physicalSize.height / 2
                )
                return physicalPoint.distance(to: center1) < physicalPoint.distance(to: center2)
            })
            guard let display = nearest else {
                return .zero
            }
            return convertWithinDisplay(point, display: display, toPhysical: false)
        }

        return convertWithinDisplay(point, display: display, toPhysical: false)
    }

    /// ディスプレイ内での座標変換
    private static func convertWithinDisplay(
        _ point: CGPoint,
        display: CoordinateConversionContext.DisplayMapping,
        toPhysical: Bool
    ) -> CGPoint {
        if toPhysical {
            // 論理 → 物理
            // 1. ディスプレイ内の相対位置（0.0〜1.0）
            let relativeX = (point.x - display.logicalFrame.minX) / display.logicalFrame.width
            let relativeY = (point.y - display.logicalFrame.minY) / display.logicalFrame.height

            // 2. 物理座標に変換
            let physicalX = display.physicalPosition.x + relativeX * display.physicalSize.width
            let physicalY = display.physicalPosition.y + relativeY * display.physicalSize.height

            return CGPoint(x: physicalX, y: physicalY)
        } else {
            // 物理 → 論理
            // 1. ディスプレイ内の相対位置（0.0〜1.0）
            let relativeX = (point.x - display.physicalPosition.x) / display.physicalSize.width
            let relativeY = (point.y - display.physicalPosition.y) / display.physicalSize.height

            // 2. 論理座標に変換
            let logicalX = display.logicalFrame.minX + relativeX * display.logicalFrame.width
            let logicalY = display.logicalFrame.minY + relativeY * display.logicalFrame.height

            return CGPoint(x: logicalX, y: logicalY)
        }
    }

    /// 点から矩形までの距離
    private static func distanceToRect(_ point: CGPoint, rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, point.x - rect.maxX, 0)
        let dy = max(rect.minY - point.y, point.y - rect.maxY, 0)
        return sqrt(dx * dx + dy * dy)
    }
}
