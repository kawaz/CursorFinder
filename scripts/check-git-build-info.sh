#!/bin/bash

echo "=== ビルド時に取得できるGit情報 ==="
echo ""

# ブランチ名
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
echo "【ブランチ】"
echo "git rev-parse --abbrev-ref HEAD"
echo "  結果: $BRANCH"
echo ""

# コミットハッシュ（短縮版）
SHORT_SHA=$(git rev-parse --short HEAD 2>/dev/null)
echo "【コミットハッシュ（短縮）】"
echo "git rev-parse --short HEAD"
echo "  結果: $SHORT_SHA"
echo ""

# コミットハッシュ（完全版）
FULL_SHA=$(git rev-parse HEAD 2>/dev/null)
echo "【コミットハッシュ（完全）】"
echo "git rev-parse HEAD"
echo "  結果: $FULL_SHA"
echo ""

# コミット日時
COMMIT_DATE=$(git log -1 --format=%cI 2>/dev/null)
echo "【コミット日時】"
echo "git log -1 --format=%cI"
echo "  結果: $COMMIT_DATE"
echo ""

# タグ（HEADが正確にタグを指している場合）
TAG_EXACT=$(git describe --tags --exact-match 2>/dev/null)
echo "【タグ（正確一致）】"
echo "git describe --tags --exact-match"
echo "  結果: $TAG_EXACT"
echo "  （タグがない場合はエラー）"
echo ""

# タグ（最も近いタグからの距離）
TAG_DESCRIBE=$(git describe --tags --always 2>/dev/null)
echo "【タグ（最も近い）】"
echo "git describe --tags --always"
echo "  結果: $TAG_DESCRIBE"
echo "  （例: v1.2.3-5-g5e06c9a = タグv1.2.3から5コミット先、ハッシュg5e06c9a）"
echo ""

# Dirtyチェック（未コミットの変更）
if [ -n "$(git status --porcelain)" ]; then
    DIRTY="-dirty"
else
    DIRTY=""
fi
echo "【Dirtyチェック】"
echo "git status --porcelain"
echo "  未コミット変更: $( [ -n \"$DIRTY\" ] && echo \"あり\" || echo \"なし\" )"
echo ""

# 推奨される組み合わせ
echo "【推奨されるビルド情報】"
echo "appVersion: $TAG_DESCRIBE または 1.2.3（Info.plistから）"
echo "gitCommit: $SHORT_SHA$DIRTY"
echo "gitCommitFull: $FULL_SHA"
echo "gitBranch: $BRANCH"
echo "gitTag: $TAG_EXACT （存在する場合）"
echo "gitCommitDate: $COMMIT_DATE"
echo "buildDate: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
