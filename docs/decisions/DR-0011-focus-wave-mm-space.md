# DR-0011: フォーカス波動エフェクト (mm 空間・隣接物理レイアウト)

関連: DR-0009 (フォーカスフラッシュ Phase A), DR-0005 (座標系), 実機フィードバック第 5 ラウンド

## 背景

DR-0009 Phase A は「フォーカス先モニタの縁を光らせる」実装で出荷したが、実機評価で
kawaz のオーダーは「**フォーカスしたウィンドウ**を震源とするエフェクト」であることが
確定した (内蔵モニタはフルスクリーン運用のためモニタ縁 ≈ ウィンドウ枠となり Phase A
評価時に区別できていなかった)。

あわせて Phase B の見せ方が裁定された: **ウィンドウ枠から衝撃波 (波紋) が周囲に拡がって
減衰するエフェクト**。物理配置された別モニタにも波が届くことで、(1) どのウィンドウが
震源か (2) どの方向か (3) 全画面に及ぶので気づきやすい、を 1 表現で満たす。

## 決定

### 1. 波動は mm 空間で計算・描画する

- 波の半径・帯幅・減衰は mm 単位で定義する (モニタの px 密度差に影響されない等方伝播)
- キャリブレーション未整備の現時点では pose.translate を尊重せず、**「論理配置の隣接
  関係を保ったまま、物理サイズ (mm/px scale) で各モニタを接して並べる」派生レイアウト**
  (WaveLayout) を都度構築する (kawaz 裁定 2026-07-12)。キャリブ済み translate の尊重は
  キャリブレーション UI 第 2 ラウンド後の後続イテレーション

### 2. WaveLayout (隣接物理レイアウト) の構築規則

入力: `[Display]` (logicalBounds + pose.scale)。出力: displayId → `WavePlacement`
(mm 空間での矩形 + 変換)。

- **anchor**: 論理 (0,0) を containsHalfOpen する display (= primary)。無ければ
  logicalBounds.(minY, minX) 辞書順最小。anchor の mmRect.min = (0,0)
- **接触判定**: 論理空間で辺が接する (例: A.maxX == B.minX、eps=0.5px) かつ直交方向の
  overlap 区間長 > 0 (角のみの接触は非接触扱い)
- **配置 (BFS)**: 接触グラフを anchor から BFS。B を A の右に置く場合
  `B.mm.minX = A.mm.maxX`、直交方向は **論理 overlap 区間の中点が mm 空間で一致する**
  よう平行移動 (`A.mmY(yc) == B.mmY(yc)`、yc = overlap 中点)。他の辺も対称
- 複数の隣接から到達可能な場合は BFS で最初に置いた親を採用 (2 枚構成では非発生)
- **非連結成分**: fallback として `mmRect.min = (logical.minX*scaleX, logical.minY*scaleY)`
  (translate=0 相当) で置く。重なりうるが Phase 1 は許容

### 3. 波動の幾何

- 震源 = フォーカスウィンドウ frame を mm へ写像した `PhysicalRect`
- 波 = 震源矩形を radius だけ外側へ膨張した角丸矩形リング (cornerRadius = radius、
  = 矩形からの等距離線)。帯幅 bandMM、進行 p∈[0,1] で
  `radius = p * (maxDistanceMM + bandMM)`、`opacity = initial * (1-p)`
- `maxDistanceMM` = 全 display mmRect の 4 隅と震源矩形の点-矩形距離の最大値
  (= 波が最遠隅に到達しきってから消える)
- 初期値 (実機チューニング前提の var): duration 0.7s / band 30mm / initialOpacity 0.5

### 4. 入力: ウィンドウ単位のフォーカス観測を追加

- 従来の `NSWorkspace.didActivateApplicationNotification` (アプリ切替) に加え、
  アクティブアプリの **AXObserver で `kAXFocusedWindowChanged` を購読** (同一アプリ内の
  ウィンドウ/ダイアログ間フォーカス移動で発火しなかった Phase A の穴を塞ぐ)
- アプリ切替時に旧 AXObserver を破棄して新 pid に張り直す
- Action は `.focusedDisplayChanged(displayId:)` を **`.focusedWindowChanged(displayId:
  windowFrame: LogicalRect)` に置き換え** (Phase A の action は displayId しか運ばず
  震源を表現できない。後方互換は不要 — 内部 action)
- `FocusFlashState` に `windowFrame: LogicalRect` を追加。generation 意味論は不変

### 5. モニタ縁フラッシュは併存

Phase A のモニタ縁フラッシュは残す (kawaz 裁定「それもやりつつ」)。主役は波動。
opacity 等の主従バランスは実機ラウンドで調整する。

## 検証済みの前提 (2026-07-12 実機調査)

- AX `kAXPositionAttribute` は LG (負 y 領域) のウィンドウでも CG グローバル y-down を
  返す (14 アプリ × CGWindowList 突き合わせで全一致、マトリクスは
  docs/findings/2026-07-12-ax-window-frame-y-down.md が正本)。DR-0009 決定 3 の
  「AX y-up 前提」は実機と乖離しており、identity 変換が正
- observer→AX→resolve の経路はアプリ外再現で LG ウィンドウを正しく LG に解決する
- 「LG でエフェクトが出ない」報告の原因はバグではなく Phase A の仕様 (モニタ縁) と
  オーダー (ウィンドウ枠) の乖離 + didActivateApplication の粒度 (アプリ単位) の複合

## 不採用案

- **CG 論理空間での波動**: 実装最小だが「物理的な距離感・方向」の表現が OS 論理配置の
  歪みを受ける。mm 化がプロダクトの本義 (物理配置の可視化) に合う (kawaz 裁定)
- **pose.translate をそのまま使う**: 未キャリブ時に translate=0 で per-display 独立
  mm 空間となり、モニタ間の波の連続性が壊れる。キャリブ整備後に再検討
- **ウィンドウ枠グロー単体 (波動なし)**: 震源モニタ以外に情報が届かない

## 検証記録

- AX y-down の実機マトリクス: docs/findings/2026-07-12-ax-window-frame-y-down.md
- 実機確認手順: docs/runbooks/v3-dev-run.md の「フォーカス波動の実機確認」節

## ステータス

Accepted (2026-07-12, kawaz 裁定)
