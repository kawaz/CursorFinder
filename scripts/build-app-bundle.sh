#!/usr/bin/env bash
# build-app-bundle.sh — SPM ビルド成果物から LaserGuide.app を組み立てる (DR-0010).
#
# 使い方:
#   scripts/build-app-bundle.sh [--version <VERSION>] [--identity <IDENTITY>] [--output <DIR>] [--skip-build]
#
# フラグ:
#   --version   Info.plist の __VERSION__ 置換値 (既定: dev-<git short>)
#   --identity  codesign identity ("-" = ad-hoc、既定は環境変数 APPLE_SIGNING_IDENTITY か "-")
#              identity 指定時は --options runtime --timestamp を明示付与 (notarize 前提)。
#              ad-hoc ("-") 時はローカル検証用として付与しない
#   --output    出力ディレクトリ (既定: build/app)。既存があれば削除して再生成
#   --skip-build  swift build を実行せず、既存の .build 成果物を使う (CI で重複実行時)
#
# 出力: <output>/LaserGuide.app 一式 + `codesign --verify --deep --strict` の実行
#
# 前提:
#   - App/Package.swift の product `laserguide-dev` (実行ファイル名は build 側の設定に従う)
#   - resources: [.copy("Resources/calibration")] の SPM リソースバンドルを含む
#   - macOS の codesign が使える環境
#
# CD workflow (`.github/workflows/cd-auto-release-and-deploy.yml`) はこのスクリプトを
# APPLE_SIGNING_IDENTITY を渡して呼び出し、成果物を notarytool submit → stapler staple する。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${REPO_ROOT}/App"
BUILD_DIR_DEFAULT="${REPO_ROOT}/build/app"
INFO_PLIST_TEMPLATE="${REPO_ROOT}/scripts/Info.plist.template"

VERSION=""
IDENTITY="${APPLE_SIGNING_IDENTITY:-}"
OUTPUT_DIR="${BUILD_DIR_DEFAULT}"
SKIP_BUILD=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)   VERSION="$2"; shift 2 ;;
    --identity)  IDENTITY="$2"; shift 2 ;;
    --output)    OUTPUT_DIR="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=true; shift ;;
    -h|--help)
      grep -E '^#( |$)' "$0" | sed -e 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  git_sha="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  VERSION="dev-${git_sha}"
fi

if [[ -z "$IDENTITY" ]]; then
  IDENTITY="-"  # ad-hoc
fi

APP_NAME="LaserGuide"
APP_BUNDLE="${OUTPUT_DIR}/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"

echo "[build-app-bundle] version=${VERSION} identity=${IDENTITY} output=${OUTPUT_DIR}"

# 1. swift build (release)
if [[ "$SKIP_BUILD" != "true" ]]; then
  echo "[build-app-bundle] swift build -c release --package-path App"
  ( cd "$APP_DIR" && swift build -c release )
fi

# 2. ビルド成果物の場所を検出
BIN_PATH="$(cd "$APP_DIR" && swift build -c release --show-bin-path)"
EXECUTABLE_SRC="${BIN_PATH}/laserguide-dev"
if [[ ! -x "$EXECUTABLE_SRC" ]]; then
  echo "[build-app-bundle] executable not found: $EXECUTABLE_SRC" >&2
  exit 1
fi

# SPM resource bundle: LaserGuideDev_LaserGuideDev.bundle (Swift 5.9 の命名規則)
RESOURCE_BUNDLE_SRC=""
for candidate in \
  "${BIN_PATH}/LaserGuideDev_LaserGuideDev.bundle" \
  "${BIN_PATH}/LaserGuideDev_LaserGuideDev.resources"; do
  if [[ -d "$candidate" ]]; then
    RESOURCE_BUNDLE_SRC="$candidate"
    break
  fi
done
if [[ -z "$RESOURCE_BUNDLE_SRC" ]]; then
  echo "[build-app-bundle] resource bundle not found in $BIN_PATH" >&2
  echo "  (期待: LaserGuideDev_LaserGuideDev.bundle または .resources)" >&2
  ls -la "$BIN_PATH" >&2
  exit 1
fi

# 3. .app バンドル構造を再生成
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# 4. 実行ファイルを配置 (CFBundleExecutable=LaserGuide にリネーム)
cp "$EXECUTABLE_SRC" "${MACOS_DIR}/${APP_NAME}"
chmod 755 "${MACOS_DIR}/${APP_NAME}"

# 5. calibration リソースを Contents/Resources 直下へコピー (Bundle.main 経路)
# CalibrationWindowController.calibrationIndexURL() は Bundle.main.resourceURL の直下に
# `calibration/index.html` を探す。
if [[ -d "${RESOURCE_BUNDLE_SRC}/calibration" ]]; then
  cp -R "${RESOURCE_BUNDLE_SRC}/calibration" "${RESOURCES_DIR}/"
else
  echo "[build-app-bundle] calibration/ が resource bundle に無い: $RESOURCE_BUNDLE_SRC" >&2
  ls -la "$RESOURCE_BUNDLE_SRC" >&2
  exit 1
fi

# 6. Info.plist を template から生成
if [[ ! -f "$INFO_PLIST_TEMPLATE" ]]; then
  echo "[build-app-bundle] template not found: $INFO_PLIST_TEMPLATE" >&2
  exit 1
fi
sed -e "s/__VERSION__/${VERSION}/g" "$INFO_PLIST_TEMPLATE" > "${CONTENTS}/Info.plist"
plutil -lint "${CONTENTS}/Info.plist" >/dev/null

# 7. PkgInfo (APPL????) を配置 (macOS 側の慣習、無くても動くが Cask 互換で入れる)
printf 'APPL????' > "${CONTENTS}/PkgInfo"

# 8. codesign
echo "[build-app-bundle] codesign --sign ${IDENTITY}"
CODESIGN_OPTS=()
if [[ "$IDENTITY" != "-" ]]; then
  # Developer ID identity: notarize が Hardened Runtime + secure timestamp を要求する
  CODESIGN_OPTS+=(--options runtime --timestamp)
fi
# ad-hoc (identity="-") はローカル検証用途、Hardened Runtime を付けても意味が無いので付けない。
# `${arr[@]+...}` は bash 3.2 (macOS /bin/bash) の「set -u + 空配列 = unbound variable」対策
codesign --force --sign "$IDENTITY" ${CODESIGN_OPTS[@]+"${CODESIGN_OPTS[@]}"} "$APP_BUNDLE"

# 9. 検証
echo "[build-app-bundle] codesign --verify --deep --strict"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "[build-app-bundle] built: $APP_BUNDLE"
