# DR-0002: 実装アーキテクチャの転換 — MoonBit 廃止、Swift 単一実装コア

## 背景

V3 は「ワープ判定コアを MoonBit で書き、Wasm (web UI) と native (Swift) の両方から呼ぶ」構成の実験として始まった。2026-07-09 の全方位レビュー (Fable + Codex 独立レビュー、収束) で以下が実測確認された:

- **Wasm FFI は実際には不通**: Node 実測で MoonBit String 引数が渡せず、返り値タプルも opaque。エクスポート 6 関数のうち実質 `mb_init`/`mb_cleanup` しか機能しない
- **web UI は既に全ロジックを JS 再実装**しており、MoonBit 実装と発散済み (translate 適用有無・Top/Bottom 生成条件が逆)
- **native C FFI のグルーコードは未存在** (include/moonbit_warp.h の ABI と MoonBit String/タプルは自動では合わない)
- CLAUDE.md (Wasm) と DESIGN.md (Native) で高頻度経路の記述が矛盾したまま未決定

さらにプロジェクトの主目的が「レーザー描画 (マルチモニタで綺麗に繋がる) が先、ワープとエッジ座標補正はその派生」と確定した。レーザー描画は Metal/Swift 以外に選択肢がない。

## 決定

**幾何コアを含む全実装を Swift 単一とする。MoonBit は廃止。**

- ワープ判定・エッジ接続・座標変換の幾何コアは Swift の純関数レイヤとして実装し、ユニットテストで仕様輪郭を描く
- MoonBit の既存テスト 43 件が表現する仕様輪郭 (rate マッピング、エッジ検出、force_block 等) は Swift テストへ移植して保全する
- V3 リポの MoonBit コードは参照資産としてこのリポに残し、後継ブランチ (DR-0003) には持ち込まない

## 却下案

| 案 | 却下理由 |
|---|---|
| Wasm FFI を開通させて堅持 | js-string-builtins 等で JS 側は直せても、Swift 側に Wasm ランタイム (WasmKit=インタプリタ/wasmtime=重量) を積む必要があり、イベントタップのレイテンシ制約 (遅延はカーソルラグ、タイムアウトで tap 無効化) に対しリスクが本質的。FFI 3 系統の維持コストも実証済みに高い |
| native backend + C FFI | ABI グルーコードをゼロから書く統合作業が重く、判定ロジック (~300 行の純幾何) の規模に見合わない。web UI 側の二重実装問題も残る |
| MoonBit を golden テストベクタ生成器として残す | 「単一仕様の維持」は Swift 純関数テストに仕様意図コメントを込める形で達成でき、後継リポに MoonBit toolchain を持ち込む恒常コストの方が大きい |

## 影響範囲

- 後継ブランチの実装言語構成 (DR-0003)
- moonbit/ 配下は本リポで凍結 (近代化 migration は実施しない)
- web UI の位置づけは DR-0008 で再定義

## ステータス

Proposed (2026-07-09)
