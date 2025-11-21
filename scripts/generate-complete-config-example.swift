#!/usr/bin/env swift

import Cocoa

// 簡易的なJSON生成（見やすく整形）
func prettyJSON(_ obj: Any, indent: Int = 0) -> String {
    let ind = String(repeating: "  ", count: indent)
    let ind2 = String(repeating: "  ", count: indent + 1)

    if let dict = obj as? [String: Any] {
        var lines: [String] = ["{"]
        let sortedKeys = dict.keys.sorted()
        for (i, key) in sortedKeys.enumerated() {
            let value = dict[key]!
            let comma = i < sortedKeys.count - 1 ? "," : ""

            if let subDict = value as? [String: Any] {
                lines.append("\(ind2)\"\(key)\": \(prettyJSON(subDict, indent: indent + 1))\(comma)")
            } else if let arr = value as? [Any] {
                lines.append("\(ind2)\"\(key)\": \(prettyJSON(arr, indent: indent + 1))\(comma)")
            } else if let str = value as? String {
                lines.append("\(ind2)\"\(key)\": \"\(str)\"\(comma)")
            } else if let num = value as? Double {
                lines.append("\(ind2)\"\(key)\": \(num)\(comma)")
            } else if let num = value as? Int {
                lines.append("\(ind2)\"\(key)\": \(num)\(comma)")
            } else if let bool = value as? Bool {
                lines.append("\(ind2)\"\(key)\": \(bool)\(comma)")
            } else {
                lines.append("\(ind2)\"\(key)\": \(value)\(comma)")
            }
        }
        lines.append("\(ind)}")
        return lines.joined(separator: "\n")
    } else if let arr = obj as? [Any] {
        if arr.isEmpty {
            return "[]"
        }
        // シンプルな配列は1行で
        if arr.count <= 2 && arr.allSatisfy({ $0 is Double || $0 is Int }) {
            let values = arr.map { "\($0)" }.joined(separator: ", ")
            return "[\(values)]"
        }
        if arr.count == 2 && arr.allSatisfy({ $0 is [Double] || $0 is [Int] }) {
            // [[x,y], [w,h]] 形式
            let innerArrays = arr.map { prettyJSON($0, indent: 0) }.joined(separator: ", ")
            return "[\(innerArrays)]"
        }
        var lines: [String] = ["["]
        for (i, item) in arr.enumerated() {
            let comma = i < arr.count - 1 ? "," : ""
            lines.append("\(ind2)\(prettyJSON(item, indent: indent + 1))\(comma)")
        }
        lines.append("\(ind)]")
        return lines.joined(separator: "\n")
    }

    return "\(obj)"
}

print("=== LaserGuide v2 設定例（LG右下→内蔵右上ワープ） ===\n")
print("【シナリオ】")
print("- 内蔵ディスプレイ top: 全域からLGへ移動可能")
print("- LG bottom: 左側（0〜344.2mm）は内蔵全域へ、右側（344.2mm〜）は内蔵右上へワープ")
print("")

// === 保存用モデル ===

