# LaserGuide v2 次回の作業項目

## 🔧 残っている実装

### 1. PassSegment自動生成の完成

現在`osPassSegments`が空配列のまま。以下を実装する必要あり：

#### linkOSPassSegments()
- 対向するPassSegmentを検出
- pairedSegmentIdを相互に設定
- pairedSegment参照を設定

#### linkUserPassSegments()
- osPassSegmentsからコピーしたuserPassSegments同士をペアリング
- 新しいUUIDとの対応を正しく設定

### 2. AppConfigurationの出力

デバッグ情報に`appConfiguration`セクションが含まれていない。
- 現在は`configuration`と`system`のみ
- `appConfiguration`も追加

### 3. 保存・復元のテスト

実際の動作確認：
1. PassSegmentを手動設定
2. 保存
3. アプリ再起動
4. 復元確認
5. pairedSegmentキャッシュが正しく復元されるか

---

## 🤔 気になる点（要検討）

### 1. 物理座標の正規化タイミング

現在の実装：
- `createDefault()`で各Displayの物理位置は`(0,0)`
- 最後に全体を正規化

疑問：
- 初期配置はどう決める？（論理的隣接を元に物理配置を推測？）

### 2. 解像度変更時の物理座標

解像度を変更すると：
- fingerprintが変わる
- 別の設定セットになる
- 物理サイズは変わらない（ハードウェアは同じ）

対応：
- 前の設定から物理配置をコピー？
- 毎回デフォルトから？

### 3. PassSegmentの編集UI

ユーザーがPassSegmentを編集する際の制約：
- 同じedge上で重複禁止
- ペアの整合性維持
- 物理座標との連動

---

## 📋 次回セッションで進めること

### 優先度: 高

1. **PassSegment自動生成の完成**
   - 論理的隣接検出
   - 対向セグメントのペアリング
   - テストデータでの動作確認

2. **完全な保存・復元テスト**
   - 手動でPassSegment設定
   - UserDefaultsへの保存確認
   - 復元後のキャッシュ確認

### 優先度: 中

3. **AppConfiguration統合**
   - デバッグ出力への追加
   - workspace参照の動作確認

4. **物理配置の初期値決定**
   - 論理配置から推測するアルゴリズム

### 優先度: 低（UI実装後）

5. **キャリブレーションUI**
6. **エッジ越境の実際の動作**

---

## 💡 メモ

- Display.physical.position の初期値が全て(0,0)になっている
  - 論理配置から推測して初期配置を作るべき？
  - BFS アルゴリズム（v1で使っていた）を移植？

- `isMain`が逆になっている？
  - Built-in: `"isMain": false`
  - LG: `"isMain": true`
  - LGをメインに設定している？

- Git情報がnull
  - Info.plistへの埋め込みが未設定
  - Makefileで対応必要

