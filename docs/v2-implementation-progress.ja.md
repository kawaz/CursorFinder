# LaserGuide v2 実装進捗

最終更新: 2025-11-21 (Phase 5: エッジ越境と設定管理完成)

## 完了した実装 ✅

### Phase 1: ブランチのセットアップ

- v2ブランチ作成
- v1コードを`LaserGuide.v1.backup/`にバックアップ
- 新しいディレクトリ構造作成

### Phase 2-4: コアデータモデルとサービス

#### 座標系（`LaserGuide/Core/`）
- ✅ `Point2D.swift` - 2次元座標
- ✅ `Size2D.swift` - 2次元サイズ
- ✅ `CoordinateSpace.swift` - 座標変換（logical ↔ physical）
- ✅ `DisplayFingerprint.swift` - 16進数24文字固定、x統一形式

#### ディスプレイモデル（`LaserGuide/Models/`）
- ✅ `Display.swift` - 階層化構造
  - `HardwareInfo` - fingerprint、16進参照用フィールド
  - `CoordinateInsets` - Codable版インセット
  - `CoordinateFrame` - logical/physical完全対称
  - `CoordinatesInfo` - 座標情報の統合
  - `DisplayInfo` - 状態・解像度・PPI
  - `VisualInfo` - 色・HDR
  - `osPassSegments` - OS標準（PP/PB/BP/BB判定用）
  - `passSegments` - ユーザー設定

#### エッジナビゲーション（`LaserGuide/Models/`）
- ✅ `EdgeNavigation.swift`
  - `EdgeSide` - top/bottom/left/right
  - `SegmentRange` - 実座標値範囲
  - `PassSegment` - displayId、デバッグヒント含む
  - `EdgeNavigationMap` - 高速検索用インデックス

#### 設定モデル（`LaserGuide/Models/`）
- ✅ `WorkspaceConfiguration.swift`
  - `ConfigMetadata` - アプリバージョン、Git情報
  - 物理座標の正規化
  - デフォルト生成

- ✅ `AppSettings.swift`
  - `AppConfiguration` - グローバル設定
  - `LaserSettings` - レーザー機能設定
  - `EdgeNavigationSettings` - エッジナビゲーション設定
  - `ModifierKeySet` - 修飾キー組み合わせ

#### サービスレイヤー（`LaserGuide/Services/`）
- ✅ `ConfigurationManager.swift`
  - Workspace保存/読み込み
  - 論理座標とのマージ
  - SystemMetadata生成
  - デバッグ情報出力

- ✅ `DisplayDetector.swift`
  - ディスプレイ検出
  - 変更監視
  - WorkspaceConfiguration管理

- ✅ `MouseTracker.swift`
  - マウス追跡
  - 修飾キー監視
  - 強制Block判定

- ✅ `EdgeCrossingDetector.swift`
  - エッジ付近検出
  - 越境処理（実座標値使用）

#### UI層（`LaserGuide/Views/`）
- ✅ `LaserView.swift` - SpriteKitベースのレーザー描画
- ✅ `LaserGuideApp.swift` - アプリエントリーポイント
- ✅ `AppDelegate.swift` - メニューバー、ウィンドウ管理

### ドキュメント

- ✅ `docs/v2-data-model-design.ja.md` - 完全な設計書（560行）
- ✅ `docs/v2-implementation-progress.ja.md` - 本ファイル

---

## 確定した設計仕様

### 1. Fingerprint形式
```
000006100000A051FD626D62-3456x2234x1
^^^^^^^^^^^^^^^^^^^^^^^^-^^^^^^^^^^^
24文字固定16進数        幅x高さxスケール
```

### 2. 設定キー
```
config_000006100000A051FD626D62-3456x2234x1_00001E6D00009E8B0007543B-3440x1440x1
```

### 3. Display階層化
```json
{
  "hardware": { "fingerprint": "...", "vendorIDHex": "...", ... },
  "coordinates": {
    "logical": { "position": [0,0], "size": [3456,2234], ... },
    "physical": { "position": [0,0], "size": [344.2,222.5], ... }
  },
  "display": { "resolution": { "ppi": 255 }, ... },
  "visual": { ... },
  "osPassSegments": [ ... ],
  "passSegments": [ ... ]
}
```

