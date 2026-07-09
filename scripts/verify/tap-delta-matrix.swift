#!/usr/bin/env swift
//
// DR-0006 検証: CGEventTap で mouseMoved の location / deltaX / deltaY を
// 10 秒間記録し、加速度適用前後・クランプ持続中・エッジちょうどかの
// 意味論を観測するためのマトリクスダンプ。
//
// 実行: swift scripts/verify/tap-delta-matrix.swift
//
// 権限: アクセシビリティ権限 (CGEventTap の listen) が必要。
// 初回実行時は「システム設定 > プライバシーとセキュリティ > アクセシビリティ」
// に実行バイナリ (Terminal.app または swift 自体) を許可する必要がある。
// 権限が無い場合、イベントタップは作成できるが実際にはコールバックが
// 呼ばれない (silent failure) ことがあるため、実行者は以下の手順で確認する:
//
//   1. ターミナルで `swift scripts/verify/tap-delta-matrix.swift` を実行
//   2. 起動後 10 秒以内にマウスを動かし、特に画面の端 (モニタの境界) に
//      向かって押し付けるように動かす (エッジクランプの挙動を見るため)
//   3. 「システム設定 > プライバシーとセキュリティ > アクセシビリティ」で
//      Terminal (または実行している端末アプリ) が許可されているか確認。
//      未許可の場合、初回実行時にダイアログが出るのでそこで許可し、
//      再実行する
//   4. 10 秒経過後、記録された event 数と内容が表示される。0 件のままなら
//      権限が下りていない可能性が高い
//

import Cocoa
import CoreGraphics

var eventLog: [String] = []
var eventCount = 0

let eventMask = (1 << CGEventType.mouseMoved.rawValue)

func eventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .mouseMoved {
        eventCount += 1
        let location = event.location // CG座標系 (グローバル, y-down)
        let deltaX = event.getDoubleValueField(.mouseEventDeltaX)
        let deltaY = event.getDoubleValueField(.mouseEventDeltaY)
        // unacceleratedPointerMovement 相当のフィールドは公開APIでは
        // CGEventField として存在しないため、deltaX/deltaY (加速度適用後の
        // 値と観測されている) のみを記録する。存在有無自体もこの検証の対象。
        let ts = Date().timeIntervalSince1970
        let line = String(
            format: "#%04d t=%.3f loc=(%.2f,%.2f) deltaX=%.3f deltaY=%.3f",
            eventCount, ts, location.x, location.y, deltaX, deltaY
        )
        eventLog.append(line)
        if eventCount <= 5 || eventCount % 20 == 0 {
            print(line)
        }
    }
    return Unmanaged.passRetained(event)
}

print("=== CGEventTap delta マトリクス検証 (DR-0006) ===")
print("10 秒間 mouseMoved イベントを記録します。マウスを動かし、特に画面端に押し付けてください。\n")

guard let eventTap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .listenOnly,
    eventsOfInterest: CGEventMask(eventMask),
    callback: eventCallback,
    userInfo: nil
) else {
    print("CGEventTap 作成失敗。アクセシビリティ権限が付与されていない可能性が高い。")
    print("システム設定 > プライバシーとセキュリティ > アクセシビリティ で実行アプリ (Terminal 等) を許可してください。")
    exit(1)
}

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: eventTap, enable: true)

let deadline = Date().addingTimeInterval(10.0)
while Date() < deadline {
    CFRunLoopRunInMode(.defaultMode, 0.1, true)
}

CGEvent.tapEnable(tap: eventTap, enable: false)

print("\n=== 記録終了 ===")
print("総イベント数: \(eventCount)")
if eventCount == 0 {
    print("イベントが 1 件も記録されませんでした。アクセシビリティ権限が付与されていないか、")
    print("マウスが動かされなかった可能性があります。")
} else {
    print("\n--- 全記録 (末尾20件) ---")
    for line in eventLog.suffix(20) {
        print(line)
    }
}
