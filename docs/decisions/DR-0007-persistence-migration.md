# DR-0007: 永続化と後方互換 — v2 fingerprint 採用、v1 設定の migration を用意

## 背景

配布中の v0.12.1 (v1 実装) と v2 骨格で永続化方式が異なる (2026-07-09 偵察 §6):

- v1: key `LaserGuide.Calibration.config_<sorted DisplayIdentifier>` + `.temporary` サフィックス方式のプレビュー保存
- v2: key `LaserGuide.v2.Workspace.<DisplayFingerprint>` (hardwareId + resolution + backingScaleFactor)
- v1 → v2 の migration は未実装。このままリリースすると既存ユーザは「更新したらキャリブレーションが消えた」を体験する

## 決定

1. **モニタの同一性判定は hardwareId のみで行い、resolution / backingScaleFactor は key に含めない**。v2 の DisplayFingerprint (hardwareId + resolution + backingScaleFactor) をそのまま使うと、解像度スケーリングを変えるたびにキャリブレーションが消える。mm ベースの pose (DR-0005) は本質的に解像度非依存であり、解像度変更で変わる px→mm scale は現在の resolution から毎回導出する。V3 の `generate_config_id` (枚数+解像度のみ) は同型モニタ 2 枚を区別できず不採用
   - **hardwareId 衝突時の fallback**: `CGDisplaySerialNumber` が 0 を返す機種では同型 2 枚が同一 id になりうる。衝突を検知した場合は接続順・位置による補助識別子を付与し、その旨を state に記録する (実機検証は下記輪郭)
2. **key prefix は `LaserGuide.v3.`** とし、スキーマに version フィールドを含める (将来の migration を一方向の変換関数として書けるようにする)
3. **v1 設定の migration reader を用意する**: 起動時に新 key が無く v1 key があれば、v1 `DisplayConfiguration` → 新スキーマへ変換して保存する。v2 prefix は未リリースのため migration 対象外 (開発者ローカルのみ)
4. **Bundle ID `jp.kawaz.LaserGuide` は維持**する。Cask の `uninstall quit:` / `zap trash:` の経路を壊さない (DR-0003)
5. **プレビューの `.temporary` キー方式は廃止**: プレビュー状態は永続化せず reducer 内の派生 state で表現する (DR-0004)。migration 時に残存 `.temporary` キーは読み捨てて削除する
6. **スキーマの型の正本は Swift の Codable 型に一元化する**。永続スキーマと WebView へ渡す render model (DR-0008) は別の型だが、どちらも同じ Swift 型定義から encode する。V3 で起きた「Swift 出力 / docs / MoonBit 型の 3 者不一致」(os_name vs name_default 等) の再発を、正本を 1 箇所にすることで防ぐ
7. **display 構成変化時のユーザ編集セグメントの reconcile**: `osPassSegments` は構成変更ごとに再生成されるが、ユーザの `passSegments` は hardwareId 単位で保持し、再接続時に現構成へ再マッピングする。対応先を失ったセグメントは削除せず「無効 (inactive)」として保持し、キャリブレーション UI で可視化する (モニタを一時的に外しただけで設定が消える体験を避ける)

## 検証の輪郭

- v1 実キー (配布版が書いた実データ) からの読み込み→変換→新キー保存の round-trip テスト
- fingerprint: 同型モニタ 2 枚構成で別 ID になること、ケーブル差し替え・再接続で同一 ID になることの実機確認
- 新スキーマの encode/decode round-trip + version フィールド前提の前方互換テスト

## ステータス

Proposed (2026-07-09)
