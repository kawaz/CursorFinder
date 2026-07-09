# DR-0004: 単方向データフロー — 手組み Elm-style (Action / 純関数 reducer / Effect 分離)

## 背景

v1 (配布中) は状態が最低 4 か所 (UserDefaults / 複数 ViewModel の @Published / NotificationCenter 4 通知 / SwiftUI @State) に散在し、`isDragging` の 3 か所別実装、`showingOriginalZones` bool + 派生 2 変数、`.temporary` サフィックスによる二重保存など、真の source of truth が不明な構造だった (2026-07-09 偵察レポート §1.1)。作者の要求は「全アクションを形式化し、リデューサーで処理をルーティングする設計」。

## 決定

**フレームワーク非依存の手組み Elm-style を採用する。**

```swift
// 中核の形 (概念)
enum Action {
  case mouseMoved(location: LogicalPoint, deltaSign: (dx: Int, dy: Int))  // delta は符号のみ契約 (DR-0006)
  case displayConfigurationChanged([DisplaySnapshot])
  case eventTapDisabled(reason: TapDisableReason)     // timeout / userInput / 権限失効
  case calibration(CalibrationAction)                 // drag start/move/end, preview 適用...
  case settingsChanged(AppConfiguration)
  ...
}
struct AppState { /* 唯一の source of truth */ }
enum Effect { case rewriteEventLocation(LogicalPoint), persist(WorkspaceConfiguration), reenableTap, ... }
func reduce(_ state: AppState, _ action: Action) -> (AppState, [Effect])  // 純関数
```

- **store は 1 個、main run loop に一元化、reduce は同期実行**。イベントタップも main run loop に載せる (v2 の実装実績と同じ) ため、排他制御なしで一貫する
- **Effect インタープリタ**が副作用 (イベント座標書き換え、UserDefaults 永続化、オーバーレイウィンドウ管理、tap 再有効化) を実行する。reducer 内での副作用は禁止
- **描画は state の購読**: レーザー描画ビューは action を個別に見ず、state スナップショットを描く
- **キャリブレーションのリアルタイムプレビュー**は「候補 transform を適用した派生 state を同じ reducer/selector で評価して描く」。`.temporary` キー方式 (v1) は廃止
- Action ログをリングバッファで保持し、デバッグ時に再生 (replay) できるようにする。テストは「action 列 → state 列」の形で書く

## 高頻度経路のトリガーモデル (作者提案 2026-07-09、採用)

mouseMoved は 60〜125Hz+ で流れるが、**ワープ計算が必要なのは遷移シグナルの時だけ**という 2 段構造にする:

1. **fast path (毎イベント)**: `(マウス座標, 所属モニタ id)` を 2 世代シフト保存し、以下の 3 分類のみ行う
   - **interior**: 同一モニタ内の移動 → 追加処理なし (レーザー描画は state 購読側が拾う)
   - **PX**: 所属モニタ id が変わった → ネイティブ通過が起きた → PP/PB 判定 (slow path) を起動
   - **BX**: エッジ上にクランプされた (エッジ上 + delta 符号が外向き、DR-0006) → ネイティブブロックに当たった → BP/BB 判定 (slow path) を起動。BX は連続発火する前提で、BX イベント列が BP 速度推定器への入力になる
2. **slow path (遷移時のみ)**: セグメント検索・rate 写像・ワープ先計算。頻度が低いので予算が緩い
3. **派生テーブルの事前計算**: モニタごとの logical↔physical affine 係数・セグメント検索構造は `displayConfigurationChanged` / キャリブレーション確定の action でのみ再構築する derived state とする。毎イベントの処理は係数適用と包含チェックのみで、reducer 内での確保・エンコード・IO は禁止

## ワープの実行機構

- **主機構: tap callback 内での `event.location` 書き換え** (6cab429 版 EdgeCrossingDetector と同方式)。イベント自体が移動になるため**合成イベントを生まず**、tap と同期で完結する
- この effect (`rewriteEventLocation`) は通常の非同期 effect と異なり、**tap callback 内で同期実行され、結果が callback の返り値 (書き換え済みイベント) に反映される**。Effect インタープリタの契約として明記する
- `CGWarpMouseCursorPosition` は補助 (イベントを生成しない API であることに注意) とし、使う場合は次の実イベントの座標跳びを履歴側で吸収する
- **ワープ後の履歴リセット**: ワープを実行した action の reduce で 2 世代履歴をワープ後の座標・モニタ id で埋め直す。これを怠るとワープ自身が PX (モニタ変化) として誤トリガーする

## tap の無効化・権限失効からの回復

- callback が遅いと `kCGEventTapDisabledByTimeout` で**黙って無効化**される。`tapDisabledByTimeout` / `tapDisabledByUserInput` イベントを受けて `eventTapDisabled` action を発行し、effect で `CGEvent.tapEnable` を再有効化する
- アクセシビリティ権限が実行中に剥奪された場合は検知してユーザ通知し、**ワープ機能のみ停止・レーザー描画は継続** (レーザーは NSEvent monitor で権限不要に動く) に degrade する

## PB (仮想ブロック) の実行機構

PB は「OS が通そうとする越境を毎イベント差し戻す」**継続介入**であり、ワープ (単発) よりも高頻度経路への寄与が大きい。PX 判定で PB と判定された場合、effect は `event.location` を元エッジ内にクランプした座標へ書き換え続ける。この経路も fast path のレイテンシ予算に含めて計測する。

## レイテンシ計測の輪郭

- p50/p99 を実測してから出荷する (計測 effect を用意)
- 最悪ケースを含める: **キャリブレーション画面表示中** (WebView への render model encode + 60fps ドラッグ action が main run loop を専有しがちな状況) での mouseMoved tap 応答時間

## 却下案

| 案 | 却下理由 |
|---|---|
| TCA (The Composable Architecture) | 外部依存の重さと、CGEventTap callback 内での同期 reduce + イベント書き換えという特殊経路を TCA の main-actor store 契約に載せる統合コストが、本アプリの規模に見合わない |
| v1 型の ViewModel + NotificationCenter 分散 | 今回の病巣そのもの。source of truth 不明・フラグ増殖の再発が確実 |
| 高頻度経路だけ store 外の別系統にする | 「見た目だけ Elm」になり形式化の目的 (全アクションの可視化・再生可能性) を失う。トリガーモデルにより fast path の reduce は履歴シフト + 3 分類のみで μs オーダーが設計的に保証されるため、分離は不要。実測で予算超過が観測された場合のみ再検討する |

## ステータス

Proposed (2026-07-09)
