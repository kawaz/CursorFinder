# DR-0008: キャリブレーション UI — WKWebView + JS を「純 view」として採用

## 背景

キャリブレーション UI の実装が世代で分かれている:

- v2 (LaserGuide 現 HEAD): SwiftUI + SpriteKit の物理配置編集画面。ただしエッジセグメント編集 UI は未実装
- V3 (本リポ): web (canvas + JS) プロトタイプ。モニタ/エッジの優先度リスト操作・ドラッグ編集・JSON export まで実装済みで、agent-browser による実機確認も通っている (2026-07-09)

V3 では「web UI が MoonBit を呼べず全幾何ロジックを JS 再実装 → 本体実装と発散」が Major 問題だった。UI 技術の選択と同時に、**幾何ロジックの二重実装を構造的に禁止する**必要がある。

## 決定

**キャリブレーション UI は WKWebView + JS とし、「純 view」の規律を課す。**

1. **JS は描画と操作イベントの変換のみ**を担う。幾何ロジック (エッジ検出・スナップ・座標変換・接続判定) の JS 実装は禁止
2. **表示は Swift の state から導出した JSON (render model) を受け取って描く**。操作は `postMessage` で action (DR-0004 の `CalibrationAction`) として Swift store へ送る。つまり WebView は Elm アーキテクチャの view 関数の位置に収まる
3. **プレビューも Swift 側で計算**: ドラッグ中の中間状態は action として store に流し、reducer が派生 state → render model を返す。60fps 級の追従が必要な局所ドラッグは「ドラッグ中だけ JS 側で座標を仮描画し、確定は Swift」の楽観表示を許すが、スナップ・整列などの判断は Swift の結果を正とする
4. **ブラウザ単体の開発モードを維持**: Swift ブリッジの mock (fixture の render model を返し、action を console に流す) を用意し、live-server での高速イテレーションと agent-browser によるテスト (docs/runbooks/ui-testing.md) を継続する
5. V3 web プロトタイプの操作設計 (優先度リスト、エッジハンドル、Export) は流用する。ただしコードは「純 view 化」の書き直しを伴う (V3 プロトタイプの main.js はモデル操作と幾何を内包しているため)
6. v2 の SpriteKit キャリブレーション画面は採用しない (エッジ編集が未実装で、完成度は V3 web プロトタイプが上回る。UI を 2 系統維持しない)

## 却下案

| 案 | 却下理由 |
|---|---|
| SwiftUI + SpriteKit (v2 路線) を完成させる | エッジセグメント編集・優先度リスト操作を SpriteKit で作り直すコスト > web プロトタイプ流用。UI の試行錯誤の速度も web が速い (作者の開発スタイルとも一致) |
| JS に幾何ロジックを持たせて自立させる (V3 現状路線) | 本体実装との発散が実証済み (translate 適用有無・Top/Bottom 条件が既に逆転していた)。単一正本の原則 (DR-0007) に反する |
| SwiftUI Canvas で web を置き換える | レーザー描画 (オーバーレイ) と違いキャリブレーションは複雑な編集 UI であり、web の DOM/canvas エコシステムの方が開発効率が高い。ネイティブ化の利点 (配布サイズ・起動速度) はこの画面では重要でない |

## トレードオフ (受け入れる悪い面)

- WKWebView ブリッジ (render model push / action postMessage) の配線コストが初期に乗る
- アプリ内に SwiftUI (メニューバー・設定) と WebView (キャリブレーション) の 2 UI 技術が同居する
- ドラッグ追従の楽観表示 (決定 3) は「JS が一瞬だけ独自判断で描く」点で純 view の例外となるため、範囲を明示的に限定する

## ステータス

Proposed (2026-07-09)
