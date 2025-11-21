# LaserGuide v2 実装進捗

## 完了した実装

### Phase 1: ブランチのセットアップ ✅

- v2ブランチ作成
- v1コードを`LaserGuide.v1.backup/`にバックアップ
- 新しいディレクトリ構造作成

### Phase 2: コアデータモデル ✅

#### 座標系（`LaserGuide/Core/`）
- `Point2D.swift` - 2次元座標（物理座標用）
- `Size2D.swift` - 2次元サイズ（物理サイズ用）
- `CoordinateSpace.swift` - 座標変換（logical ↔ physical）
  - SpriteKit採用により左下原点・Y軸上向きに統一
  - Y軸反転不要

#### ディスプレイ識別（`LaserGuide/Core/`）
- `DisplayFingerprint.swift`
  - HardwareIdentifier（ベンダー、モデル、シリアル）
  - 解像度を含む（回転時に別設定として扱う）
  - 設定キー生成

#### ディスプレイモデル（`LaserGuide/Models/`）
- `Display.swift`
  - PhysicalLayout（保存用、物理情報のみ）
  - LogicalSnapshot（デバッグ用スナップショット）
  - Display（実行時、論理+物理の統合）
  - 物理座標の正規化（全体の最小点を原点）

#### エッジナビゲーション（`LaserGuide/Models/`）
- `EdgeNavigation.swift`
  - EdgeSide（top/bottom/left/right）
  - PassSegment（通過可能区間）
    - 空セグメント（start==end）でワープポイント表現
    - ペアリングによる双方向接続
  - DisplayEdge（ディスプレイの一辺）
  - EdgeNavigationMap（全体マップ）
  - 越境処理（位置比率補正）

#### ワークスペース設定（`LaserGuide/Models/`）
- `WorkspaceConfiguration.swift`
  - DisplayConfiguration
  - Workspace（論理+物理の統合）
  - デフォルト設定の自動生成

#### アプリ設定（`LaserGuide/Models/`）
- `AppSettings.swift`
  - ModifierKeySet（修飾キー組み合わせ）
  - 強制Block機能設定

### Phase 3: サービスレイヤー ✅

#### 設定管理（`LaserGuide/Services/`）
- `ConfigurationManager.swift`
  - UserDefaultsへの保存/読み込み
  - 論理スナップショット追加
  - デバッグ情報生成

#### ディスプレイ検出（`LaserGuide/Services/`）
- `DisplayDetector.swift`
  - NSScreen監視
  - ディスプレイ変更検出
  - ワークスペース再読み込み

#### マウス追跡（`LaserGuide/Services/`）
- `MouseTracker.swift`
  - グローバルマウスイベント監視
  - アクティビティ検出（idle/active）
  - 修飾キー監視
  - 強制Block判定

#### エッジ越境検出（`LaserGuide/Services/`）
- `EdgeCrossingDetector.swift`
  - エッジ付近検出
  - 越境処理
  - 強制Block適用

### Phase 4: UI層 ✅

#### アプリ構造（`LaserGuide/`）
- `LaserGuideApp.swift` - アプリエントリーポイント
- `AppDelegate.swift`
  - メニューバーアイテム
  - レーザーウィンドウ管理
  - サービス起動

#### レーザー表示（`LaserGuide/Views/`）
- `LaserView.swift`
  - SpriteKitベースの描画
  - 4隅からのレーザーライン
  - マウスアクティビティ連動

### ドキュメント ✅

- `docs/v2-data-model-design.ja.md` - データモデル設計書
- `docs/v2-implementation-progress.ja.md` - 実装進捗（本ファイル）

---

## 未完了の実装

### Phase 5: キャリブレーションUI ⏳

- ディスプレイ配置キャンバス（SpriteKit or SwiftUI）
- エッジエディター
- 設定ウィンドウ
- ライブプレビュー

### Phase 6: 統合とテスト ⏳

- Xcodeプロジェクトファイルへの新規ファイル追加
- ビルドと動作確認
- エッジ越境の実際の動作テスト
- バグ修正

---

## 次のステップ

1. **Xcodeプロジェクトファイルの更新**
   - 新規作成したSwiftファイルをXcodeプロジェクトに追加
   - ビルドターゲットの確認

2. **ビルドと基本動作確認**
   - アプリが起動するか
   - レーザーが表示されるか
   - マウス追跡が動作するか

3. **キャリブレーションUIの実装**
   - ディスプレイ配置編集
   - エッジセグメント編集
   - 設定の保存/読み込み

4. **エッジ越境の実装**
   - 実際のマウス座標書き換え
   - ブロック処理
   - 物理補正

5. **テストと調整**
   - 複数ディスプレイでの動作確認
   - パフォーマンス調整
   - バグ修正

---

## 設計の特徴

### シンプルな座標系
- logical と physical の2種類のみ
- SpriteKitと統一（左下原点、Y上向き）
- Y軸反転不要

### シンプルなエッジ管理
- PassSegmentのみ保存（Blockは暗黙的）
- 空セグメント（start==end）でワープ表現
- 位置比率補正による柔軟な越境

### 正規化された保存データ
- 論理座標はスナップショットのみ（実行時取得）
- 物理座標の原点は全体の最小点
- メインディスプレイ変更の影響を受けない

### 拡張性
- 任意のEdge同士をペアリング可能
- 修飾キーによる動作変更
- 将来の機能追加を見据えた設計

---

## コードメトリクス

- **新規ファイル**: 13個のSwiftファイル
- **追加行数**: 約2500行
- **コア型**: Point2D, Size2D, DisplayFingerprint, Display, PassSegment
- **サービス**: 4つ（Configuration, Display, Mouse, EdgeCrossing）
- **リンターエラー**: 0

---

## 実装済み機能

✅ ディスプレイ検出
✅ 物理座標管理
✅ エッジナビゲーション（データ構造）
✅ マウス追跡
✅ 基本的なレーザー表示
✅ 設定の永続化
✅ 修飾キーによる強制Block

## 未実装機能

⏳ キャリブレーションUI
⏳ 実際のエッジ越境処理（マウス座標書き換え）
⏳ 物理補正の適用
⏳ エッジセグメントの視覚的編集