### 4. PassSegment
- 実座標値（px/mm）で保存
- displayId含む（高速検索）
- デバッグヒント（pairedDisplayId/Name/Side）

### 5. 設定構造
- `AppConfiguration` - グローバル（laser/edgeNavigation）
- `WorkspaceConfiguration` - ディスプレイ構成ごと
- `SystemMetadata` - デバッグ用（保存しない）

---

## 未完了の実装

### Phase 5: エッジ越境の実装 🔜

- ✅ EdgeCrossingDetector 基本構造
- ⏳ CGEventによる実際のマウス移動
- ⏳ PP/PB/BP/BBパターン実装
- ⏳ 強制Block機能の統合
- ⏳ エッジ交点計算の最適化

### Phase 6: キャリブレーションUI ⏳

- ディスプレイ配置エディター（SpriteKit）
- PassSegmentエディター
- 設定ウィンドウ
- ライブプレビュー

### Phase 7: 最終調整とテスト ⏳

- 複数ディスプレイ構成での動作確認
- パフォーマンス最適化
- バグ修正
- ドキュメント完成

---

## コミット履歴

### `5e06c9a` - データモデルとコアサービスの実装
- v1バックアップ
- 基本的なデータ構造
- サービスレイヤー
- 基本的なレーザーレンダリング

### `9e772cd` - 実装コードを最終設計に更新
- DisplayFingerprint（16進数、x統一）
- Display階層化
- PassSegment実座標値
- ConfigMetadata Git情報
- AppConfiguration機能別設定
- SystemMetadata

### 最新 - PassSegment自動生成・ペアリング完成
- ✅ `linkOSPassSegments()` 完全実装
  - 対向ディスプレイの自動検出
  - 重複範囲の計算
  - ベストマッチのペアリング
  - 相互参照の自動設定
- ✅ `linkUserPassSegments()` 完全実装
  - ユーザーセグメントのペアリング
- ✅ ビルド成功、warning解消
- ✅ 実機テストで動作確認
  - 2ディスプレイ環境で正常動作
  - Built-in Display (top) ↔ LG ULTRAGEAR+ (bottom)
  - ペアリング情報が正しく設定されることを確認

### 4. エッジ越境の実装（Phase 5）

#### EdgeCrossingDetector完成
- ✅ CGEventTapによるマウスイベントフック
- ✅ エッジ検出とマウス座標書き換え
- ✅ アクセシビリティ権限チェック
- ✅ 強制Block機能の統合
- ✅ デバッグログ出力

#### Configuration管理の完成
- ✅ WorkspaceConfiguration自動保存
  - `loadOrCreateWorkspace()`で新規作成時に自動保存
  - マージ後の設定も自動保存
- ✅ AppConfiguration自動保存
  - `loadOrCreateConfiguration()`で新規作成時に自動保存
- ✅ PassSegmentのCodingKeys明示
  - 循環参照エラーを修正
  - 実行時キャッシュをエンコードから除外
- ✅ 起動時の初期化フロー確立

---

## 次のステップ

1. ✅ データモデル設計完了
2. ✅ コア実装完了
3. ✅ PassSegment自動生成・ペアリング完成
4. ✅ エッジ越境の実装完了（CGEvent）
5. ✅ 設定の保存・読み込み完了
6. 🔜 アクセシビリティ権限を付与して動作テスト
7. ⏳ 物理配置の初期値決定（BFS移植）
8. ⏳ キャリブレーションUI実装
9. ⏳ 最終調整とテスト

---

## 技術的な特徴

- **座標系統一**: SpriteKit採用、Y軸反転不要
- **階層化JSON**: 論理/物理が完全対称で比較しやすい
- **実座標値**: 正規化不要、高速
- **デバッグ性**: 16進参照、ヒントフィールド
- **拡張性**: 機能別設定、将来の機能追加に対応
