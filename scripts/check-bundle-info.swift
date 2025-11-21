#!/usr/bin/env swift

import Foundation

print("=== Bundle情報（アプリバージョン関連） ===\n")

// 実際のアプリから取得
let bundle = Bundle.main
let infoDictionary = bundle.infoDictionary ?? [:]

print("【Info.plistから取得できる情報】")

// バージョン関連
print("CFBundleShortVersionString: \(infoDictionary["CFBundleShortVersionString"] ?? "N/A")")
print("CFBundleVersion: \(infoDictionary["CFBundleVersion"] ?? "N/A")")
print("CFBundleIdentifier: \(infoDictionary["CFBundleIdentifier"] ?? "N/A")")
print("CFBundleName: \(infoDictionary["CFBundleName"] ?? "N/A")")

print("\n【その他の情報】")
for (key, value) in infoDictionary.sorted(by: { $0.key < $1.key }) {
    if key.contains("Version") || key.contains("Build") {
        print("\(key): \(value)")
    }
}

print("\n【Git情報（カスタムキー、設定すれば取得可能）】")
print("GitCommitSHA: \(infoDictionary["GitCommitSHA"] ?? "未設定")")
print("GitCommitDate: \(infoDictionary["GitCommitDate"] ?? "未設定")")
print("GitBranch: \(infoDictionary["GitBranch"] ?? "未設定")")
print("BuildDate: \(infoDictionary["BuildDate"] ?? "未設定")")

print("\n【推奨】")
print("- appVersion: CFBundleShortVersionString（例: \"1.2.3\"）")
print("- appBuildNumber: CFBundleVersion（例: \"42\" or \"1.2.3.42\"）")
print("- commitSHA（オプション）: ビルド時にInfo.plistに埋め込む")
print("- buildDate（オプション）: ビルド時にInfo.plistに埋め込む")
