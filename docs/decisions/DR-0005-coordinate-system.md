# DR-0005: 座標系規約 — CG グローバル (y-down) を正とし、論理/物理を型で分離する

## 背景

V3 の Critical バグ 2 件はどちらも座標系規約の未確定が根本原因だった (2026-07-09 レビュー):

- Top/Bottom 辺の意味が init.mbt (y-up、NSScreen 由来) と core.mbt (y-down) で逆転し、上下隣接モニタのワープ判定が全滅
- 論理座標と物理座標を同じ `Point` 型で混用し、キャリブレーション (transform≠identity) を設定した瞬間に全判定が破綻する構造 + 逆変換の不在

macOS には座標系が 2 つ共存する古典的罠がある: **NSScreen / NSEvent は bottom-left 原点 y-up**、**CGDisplay / CGEvent は top-left 原点 y-down**。v1/v2 は NSEvent 世界、CGEventTap (ワープの入出力) は CG 世界で、混在が避けられない。

さらにレーザー描画が主目的と確定したため、「モニタを跨いで直線が物理的に真っ直ぐ繋がる」ための **mm 単位の物理空間**が第一級の要件になった (V3 の物理座標系は translate のみで px/mm scale を持たず、この要件を表現できなかった)。

## 決定

### 1. グローバル論理座標の正 = CG 座標系 (top-left 原点、y-down)

- 根拠: ワープの入力 (CGEventTap の `event.location`) と出力 (`event.location` 書き換え / `CGWarpMouseCursorPosition`) がどちらも CG 座標。判定コアを入出力と同じ系に置くことで高頻度経路の変換をゼロにする
- モニタ矩形は `CGDisplayBounds` (CG 座標) で取得する。NSScreen / NSEvent 由来の値は **境界 (Effect / 入力アダプタ層) で即座に CG へ変換**し、reducer より内側に y-up の値を持ち込まない

### 2. 論理空間と物理空間を型で分離する

```swift
struct LogicalPoint { var x, y: Double }   // CG グローバル論理座標 (px)
struct PhysicalPoint { var x, y: Double }  // 物理配置空間 (mm)
```

- 物理空間の単位は **mm**。モニタごとの pose (配置 translate + px→mm scale。scale は解像度と physical size から導出し、キャリブレーションで補正可能) で `logical ↔ physical` を**双方向に**変換する。逆変換 (physical → logical) を最初から実装する (V3 に欠けていて WarpTo が使えなかった)
- **mm 情報が取れないディスプレイの fallback**: `CGDisplayScreenSize` は EDID 不備の機種やプロジェクタで 0 や不正値を返す。その場合は仮定 DPI (110dpi 相当) で暫定 scale を与え、キャリブレーション UI 上で「physical size 未取得・要手動補正」を明示する。レーザー直進性がこの値に依存するため、黙って仮定値のまま見せない
- ワープ判定・エッジ接続・レーザーの直線性計算は物理空間で行い、OS へ返す直前に論理座標へ逆変換する
- **描画境界の変換規則**: オーバーレイ NSWindow/NSView のローカル座標は y-up 世界であり、y 反転バグの再発ポイントになる。CG グローバル → 各 display の view ローカルへの変換 (per-display の y-flip 込み) は描画 Effect/view 層の境界 1 箇所に集約し、レーザー描画テスト (物理直進性) はこの変換を通した後の値で assert する
- 3D pose (roll/pitch/yaw、モニタの向き) は将来のレーザー投影拡張として型に場所だけ確保し、Phase 1 は translate + scale の 2D に限定する

### 3. 検証の輪郭 (この DR の受け入れ条件)

- 上下隣接 2 枚構成のワープ判定テスト (V3 では 0 件だった軸)
- transform ≠ identity (translate と scale を設定) 状態でのワープ判定・逆変換テスト
- px/mm が異なる 2 枚 (例: Retina 内蔵 + 外部モニタ) を跨ぐレーザー直線の物理空間直進性テスト

## 却下案

| 案 | 却下理由 |
|---|---|
| NSScreen (y-up) を正とする | ワープ入出力 (CG) との変換が高頻度経路に入る。なお v1/v2 の資産は「y-up で統一されている」のではなく **y-up (NSScreen frame) と y-down (event.location) が無変換で混在**しており (2026-07-09 敵対レビューで実コード確認、V3 と同型の y 反転バグ)、どちらを正にするにせよ境界変換の規律が本丸 |
| 単一 Point 型のまま規約コメントで運用 | V3 で破綻済み。混用はコンパイルエラーにするのが再発防止の本丸 |
| 物理空間を px のまま (V3 方式) | px/mm 差の補正ができず、レーザー直線性 (主目的) の必要条件を満たさない |

## ステータス

Proposed (2026-07-09)
