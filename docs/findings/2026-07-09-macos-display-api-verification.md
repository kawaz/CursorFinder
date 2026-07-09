# macOS ディスプレイ API 実機検証 (DR-0005 / DR-0006)

検証機: kawaz の作業 Mac (Apple Silicon 内蔵ディスプレイ + 外部モニタ 1 台の 2 画面構成)。
実行コマンド: `swift scripts/verify/dump-displays.swift`

## 判明した事実

### 1. CG (y-down) と NSScreen (y-up) の座標変換式は理論通り、実測で一致

実出力:

```
=== ディスプレイ情報ダンプ (DR-0005 / DR-0006 検証) ===

アクティブディスプレイ数: 2

--- ディスプレイ #0 (CGDirectDisplayID = 1) ---
CGDisplayBounds (CG, y-down想定): origin=(0.0, 0.0), size=(2056.0, 1329.0)
CGDisplayIsMain: true
NSScreen.frame (y-up想定): origin=(0.0, 0.0), size=(2056.0, 1329.0)
NSScreen.backingScaleFactor: 2.0
NSScreen.localizedName: Built-in Retina Display
CGDisplayScreenSize (mm): width=344.7023050541138, height=222.81583823780025
CGDisplayPixelsWide/High (px): 2056 x 1329
導出 DPI (px幅 / mm幅 * 25.4): 151.50000227530174
CGDisplayVendorNumber: 1552 (0x610)
CGDisplayModelNumber: 41041 (0xa051)
CGDisplaySerialNumber: 4251086178
CGDisplayUnitNumber: 0

--- ディスプレイ #1 (CGDirectDisplayID = 2) ---
CGDisplayBounds (CG, y-down想定): origin=(-258.0, -1440.0), size=(3440.0, 1440.0)
CGDisplayIsMain: false
NSScreen.frame (y-up想定): origin=(-258.0, 1329.0), size=(3440.0, 1440.0)
NSScreen.backingScaleFactor: 1.0
NSScreen.localizedName: LG ULTRAGEAR+
CGDisplayScreenSize (mm): width=1052.7228757559535, height=440.67469217691075
CGDisplayPixelsWide/High (px): 3440 x 1440
導出 DPI (px幅 / mm幅 * 25.4): 83.00000124653495
CGDisplayVendorNumber: 7789 (0x1e6d)
CGDisplayModelNumber: 40587 (0x9e8b)
CGDisplaySerialNumber: 480315
CGDisplayUnitNumber: 1

--- 突合確認 ---
NSScreen.screens.count: 2
CGGetActiveDisplayList count: 2

main ディスプレイの NSScreen.frame.height: 1329.0 (y変換の基準値)
ディスプレイ#0: 実測 CG.y=0.0, 予測値 (mainHeight - nsY - height)=0.0, 一致=true
ディスプレイ#1: 実測 CG.y=-1440.0, 予測値 (mainHeight - nsY - height)=-1440.0, 一致=true
```

- 変換式 `cgY = mainHeight - nsY - height` (mainHeight = メインディスプレイの `NSScreen.frame.height`) が2画面とも1px未満の誤差で一致した。DR-0005 が前提とする「NSScreen (y-up) と CGDisplay (y-down) は既知の変換式で相互変換できる」という想定は、この実機構成 (上下ではなく左右+段違い配置) で成立することを確認した。
- ただし **サンプル数は 1 台の Mac、1 通りのモニタ配置 (横並び、段違い)** のみ。DR-0005 が要求する「上下隣接 2 枚構成」は未検証 (この検証機に上下配置のモニタ環境がない)。

### 2. CGDisplayScreenSize (mm) は両ディスプレイで取得でき、妥当な値だった

- 内蔵 Retina: 344.7mm × 222.8mm → 導出 DPI 151.5 (Retina 内蔵ディスプレイの実測既知値と整合的なオーダー)
- 外部 LG ULTRAGEAR+ (3440x1440 ウルトラワイド): 1052.7mm × 440.7mm → 導出 DPI 83.0 (34インチ級ウルトラワイドの実寸として妥当)
- 2台とも `CGDisplayScreenSize` が 0 を返すケースには遭遇しなかった。DR-0005 が懸念する「EDID 不備で 0 や不正値を返す」ケースはこの検証機では再現できず、**未検証** (プロジェクタ・古い/安価なモニタでの再検証が必要)。

### 3. Serial Number は両ディスプレイとも非ゼロ

