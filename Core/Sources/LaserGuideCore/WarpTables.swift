// WarpTables (DR-0004 決定: 派生テーブルは構成変更時のみ再構築する derived state)
//
// - displays: 現在の物理接続構成 (id + logicalBounds + pose)
// - userSegments: ユーザ編集セグメント (永続化対象、DR-0006)
// - osSegments: displays から自動導出される OS 隣接セグメント (derived)
//
// 高頻度経路 (毎イベント) では displays を線形走査で「所属モニタ」を求めるだけ。テーブル自体の
// 構築は displayConfigurationChanged / キャリブレーション確定時のみ発生する (Phase 1 は naive
// 走査。Phase 2 で検索構造を最適化する余地を残す)。
import Foundation

public struct WarpTables: Equatable, Hashable, Sendable {
    public let displays: [Display]
    public let userSegments: [PassSegment]
    public let osSegments: [PassSegment]

    public init(displays: [Display], userSegments: [PassSegment]) {
        self.displays = displays
        self.userSegments = userSegments
        self.osSegments = Adjacency.detectOSPassSegments(displays)
    }

    /// 論理点を含むモニタ id を返す (半開区間、境界は minX/minY 側に属する。BX 判定は別関数)
    public func displayId(containing p: LogicalPoint) -> String? {
        for d in displays where d.logicalBounds.containsHalfOpen(p) {
            return d.id
        }
        return nil
    }

    public func display(_ id: String) -> Display? {
        displays.first(where: { $0.id == id })
    }

    public func osSegment(id: String) -> PassSegment? { osSegments.first(where: { $0.id == id }) }
    public func userSegment(id: String) -> PassSegment? { userSegments.first(where: { $0.id == id }) }
}
