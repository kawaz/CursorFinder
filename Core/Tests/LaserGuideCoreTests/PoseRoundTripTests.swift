// DisplayPose の toPhysical / toLogical の可逆性 (DR-0005 決定 2: 逆変換を最初から実装する)
//
// V3 では逆変換不在で WarpTo (物理→論理) が事実上使えなかった。ここで往復可逆性を仕様として固定する。
import XCTest
@testable import LaserGuideCore

final class PoseRoundTripTests: XCTestCase {

    /// 恒等 pose の toPhysical/toLogical は座標を保つ。pose = identity は「pose 未設定」の基準状態
    /// であり、他テストの baseline としても使う。
    func testIdentityPoseIsInvariant() {
        let p = LogicalPoint(x: 123.5, y: -42.75)
        let phys = DisplayPose.identity.toPhysical(p)
        XCTAssertEqual(phys.x, 123.5)
        XCTAssertEqual(phys.y, -42.75)
        let back = DisplayPose.identity.toLogical(phys)
        XCTAssertEqual(back.x, 123.5)
        XCTAssertEqual(back.y, -42.75)
    }

    /// translate + 非等方 scale (混合 DPI 想定、DR-0005 決定 3) を通した往復が epsilon 内で一致すること。
    /// V3 に欠けていた逆変換の仕様輪郭を固定する。
    func testAnisotropicScaleWithTranslateIsInvertible() {
        // 例: 4K 外部モニタ相当。x 方向 0.25 mm/px、y 方向 0.24 mm/px、論理原点は物理 (500, 300) mm に置く。
        let pose = DisplayPose(translate: PhysicalPoint(x: 500, y: 300), scaleX: 0.25, scaleY: 0.24)
        let samples = [
            LogicalPoint(x: 0, y: 0),
            LogicalPoint(x: 1920, y: 1080),
            LogicalPoint(x: -1000, y: 500),
            LogicalPoint(x: 3840.5, y: 2159.75),
        ]
        for p in samples {
            let phys = pose.toPhysical(p)
            let back = pose.toLogical(phys)
            XCTAssertEqual(back.x, p.x, accuracy: 1e-9, "toLogical(toPhysical(p)) should recover p.x")
            XCTAssertEqual(back.y, p.y, accuracy: 1e-9, "toLogical(toPhysical(p)) should recover p.y")
        }
    }

    /// 物理座標側から始めた場合の往復も可逆であること (対称性)。
    func testPhysicalToLogicalAndBackIsInvariant() {
        let pose = DisplayPose(translate: PhysicalPoint(x: -120, y: 40), scaleX: 0.5, scaleY: 0.5)
        let phys = PhysicalPoint(x: 800, y: 600)
        let logical = pose.toLogical(phys)
        let back = pose.toPhysical(logical)
        XCTAssertEqual(back.x, phys.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, phys.y, accuracy: 1e-9)
    }
}
