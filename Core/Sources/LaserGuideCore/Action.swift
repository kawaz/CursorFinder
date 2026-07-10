// Action (DR-0004 の列挙に準拠)
//
// - mouseMoved: 高頻度経路の入力。deltaSign は符号のみ (DR-0006 決定 3)
// - displayConfigurationChanged: OS 側の物理配置変更。派生 tables 再構築のトリガー
// - eventTapDisabled: timeout/userInput (回復可能) と permissionRevoked (degrade) を区別する
// - calibration: キャリブレーション編集のサブアクション
// - settingsChanged: アプリ設定変更、永続化を伴う
// - focusedDisplayChanged: フォーカスフラッシュ (DR-0009) の入力アダプタが投げる action。
//   Phase A ではフォーカス先の所属モニタ id のみ運ぶ。Phase B ではウィンドウ枠の物理領域を
//   運ぶよう拡張予定 (payload に AX 由来の LogicalRect を追加する形になる)。
//
// 「ワープ完了」を表す専用 action は用意していない。DR-0004 はワープ effect が
// 「tap callback 内で同期実行され、結果が callback の返り値に反映される」契約なので、
// ワープ後の履歴リセットは mouseMoved の reduce 内で完結させる (このファイルの Store.swift
// 参照)。非同期の完了通知アクションを別途起こす必要がない。
import Foundation

public enum Action: Equatable, Sendable {
    case mouseMoved(location: LogicalPoint, deltaSign: DeltaSign)
    case displayConfigurationChanged([DisplaySnapshot])
    case eventTapDisabled(reason: TapDisableReason)
    case calibration(CalibrationAction)
    case settingsChanged(AppConfiguration)
    /// フォーカスフラッシュ (DR-0009 Phase A): アプリ切替時にフォーカス先の所属モニタが確定した
    /// タイミングで入力アダプタが発行する。同一モニタへの連続切替でも都度発行してよい
    /// (reducer 側で世代カウンタが単調増加し、直近の発火が最新として上書きされる)。
    ///
    /// Phase B 拡張余地: `windowFrame: LogicalRect?` を追加し、ウィンドウ枠のアウトライン強調を
    /// reducer/描画に流す想定 (payload 拡張はここのシグネチャ変更のみで済むよう case を薄く保つ)。
    case focusedDisplayChanged(displayId: String)
}

/// キャリブレーション編集のサブアクション。dragMove は候補 pose の更新のみ (テーブル再構築なし)、
/// preview で明示的にプレビュー用テーブルを再構築する (DR-0004 の「特定 action でのみ派生
/// テーブルを再構築する」規律をキャリブレーション編集にも適用する)。
public enum CalibrationAction: Equatable, Sendable {
    case dragStart(displayId: String)
    case dragMove(displayId: String, candidatePose: DisplayPose)
    case dragEnd
    case preview
    case commit
    case cancel
}
