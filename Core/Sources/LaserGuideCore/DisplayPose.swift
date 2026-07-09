// DisplayPose (DR-0005 決定 2)
//
// 論理 (CG グローバル px, y-down) ↔ 物理 (mm) の 2D アフィン変換。
// - translate: 論理原点 (0,0) が物理空間で置かれる位置 (mm)、x/y 別
// - scaleX / scaleY: px→mm 係数、軸別に独立 (混合 DPI 対応、DR-0005 決定 3)
//
// physical.x = translate.x + logical.x * scaleX
// physical.y = translate.y + logical.y * scaleY
//
// 逆変換を初期から実装する (V3 で欠けていた点)。scale が 0 でない限り可逆。
// 3D pose (roll/pitch/yaw) は Phase 1 の対象外 (DR-0005 決定 2 末尾)。
import Foundation

public struct DisplayPose: Equatable, Hashable, Sendable {
    public var translate: PhysicalPoint
    public var scaleX: Double
    public var scaleY: Double

    public init(translate: PhysicalPoint, scaleX: Double, scaleY: Double) {
        // scale <= 0 は逆変換不能 (0) または鏡映反転 (負値、モニタ配置として想定外) を許してしまう。
        // ミラーリング表現は pose の責務外 (DR-0005) なので正値のみ受け付ける (m-4)。
        precondition(scaleX > 0 && scaleY > 0, "DisplayPose: scale は正の値である必要がある (0 は逆変換不能、負値は反転を意味してしまう)")
        self.translate = translate
        self.scaleX = scaleX
        self.scaleY = scaleY
    }

    /// 恒等 pose (translate=0, scale=1)。テストの baseline 用。
    public static let identity = DisplayPose(
        translate: PhysicalPoint(x: 0, y: 0), scaleX: 1, scaleY: 1
    )

    public func toPhysical(_ p: LogicalPoint) -> PhysicalPoint {
        PhysicalPoint(
            x: translate.x + p.x * scaleX,
            y: translate.y + p.y * scaleY
        )
    }

    public func toLogical(_ p: PhysicalPoint) -> LogicalPoint {
        LogicalPoint(
            x: (p.x - translate.x) / scaleX,
            y: (p.y - translate.y) / scaleY
        )
    }
}