let configExample: [String: Any] = [
    "configurationKey": "config_1552-41041-4251086178_3456x2234+7789-40587-480315_3440x1440",
    "metadata": [
        "created": "2025-11-20T23:00:00Z",
        "modified": "2025-11-20T23:00:00Z"
    ],
    "displays": [
        [
            "id": "builtin-uuid",
            "hardware": [
                "fingerprint": "1552-41041-4251086178_3456x2234",
                "displayID": 1,
                "vendorID": 1552,
                "modelID": 41041,
                "serialNumber": 4251086178
            ],
            "coordinates": [
                "logical": [
                    "position": [0.0, 0.0],
                    "size": [3456.0, 2234.0],
                    "visibleFrame": [[0.0, 0.0], [3456.0, 2164.0]],
                    "safeAreaInsets": ["top": 64.0, "left": 0.0, "bottom": 0.0, "right": 0.0]
                ],
                "physical": [
                    "position": [0.0, 0.0],
                    "size": [344.2, 222.5],
                    "visibleFrame": [[0.0, 0.0], [344.2, 215.5]],
                    "safeAreaInsets": ["top": 6.37, "left": 0.0, "bottom": 0.0, "right": 0.0]
                ]
            ],
            "display": [
                "isMain": true,
                "isBuiltIn": true,
                "name": "Built-in Display",
                "resolution": [
                    "points": [3456.0, 2234.0],
                    "pixels": [3456.0, 2234.0],
                    "backingScaleFactor": 1.0,
                    "ppi": 255.0
                ],
                "refreshRate": 120.0
            ],
            "visual": [
                "colorSpaceName": "NSCalibratedRGBColorSpace",
                "colorSpaceLocalizedName": "Color LCD",
                "bitsPerSample": 8,
                "colorDepth": 520,
                "hdrMaxValue": 1.0,
                "hdrMaxPotentialValue": 16.0,
                "hdrMaxReferenceValue": 0.0
            ]
        ],
        [
            "id": "lg-uuid",
            "hardware": [
                "fingerprint": "7789-40587-480315_3440x1440",
                "displayID": 5,
                "vendorID": 7789,
                "modelID": 40587,
                "serialNumber": 480315
            ],
            "coordinates": [
                "logical": [
                    "position": [0.0, 2234.0],
                    "size": [3440.0, 1440.0],
                    "visibleFrame": [[0.0, 2234.0], [3440.0, 1440.0]],
                    "safeAreaInsets": ["top": 0.0, "left": 0.0, "bottom": 0.0, "right": 0.0]
                ],
                "physical": [
                    "position": [0.0, 222.5],
                    "size": [1052.7, 440.7],
                    "visibleFrame": [[0.0, 222.5], [1052.7, 440.7]],
                    "safeAreaInsets": ["top": 0.0, "left": 0.0, "bottom": 0.0, "right": 0.0]
                ]
            ],
            "display": [
                "isMain": false,
                "isBuiltIn": false,
                "name": "LG ULTRAGEAR+",
                "resolution": [
                    "points": [3440.0, 1440.0],
                    "pixels": [3440.0, 1440.0],
                    "backingScaleFactor": 1.0,
                    "ppi": 83.0
                ],
                "refreshRate": 240.0
            ],
            "visual": [
                "colorSpaceName": "NSCalibratedRGBColorSpace",
                "colorSpaceLocalizedName": "LG ULTRAGEAR+",
                "bitsPerSample": 8,
                "colorDepth": 520,
                "hdrMaxValue": 1.0,
                "hdrMaxPotentialValue": 1.0,
                "hdrMaxReferenceValue": 0.0
            ]
        ]
    ],
    "navigation": [
        "passSegments": [
            [
                "id": "builtin-top-1",
                "displayId": "builtin-uuid",
                "side": "top",
                "logical": ["start": 0.0, "end": 3440.0],
                "physical": ["start": 0.0, "end": 342.6],
                "pairedSegmentId": "lg-bottom-1"
            ],
            [
                "id": "builtin-top-2",
                "displayId": "builtin-uuid",
                "side": "top",
                "logical": ["start": 3456.0, "end": 3456.0],
                "physical": ["start": 344.2, "end": 344.2],
                "pairedSegmentId": "lg-bottom-2"
            ],
            [
                "id": "lg-bottom-1",
                "displayId": "lg-uuid",
                "side": "bottom",
                "logical": ["start": 0.0, "end": 1125.0],
                "physical": ["start": 0.0, "end": 344.2],
                "pairedSegmentId": "builtin-top-1"
            ],
            [
                "id": "lg-bottom-2",
                "displayId": "lg-uuid",
                "side": "bottom",
                "logical": ["start": 1125.0, "end": 3440.0],
                "physical": ["start": 344.2, "end": 1052.7],
                "pairedSegmentId": "builtin-top-2"
            ]
        ]
    ]
]

print(prettyJSON(configExample))

print("\n\n=== 動作確認 ===\n")
print("1. 内蔵 x=1000px から LG へ")
print("   → builtin-top-1 に含まれる（0〜3440）")
print("   → 比率: 1000/3440 = 0.29")
print("   → LG: 0 + 0.29*(1125-0) = 326px")
print("")
print("2. LG x=2000px から内蔵へ")
print("   → lg-bottom-2 に含まれる（1125〜3440）")
print("   → 比率: (2000-1125)/(3440-1125) = 0.38")
print("   → 内蔵: 3456 + 0.38*(3456-3456) = 3456px（右端へワープ）")
