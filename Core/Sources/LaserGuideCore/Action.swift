// Action (DR-0004 の列挙に準拠)
//
// - mouseMoved: 高頻度経路の入力。deltaSign は符号のみ (DR-0006 決定 3)
// - displayConfigurationChanged: OS 側の物理配置変更。派生 tables 再構築のトリガー
// - eventTapDisabled: timeout/userInput (回復可能) と permissionRevoked (degrade) を区別する
// - calibration: キャリブレーション編集のサブアクション
// - settingsChanged: アプリ設定変更、永続化を伴う
// - focusedWindowChanged: フォーカスフラッシュ (DR-0011) の入力アダプタが投げる action。
//   フォーカス先ウィンドウの所属モニタ id と CG グローバル論理 frame (震源) を運ぶ。
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
    /// フォーカスフラッシュ (DR-0011): フォーカス先ウィンドウが確定したタイミングで入力アダプタが
    /// 発行する。震源は `windowFrame` (CG グローバル論理 frame)。同一ウィンドウへの連続発火でも
    /// 都度発行してよい (reducer 側で世代カウンタが単調増加し、直近の発火が最新として上書きされる)。
    case focusedWindowChanged(displayId: String, windowFrame: LogicalRect)
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
