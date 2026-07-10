// キー設計 (DR-0007 決定 1, 2)
//
// - v3 の構成キーは hardwareId の sorted 結合のみ (resolution/backingScaleFactor は含めない)。
//   解像度スケーリングを変えるたびにキーが変わり、キャリブレーションが消える V2 の
//   DisplayFingerprint 方式を採用しない、という DR-0007 決定 1 をキー生成という形で固定する。
// - v1 は `LaserGuide.Calibration.config_<sorted identifiers>` (+ `.temporary` サフィックスの
//   プレビュー専用キー) を使っていた (CalibrationDataManager.swift 実物、
//   file: LaserGuide.v1.backup/Services/CalibrationDataManager.swift:10,31-38,50-51)。
//   v3 では `.temporary` プレビュー方式そのものを廃止する (DR-0007 決定 5) ので、v1 key
//   space からは「読み取って migration するか、捨てるか」の判定だけが必要になる。
import Foundation

public enum PersistenceKeyV3 {
    /// v3 の永続化 key prefix (DR-0007 決定 2)。
    public static let keyPrefix = "LaserGuide.v3.workspace."

    /// 現在接続中のモニタ集合 (hardwareId 列) から構成キーを作る。
    /// 順序に依存せず同一構成が同一キーになるよう、呼び出し側の順序を無視して毎回 sort する。
    public static func workspaceKey(hardwareIds: [String]) -> String {
        keyPrefix + hardwareIds.sorted().joined(separator: "_")
    }
}

/// v1 (配布中 v0.12.1) の key space の判定関数。migration 対象キーの発見と、
/// 移行後に読み捨てるべき `.temporary` キーの区別に使う (DR-0007 決定 3, 5)。
public enum PersistenceKeyV1 {
    /// v1 実装の calibration key prefix (CalibrationDataManager.swift:10 `calibrationKeyPrefix`)。
    public static let keyPrefix = "LaserGuide.Calibration."
    /// v1 のプレビュー専用 temporary サフィックス (CalibrationDataManager.swift:51)。
    public static let temporarySuffix = ".temporary"

    /// v1 の永続 (非 temporary) 設定キーか。migration reader が読みに行く対象。
    public static func isPersistentConfigKey(_ key: String) -> Bool {
        key.hasPrefix(keyPrefix) && !key.hasSuffix(temporarySuffix)
    }

    /// v1 のプレビュー専用 temporary キーか。DR-0007 決定 5: プレビューは永続化しない設計に
    /// 変わったため、migration 時は変換対象にせず読み捨てて削除する。
    public static func isTemporaryKey(_ key: String) -> Bool {
        key.hasPrefix(keyPrefix) && key.hasSuffix(temporarySuffix)
    }
}
