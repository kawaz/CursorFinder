# LaserGuide justfile (v3 SPM 構成)
#
# 開発の check / push ゲート + DR-0010 の .app バンドル組み立て動線。
# リリース CD (cd-auto-release-and-deploy.yml, main push トリガ) は独立で走る。

set shell := ["bash", "-euo", "pipefail", "-c"]

# default behaviour: alias for `list`
default: list

# show the recipe list
list:
    @just --list --unsorted

# ---------- atomic ----------

# Core (幾何 + store 純関数層) のテスト
test-core:
    cd Core && swift test --parallel

# App (executable + runtime) のテスト
test-app:
    cd App && swift test --parallel

# 全パッケージのテスト
test: test-core test-app

# SwiftLint --strict (DR-0010 §6 の config、リポルート .swiftlint.yml が正本)
lint:
    swiftlint --strict

# CI entry point (lint + tests)
ci: lint test

# ---------- build ----------

# DR-0010: SPM 成果物から LaserGuide.app を組み立てる (ad-hoc 署名、ローカル検証用)。
# 実 identity 署名は CD workflow で APPLE_SIGNING_IDENTITY 経由で行う。
build-app:
    scripts/build-app-bundle.sh

# 開発用 CLI 実行 (SPM 直、.app にはしない。docs/runbooks/v3-dev-run.md 参照)
run:
    cd App && swift run laserguide-dev

# ---------- gates ----------

# working tree is clean
[private]
ensure-clean:
    test -z "$(git status --porcelain)" || { git status --short; echo "working tree is not clean"; exit 1; }

# ---------- push ----------

# feature ブランチを origin へ push (ci + clean ゲート)。main は CD が動くため専用経路 (未整備) を使う
[script]
push-wip: ensure-clean ci
    branch=$(git rev-parse --abbrev-ref HEAD)
    if [ "$branch" = "main" ]; then
        echo "main への push はリリース CD (cd-auto-release-and-deploy.yml) が動くため push-wip では行わない"
        exit 1
    fi
    git push -u origin "$branch"

# main へのリリース push (ci + clean ゲート)。main push はリリース CD が発火する
# (最新 tag からの auto bump + tag + GH Release + Cask 更新) = 実行はリリース判断そのもの
[script]
push: ensure-clean ci
    git push origin HEAD:main
    echo "[push] main へ push しました。CD (cd-auto-release-and-deploy.yml) の watch を推奨"
