# LaserGuide justfile (v3 リライト用の最小構成)
#
# 既存のリリース CD (cd-auto-release-and-deploy.yml, main push トリガ) とは独立に、
# v3 開発の check / push ゲートだけを提供する。リリース経路の justfile 化は
# v3 が main を差し替えるタイミングで Makefile と統合する。

set shell := ["bash", "-euo", "pipefail", "-c"]

# default behaviour: alias for `list`
default: list

# show the recipe list
list:
    @just --list --unsorted

# ---------- atomic ----------

# Core (幾何 + store 純関数層) のテスト
test:
    cd Core && swift test

# CI entry point
ci: test

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

# main への push 経路は v3 が main を差し替える時に整備する
push:
    @echo "リリース経路は未整備 (v3 開発中は 'just push-wip' を使う)"; exit 1
