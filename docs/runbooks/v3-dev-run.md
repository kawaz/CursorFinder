# v3 開発用アプリの起動手順

`swift run laserguide-dev` で立ち上げる開発用の常駐アプリ。メニューバーに `LG` として現れ、
各ディスプレイに透明オーバーレイを張ってレーザーを描画し、CGEventTap 経由で仮想境界ワープを実行する。
リリース用 xcodeproj への配線は別タスク。

## 前提

- macOS 13 以上 (SPM manifest で `.macOS(.v13)`)
- Swift 5.9 以上 (`swift --version` で確認)
- アクセシビリティ権限を Terminal (もしくは起動元プロセス) に付与する必要あり

## ビルドと起動

```
cd App
swift build             # 依存の Core も同時にビルドされる
swift run laserguide-dev
```

初回起動時、AXIsProcessTrustedWithOptions(prompt=true) がシステムダイアログを出す。
承認後は `swift run laserguide-dev` を打ち直すと通常経路で立ち上がる。

### アクセシビリティ権限の付与

システム設定 → プライバシーとセキュリティ → アクセシビリティ で、
「Terminal」もしくは実際に `swift run` を打っている親プロセス (iTerm2 / VS Code 等) をトグル ON する。
権限が取れていないと:

- CGEventTap が起動できず、**レーザー描画のみモード**にフォールバック (仮想境界ワープは動かない)
- 起動ログに tap 失敗が現れる (`applicationDidFinishLaunching` 内で判定)

## メニューバー操作

| メニュー項目 | 挙動 |
|---|---|
| Warp: on / off | CGEventTap の有効/無効トグル。off でもレーザー描画は継続 |
| Quit LaserGuide (dev) | 終了 |

## 動作確認観点

- **レーザー描画**: マウスを動かすと各ディスプレイに、そのディスプレイの 4 隅から
  カーソルへ伸びるレーザーが描画される。加えて他ディスプレイの 4 隅からの延長線も
  現ディスプレイに現れる (物理 mm 空間で計算しているため)。
- **継ぎ目の直線連続性**: 上下・左右で隣接する 2 モニタを跨がる線が、継ぎ目で
  折れずに一続きに見える (両モニタの pose が整合していれば厳密一致、Phase 1 は各モニタ
  独立 mm 空間なので継ぎ目連続性はキャリブレーション UI 実装後に整う)。
- **PB (仮想通過ブロック) は未設定**: userSegments が空なので発火しない。上下隣接
  モニタ間の OS 自動 pass のみ有効。
- **LG↔内蔵の PP ワープ**: LG (上) と内蔵 (下) が上下隣接している構成では、継ぎ目を跨がる
  マウス移動で通過が期待どおり行われる (通常の OS 挙動を阻害せず流す)。
- **Warp トグル**: メニューバーで off にすると mouseMoved の tap 経路が停止する
  (レーザーは NSEvent monitor 経由の fallback へ切り替わらないので描画は止まる、Phase 2 課題)。

## 既知の制約 (Phase 1)

- 永続化 (persist effect) は NSLog 出力のみ。UserDefaults 経路は Phase 2。
- 実行中の権限失効検知は起動時判定のみ (tap callback 経由での剥奪検知は Phase 2)。
- ディスプレイ構成変更時、overlay を全部作り直す (差分更新は Phase 2)。
- キャリブレーション UI・設定 UI は無い (WebView 経路は別タスク)。
- CGDisplayScreenSize=0 のモニタ (プロジェクタ等) では fallback 110dpi を暫定使用するが、
  UI 上の警告表示は Phase 2。
