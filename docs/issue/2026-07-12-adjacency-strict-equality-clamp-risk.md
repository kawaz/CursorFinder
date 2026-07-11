---
title: Adjacency の接触判定が厳密一致 (==) で実機の -0.02px clamp を落とす懸念
status: open
category: bug
created: 2026-07-12T02:28:32+09:00
last_read:
open_entered: 2026-07-12T02:28:32+09:00
wip_entered:
blocked_entered:
pending_entered:
discarded_entered:
resolved_entered:
discard_reason:
pending_reason:
close_reason:
blocked_by:
origin: DR-0011 Fable レビュー指摘 n-15
---

# Adjacency の接触判定が厳密一致 (==) で実機の -0.02px clamp を落とす懸念

## 概要

`Core/Sources/LaserGuideCore/Adjacency.swift` の `detectOSPassSegments` は隣接辺の接触判定を厳密一致 (`==`) で行っている。実機観測では max 側境界が -0.02px ずれる clamp 挙動があり、clamp 済み座標が混入する経路があると隣接検出を落とす可能性がある。

`WaveLayout` (DR-0011) は同種の問題を避けるため `eps=0.5px` の許容判定を別実装した (`WaveLayout.swift` のコメントに対比記載あり)。

**注記**: これは部外者レビュー (Fable) 由来のフラグであり断定ではない。裏取りしてから採否を決めること。

## 背景

DR-0011 の Fable レビュー指摘 n-15 に由来する懸念。`detectOSPassSegments` の入力座標がどの経路 (CGDisplayBounds 直読みのみか、clamp 済み座標が混入しうるか) から来ているかによって、この懸念の妥当性が変わる。

## 受け入れ条件

- [ ] `detectOSPassSegments` の入力経路を監査し、以下いずれかの結論を出す:
  - (1) CGDisplayBounds 直読みのみで clamp 済み座標が混入しないなら「懸念なし」として close
  - (2) clamp 済み座標が混入しうるなら、`WaveLayout` の eps=0.5px 判定との共通化を設計する

## TODO

- [ ] `detectOSPassSegments` への入力座標の由来を追跡 (呼び出し元を遡る)
- [ ] clamp 混入経路の有無を確認 (実機 or コードパス解析)
- [ ] 混入しうる場合、eps 判定の共通化方針を検討 (WaveLayout.swift の実装を参照)