- 内蔵: `CGDisplaySerialNumber = 4251086178`
- 外部: `CGDisplaySerialNumber = 480315`
- DR-0007 が懸念する「serial が 0 の機種」はこの検証機の2台では再現しなかった。**サンプル数 2、いずれも非ゼロという結果のみ**。EDID に serial を持たない機種 (特に安価な外部モニタやプロジェクタ) での再検証が必要。

### 4. CGEventTap の delta 検証は権限・環境の制約で未検証

実行コマンド: `swift scripts/verify/tap-delta-matrix.swift` (タイムアウト 12 秒で自動実行)

実出力:

```
=== CGEventTap delta マトリクス検証 (DR-0006) ===
10 秒間 mouseMoved イベントを記録します。マウスを動かし、特に画面端に押し付けてください。


=== 記録終了 ===
総イベント数: 0
イベントが 1 件も記録されませんでした。アクセシビリティ権限が付与されていないか、
マウスが動かされなかった可能性があります。
```

- `CGEvent.tapCreate` 自体は `nil` を返さず成功した (= 権限拒否の即時エラーにはならなかった)。
- しかし 10 秒間で記録されたイベントは 0 件だった。これは以下のいずれか、または両方が原因と考えられるが、**この自動実行環境からは切り分けられない**:
  - 自動実行 (Bash tool 経由、対話的なマウス操作を行うユーザがいない) だったため、そもそもマウスが動いていない
  - アクセシビリティ権限が実行プロセス (この場合 `swift` インタプリタを起動した親プロセス) に付与されていない
- **未検証項目**: delta の意味論 (加速度適用前後の値、量子化、エッジクランプ中の値、location がエッジ値ちょうどかクランプで1px内側か) はマウスの実操作が必須であり、この検証では取得できなかった。

## 実用的な示唆

- DR-0005 の CG/NSScreen 変換式は、少なくとも「横並び+段違い配置」の実機で式レベルの整合性が確認できた。ただし DR-0005 が明示的に要求する「上下隣接構成」でのテストは別途、上下配置が可能な検証環境 (モニタアーム等で縦積みにする、または該当構成を持つ別 Mac で実行) が必要。
- `CGDisplayScreenSize` は少なくとも Apple 純正 Retina + 主要メーカー製ウルトラワイドの組み合わせでは信頼できる値を返した。DR-0005 の「mm 取得不可時は仮定 DPI 110dpi でフォールバックし、UI 上で明示する」設計は、フォールバック分岐に到達しない環境が多い可能性を示唆する一方、フォールバック自体は実装しておくべき (この検証では反証されていない)。
- Serial Number の 0 値問題 (DR-0007) は、この検証機では発生しなかった。DR-0007 の実装判断において「serial=0 の実機」をどう入手するかが次の検証課題になる (中古の安価モニタ、プロジェクタ、仮想ディスプレイ (Sidecar/Luna Display 等) が候補)。

## 未検証項目 (権限・手動操作が必要な理由と手順)

### DR-0006 の delta 意味論マトリクス

`scripts/verify/tap-delta-matrix.swift` は作成済みだが、以下の理由で本検証では完了できなかった:

1. **アクセシビリティ権限**: `CGEventTap` で `.cgSessionEventTap` を listen するには、実行プロセス (Terminal.app 等) がシステム設定でアクセシビリティ権限を許可されている必要がある。この検証はサブエージェント経由の自動実行のため、GUI ダイアログでの許可操作ができない。
2. **マウスの実操作**: delta の意味論 (加速度適用前後・クランプ持続中・エッジちょうどの値) を観測するには、人間が実際にマウスを動かし、特に画面端に押し付ける操作が必要。自動実行では意味のあるイベントが発生しない。

**手動実行手順** (ユーザが Terminal で行う):

```bash
cd /Users/kawaz/.local/share/repos/github.com/kawaz/LaserGuide/wip-v3
swift scripts/verify/tap-delta-matrix.swift
```

実行後、10秒以内にマウスを動かす。特に画面の端 (モニタ境界) に向かって押し付けるように動かし、クランプ挙動を発生させる。初回実行時にアクセシビリティ権限のダイアログが出た場合は許可し、再実行する。出力される delta 値・location 値を基に、DR-0006 が要求する以下を確認する:

- location がエッジ値ちょうどか、1px 内側でクランプされるか
- deltaX/deltaY が加速度適用後の値か (画面解像度・OS のポインタ速度設定を変えて比較する必要あり、これも未検証)
- `unacceleratedPointerMovement` 相当のフィールドは `CGEventField` の公開 API には存在しないため、このスクリプトでは deltaX/deltaY のみ記録している (この点も DR-0006 の「一次資料が曖昧」という記述を裏付ける観測)
