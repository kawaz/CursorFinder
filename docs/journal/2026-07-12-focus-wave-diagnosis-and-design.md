# 2026-07-12: 「LG で focus flash が出ない」調査 → 波動エフェクト (DR-0011) 実装

## 発端

実機第 5 ラウンド: kawaz 報告「内蔵ではエフェクトが出るが LG 側のウィンドウでは出ない」。

## 調査の経緯 (ハマり所 → 解決のペア)

- **unified log が読めない**: zsh では `log` がビルトインに食われる → `/usr/bin/log` を
  使う。さらに NSLog の動的文字列は log show で `<private>` に落ちて内容が読めない
  (診断には stderr 直取りか os_log public 指定が要る)
- **y-flip 仮説 (本命だった) は棄却**: 「AX が y-up を返すなら primary 上では両解釈の値域が
  一致して見かけ上正しく動き、負 y 領域の LG だけ壊れる」という筋の良い仮説を立てたが、
  14 アプリ × CGWindowList 突合で AX は負 y 領域でも y-down と実証
  (findings/2026-07-12-ax-window-frame-y-down.md)
- **アプリ外 end-to-end 再現はシロ**: observer→AX→resolve を再現スクリプトで回し、
  LG ウィンドウは正しく LG に解決される。overlay も CGWindowList で両画面に存在確認
- **真相はバグではなく仕様の行き違い**: Phase A の実装は「モニタ縁」フラッシュで、kawaz の
  オーダーは「ウィンドウ枠」。内蔵はフルスクリーン運用のためモニタ縁 ≈ ウィンドウ枠となり
  Phase A 評価時に区別できていなかった。加えて `didActivateApplication` はアプリ切替でしか
  発火しない (同一アプリのウィンドウ間移動を拾わない) 制約も重なった

## 教訓

- 座標系の実機検証は primary モニタだけでは無意味 (y-up/y-down の値域が一致する)。
  負座標領域のモニタを必ずサンプルに含める
- 「エフェクトが出ない」系の報告は、コードの各層を疑う前に「何が出るはずだと期待されて
  いるか (オーダー)」と「何を出す仕様か (DR)」の突合を先にやる価値がある

## 裁定 (kawaz)

1. エフェクトの主役は「フォーカスウィンドウを震源に周囲へ拡がる衝撃波」。モニタ縁も併存
2. 波動は mm 空間ベースで描画。キャリブレーション未整備の現時点では「論理配置の隣接関係を
   保ったまま物理サイズ補正して接して並べる」派生レイアウトで良い
3. origin の旧 v3 ブランチは放置で良い (削除しない)

→ DR-0011 に決定として記録、feature/focus-flash-wave ブランチで実装。

## 実装 (workflow 並列)

Core (WaveLayout/WaveGeometry/Action 置換) → App 2 並列 (AXObserver 購読 / VM・View 描画)
→ 統合 ci → Fable レビュー、の 4 フェーズ workflow で実装。just ci green。
レビュー指摘 (Major 3 / Minor 7 / Nit 5、Critical 0) は同日中に修正反映。
