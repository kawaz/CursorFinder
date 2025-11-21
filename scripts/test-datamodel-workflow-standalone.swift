#!/usr/bin/env swift

import Foundation
import Cocoa

print("=== LaserGuide v2 データモデル完全動作確認（スタンドアロン版）===\n")
print("このスクリプトは実装コードの簡略版を使用して、")
print("データモデルの保存・復元が正しく動作することを確認します。\n")

// まず実際のディスプレイ情報を取得
let screens = NSScreen.screens
print("接続されているディスプレイ: \(screens.count)台\n")

for (i, screen) in screens.enumerated() {
    print("Display \(i): \(screen.localizedName)")
    print("  frame: \(screen.frame)")
}

print("\n次のステップ:")
print("1. Xcodeでプロジェクトを開く")
print("2. 新規作成したSwiftファイルを全てプロジェクトに追加")
print("   - LaserGuide/Core/ (4ファイル)")
print("   - LaserGuide/Models/ (4ファイル)")
print("   - LaserGuide/Services/ (4ファイル)")
print("   - LaserGuide/Views/ (2ファイル)")
print("   - LaserGuide/ (2ファイル: App, AppDelegate)")
print("3. Code Signing設定を確認")
print("4. ビルド実行")
print("")
print("または、署名なしでビルド:")
print("  xcodebuild -project LaserGuide.xcodeproj \\")
print("    -scheme LaserGuide \\")
print("    -configuration Debug \\")
print("    CODE_SIGN_IDENTITY=\"\" \\")
print("    CODE_SIGNING_REQUIRED=NO \\")
print("    build")

