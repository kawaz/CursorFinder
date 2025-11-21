# LaserGuide v2 実装進捗

最終更新: 2025-11-21

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

### Phase 5: キャリブレーションUI ⏳

- ディスプレイ配置エディター（SpriteKit）
- PassSegmentエディター
- 設定ウィンドウ
- ライブプレビュー

### Phase 6: 統合とテスト ⏳

- Xcodeプロジェクトファイル更新
- ビルドと動作確認
- エッジ越境の実際の動作実装（CGEvent）
- PP/PB/BP/BBパターン実装
- バグ修正

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

---

## 次のステップ

1. ✅ データモデル設計完了
2. ✅ コア実装完了
3. ⏳ Xcodeプロジェクトファイル更新
4. ⏳ ビルドテスト
5. ⏳ キャリブレーションUI実装
6. ⏳ エッジ越境の実際の動作実装

---

## 技術的な特徴

- **座標系統一**: SpriteKit採用、Y軸反転不要
- **階層化JSON**: 論理/物理が完全対称で比較しやすい
- **実座標値**: 正規化不要、高速
- **デバッグ性**: 16進参照、ヒントフィールド
- **拡張性**: 機能別設定、将来の機能追加に対応
