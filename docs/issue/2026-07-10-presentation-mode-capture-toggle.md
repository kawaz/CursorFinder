---
title: プレゼンテーションモード (キャプチャ表示トグル + クリック可視化サークル)
status: idea
category: request
created: 2026-07-10T11:21:55+09:00
last_read:
open_entered:
wip_entered:
blocked_entered:
pending_entered:
discarded_entered:
resolved_entered:
discard_reason:
pending_reason:
close_reason:
blocked_by:
origin: kawaz発案
---

# プレゼンテーションモード (キャプチャ表示トグル + クリック可視化サークル)

## 概要

通常はオーバーレイ window を画面キャプチャから除外している (`sharingType=.none`、v1 由来の完成品設定)。ただしリモートミーティングの画面共有でレーザーポインタ表現を見せたいユースケースがある。

メニューに「プレゼンテーションモード」トグルを追加し、on のとき:

1. 全オーバーレイ window の `sharingType` を `.readOnly` に切替 (画面キャプチャに映る状態にする)
2. クリック/mousedown 中にカーソル周囲へ半透明サークルを描画 (NSEvent global monitor で mouseDown/mouseUp を購読、Action として形式化)

## 背景

現状のオーバーレイは常にキャプチャ非対象。リモートミーティング等でレーザー操作を画面共有相手に見せたい場面に対応できていない。

## 受け入れ条件

- [ ] メニューに「プレゼンテーションモード」トグルが追加されている
- [ ] トグル on で全オーバーレイ window の `sharingType` が `.readOnly` に切り替わる
- [ ] トグル on 中、mousedown 中はカーソル周囲に半透明サークルが描画される
- [ ] NSEvent global monitor による mouseDown/mouseUp 購読が Action として形式化されている

## TODO

<!-- wip 時のみ -->

## 実装タイミング

calib-ui ワークストリーム完了後に着手する (AppDelegate 周りの競合を避けるため)。
