# 実機フィードバック第 3 ラウンド (2026-07-10)

第 2 ラウンド修正 (083e60e) を kawaz が実機確認した結果と、その場で直した分の記録。

## tap レイテンシ基準線 (DR-0004 の性能ベースライン、初記録)

kawaz 実機 (LG 上 + 内蔵 下 構成、`swift run laserguide-dev` debug ビルド) にて:

```
[latency] n=4096 total=13062 p50=156.4μs p95=469.0μs p99=758.2μs max=2918.0μs
```

- p50 ≈ 156μs / p99 ≈ 758μs / max ≈ 2.9ms。tap callback 内処理は 60fps フレーム予算
  (16.6ms) の 5% 未満に収まっており、体感遅延への寄与は無視できる水準
- 以後の変更でこの値から大きく退行したら tap callback 内の処理追加を疑う

## 確認結果と対応

| # | 結果 | 対応 |
|---|---|---|
| ①キャリブレーション前面化 | **改善確認** (中央・最前面に出る)。ドラッグ編集も動作 | done (083e60e) |
| ②クリックサークル | **Y が約 150px 下にズレる** | 即修正 (下記 bug 1) |
| 新規) ドラッグ中レーザー復活しない | mousedown 静止 → フェード後、押したまま動かしても再描画されない | 即修正 (下記 bug 2) |
| ③フォーカスフラッシュ | 反応はしているが「うっすら暗くなる」ようにしか見えない。求める絵はウィンドウ枠の発光・炎・バウンド等のオーバーレイエフェクト + 他モニタからの方向矢印 | Phase B の設計課題として issue 更新 (見せ方の全面再設計) |
| ⑤ .app 起動 | `just build-app` は成功 (ad-hoc 署名 verify pass)。Finder 起動確認は dev 版終了後に kawaz 手動 | 待ち |

## bug 1: クリックサークルの Y ズレ (~150px 下)

- **root cause**: `PermissionMonitor.nsScreenPointToCG` が基準高さに `NSScreen.main`
  (= **キーボードフォーカスのあるウィンドウの画面**) を使っていた。DR-0005 の y-flip 変換
  `cgY = H - nsY` の H は **primary スクリーン (Cocoa 原点 (0,0) を持つ `NSScreen.screens.first`)**
  の高さでなければならない。フォーカス画面と primary の高さ差がそのまま Y オフセットになる
- **なぜレーザーでは顕在化しなかったか**: レーザー座標は通常 CGEventTap (CG ネイティブ座標)
  経由で、この変換を通るのはクリックサークル (NSEvent.mouseLocation) と laser-only fallback のみ
- **fix**: `NSScreen.screens.first` に変更 + 高さ注入オーバーロードを切って純関数部を
  `PermissionMonitorTests` で固定 (上端/下端/primary より上の負領域/x 不変)

## bug 2: フェード後のドラッグでレーザーが復活しない

- **root cause**: drag position monitor が `isMouseActive == false` (アイドルフェード後) の間
  イベントを丸ごと捨てる第 2 ラウンド #5 の最適化ゲート。「非表示中に始まったドラッグは無関係な
  ウィンドウ操作」という仮定が、「ボタンを押したまま動かしたらレーザーは出るべき」という実機の
  期待と衝突した
- **fix**: ゲートを撤去し、ドラッグ移動を mouseMoved と同格の「ポインタ活動」として常に VM へ
  流す。パフォーマンス制御は VM 側 coalesce (トレーリングエッジ間引き) に一元化 — monitor
  closure の仕事は CG 変換 + pending 上書きだけで、@Published 発火はイベントレートに比例しない

## 議論メモ (裁定待ち・次ラウンド入口)

- **キャリブレーションの次元**: 現行モデルは 2D (物理 mm 平面、pose = translate)。kawaz から
  「エッジハンドル等を足すならレイキャスト当たり判定の方がやりやすいのでは」の論点が出た
- **フォーカスフラッシュの見せ方**: 縁 24px stroke + blur では「画面が暗くなった」ようにしか
  見えない。ウィンドウ枠発光 / パーティクル / スケールバウンス / 方向矢印などの案出しと
  技術選定 (SwiftUI Canvas / CAEmitterLayer / Metal shader) を Phase B でやる
