#!/usr/bin/env swift

import Cocoa

print("=== 'x' 統一形式のテスト ===\n")

let testCases: [(width: Int, height: Int, scale: CGFloat, name: String)] = [
    (3456, 2234, 1.0, "標準解像度"),
    (1728, 1117, 2.0, "Retina 2x"),
    (2304, 1489, 1.5, "スケーリング 1.5x"),
    (3840, 2160, 1.0, "4K標準"),
    (1920, 1080, 2.0, "4K Retina 2x")
]

print("【@x 形式】")
for test in testCases {
    let scale = test.scale != 1.0 ? "@\(test.scale)x" : ""
    let fingerprint = "\(test.width)x\(test.height)\(scale)"
    print("  \(fingerprint.padding(toLength: 20, withPad: " ", startingAt: 0)) ← \(test.name)")
}

print("\n【x 統一形式】")
for test in testCases {
    let scaleStr: String
    if test.scale.truncatingRemainder(dividingBy: 1) == 0 {
        scaleStr = "\(Int(test.scale))"
    } else {
        scaleStr = "\(test.scale)"
    }
    let fingerprint = "\(test.width)x\(test.height)x\(scaleStr)"
    print("  \(fingerprint.padding(toLength: 20, withPad: " ", startingAt: 0)) ← \(test.name)")
}

print("\n【結論】")
print("- @x形式: iOS/macOS開発者には馴染み深いが、特殊文字")
print("- x統一形式: シンプル、統一感、誤解のリスク低")
print("- 推奨: x統一形式")
