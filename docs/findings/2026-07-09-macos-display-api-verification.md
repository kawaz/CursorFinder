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

### 4. delta 意味論マトリクス — kawaz の手動実行で観測完了 (2026-07-09)

`swift scripts/verify/tap-delta-matrix.swift` を kawaz が Terminal で実機実行 (659 イベント記録、実出力はセッションログ参照)。構成: 内蔵 2056x1329 (CG y=0..1329) + LG 3440x1440 (CG origin (-258,-1440) = 内蔵の**上**に配置、上下隣接あり)。

**4a. クランプ時の location は「min 側 = 境界値ちょうど、max 側 = 境界値 − 0.02px」**

```
左エッジ押し付け:   loc=(0.00, 690.05)    ← x=0.00 ちょうど (min 側)
右エッジ押し付け:   loc=(2055.98, 1294.62) ← x = 2056 − 0.02 (max 側)
下エッジ押し付け:   loc=(..., 1328.98)     ← y = 1329 − 0.02 (max 側)
LG 上エッジ押し付け: loc=(..., -1440.00)    ← y=-1440 ちょうど (min 側)
```

含意: BX 検出の「エッジ上」判定は `==` 不可、**ε 許容 (0.1px 程度) の近傍判定**にする。max 側の 0.02px インセットは Retina (scale 2.0) の内蔵でも scale 1.0 の LG と同じ値だったため、backingScale 由来ではない (由来不明、値は環境依存の可能性ありとして ε で吸収する)。

**4b. クランプ持続中も delta は流れ続け、符号は外向きを正しく保つ**

```
#0640-0647 (LG 上エッジに押し付け続け):
loc.y=-1440.00 固定のまま deltaY=-86, -75, -27, -56, -47, -16, -32, -25 と流れ続ける
右エッジ: loc.x=2055.98 固定のまま deltaX=+45 (外向き正)
```

含意: (1) DR-0006 の「方向判定は delta 符号のみに依存」契約は**実機で成立** (2) クランプ中も大きさが押し込み強度を反映して流れるため、**BP 速度推定器の入力として delta の大きさが使える** (加速度適用前後の別は未分離だが、単調な強度プロキシとしては十分)

**4c. 越境 (PX) は location の不連続ジャンプとして観測される**

内蔵 (y>0) → LG (y<0) の通過が連続イベント間の loc 跳びで見え、所属ディスプレイ変化による PX 検出が成立する。

### 4-旧. 初回の自動実行が 0 件だった件 (解決済み)

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

## 未検証項目

- **delta の加速度適用前後の分離**: クランプ中の delta が「加速度適用後の点単位」か「生カウント」かは未分離 (OS のポインタ速度設定を変えた比較が必要)。DR-0006 の契約 (方向 = 符号のみ、BP 強度 = 単調プロキシ) には影響しないため優先度低。`unacceleratedPointerMovement` 相当の公開 CGEventField は存在しないことを確認済み
- **CGDisplayScreenSize = 0 / serial = 0 の実機**: この検証機では再現せず。プロジェクタ・古い外部モニタ・仮想ディスプレイ (Sidecar 等) 接続時に `swift scripts/verify/dump-displays.swift` を再実行して蓄積する
- **max 側クランプの 0.02px インセットの由来と環境依存性**: 別解像度・別 OS バージョンでの再測定で ε 設計 (現在 0.1px 想定) の妥当性を確認する
