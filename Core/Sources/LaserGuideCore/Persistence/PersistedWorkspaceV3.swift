// PersistedWorkspaceV3 (DR-0007 決定 2, 6, 7)
//
// - version フィールドを持ち、将来の migration を一方向の変換関数として書けるようにする
//   (決定 2)。未知の version を読んだ場合にクラッシュせず「無視する」前方互換を提供する
//   (下記 decodeTolerantly を参照)。
// - モニタの同一性は hardwareId のみで判定する (決定 1)。resolution/backingScaleFactor は
//   スキーマにもキーにも含めない。
// - pose は DisplayPose をそのまま (translate mm + scaleX/scaleY) 保存する。scaleX/scaleY は
//   本来「現在の解像度と physical size から都度導出する」値 (DR-0005 決定 2) だが、
//   キャリブレーションによる補正を経た最終値は state.displays 上の pose に一体化されて
//   保持されている (Core に「補正量」だけを分離するフィールドが無い、AppState.swift 参照)。
//   よってここでは pose 全体を hardwareId 単位のスナップショットとして保存し、解像度が
//   変わった場合の scale 再導出は reconcile ではなく App 側 (displayConfigurationChanged の
//   構築元) の責務とする。
// - userSegments は hardwareId (= displayId) 単位で保持し、reconcile 時に現構成へ再マッピング
//   する (決定 7)。osPassSegments は保存しない (構成のたびに Adjacency.detectOSPassSegments で
//   再生成される derived data、WarpTables.swift 参照)。
import Foundation

public struct PersistedWorkspaceV3: Equatable, Sendable {
    /// 現行スキーマの version 番号。新規保存は常にこの値を書く。
    public static let currentVersion = 3

    public var version: Int
    public var displays: [PersistedDisplayV3]

    public init(version: Int = PersistedWorkspaceV3.currentVersion, displays: [PersistedDisplayV3]) {
        self.version = version
        self.displays = displays
    }
}

/// hardwareId 単位の 1 モニタ分の永続データ。
public struct PersistedDisplayV3: Equatable, Sendable {
    public var hardwareId: String
    public var pose: DisplayPose
    /// このモニタを起点とする userSegments (displayId == hardwareId のもの)。
    public var userSegments: [PassSegment]

    public init(hardwareId: String, pose: DisplayPose, userSegments: [PassSegment]) {
        self.hardwareId = hardwareId
        self.pose = pose
        self.userSegments = userSegments
    }
}

extension PersistedWorkspaceV3: Codable {}
extension PersistedDisplayV3: Codable {}

extension PersistedWorkspaceV3 {
    /// JSON エンコード (UserDefaults に書き込む Data を作る)。
    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// version を許容範囲外に見つけても throw せず nil を返す前方互換デコード
    /// (DR-0007 「未知 version フィールドを無視する」要求)。フィールド追加のみの将来 version
    /// (currentVersion 未満は許容しない、currentVersion を超える version は「まだこのビルドが
    /// 知らない新しい保存データ」として無視する = 古いビルドへダウングレードしても
    /// クラッシュせず、単に未対応データとして migration/reconcile 側が空扱いできる)。
    ///
    /// 追加フィールドを持つ将来 version の JSON でも、Codable の未知キー無視という既定動作により
    /// decode 自体は成功する。version 番号だけで「このビルドが解釈可能な形か」を判定する。
    public static func decodeTolerantly(_ data: Data) -> PersistedWorkspaceV3? {
        guard let decoded = try? JSONDecoder().decode(PersistedWorkspaceV3.self, from: data) else {
            return nil
        }
        guard decoded.version <= currentVersion else {
            // 未来の version: このビルドはまだ意味を知らないので無視する (クラッシュしない)。
            return nil
        }
        return decoded
    }
}
