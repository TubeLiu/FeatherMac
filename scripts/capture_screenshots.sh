#!/usr/bin/env bash
# 重新生成 README 用的截图（英文 + 简体中文各一套）。
#
# 走的是应用内的 DocumentationScreenshotRunner：它会先铺一份演示数据再截图，
# 所以产出里没有真实的账号、路径或证书信息，可以安全地提交进公开仓库。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/FeatherMac.app/Contents/MacOS/FeatherMac"
DEFAULTS_DOMAIN="dev.feathermac.app"

cd "$ROOT"
[ -x "$APP" ] || { echo "先跑 scripts/package_app.sh 生成 dist/FeatherMac.app" >&2; exit 1; }

# 截图前的语言设置要还原，别把开发机的偏好改掉。
PREVIOUS_LANGUAGE="$(defaults read "$DEFAULTS_DOMAIN" FeatherMac.language 2>/dev/null || echo "")"
restore_language() {
  if [ -n "$PREVIOUS_LANGUAGE" ]; then
    defaults write "$DEFAULTS_DOMAIN" FeatherMac.language -string "$PREVIOUS_LANGUAGE"
  else
    defaults delete "$DEFAULTS_DOMAIN" FeatherMac.language 2>/dev/null || true
  fi
}
trap restore_language EXIT

capture() {
  local language="$1" outdir="$2"
  echo "Capturing $language -> $outdir"
  defaults write "$DEFAULTS_DOMAIN" FeatherMac.language -string "$language"
  rm -rf "$outdir"
  mkdir -p "$outdir"
  FEATHERMAC_SCREENSHOT_DIR="$outdir" "$APP"
}

# 语言值是 AppLanguage 的 rawValue（english / zhHans），不是 lproj 目录名。
capture "english" "$ROOT/docs/assets/screenshots/en"
capture "zhHans" "$ROOT/docs/assets/screenshots/zh-Hans"

echo "Done:"
ls -1 "$ROOT/docs/assets/screenshots/en" "$ROOT/docs/assets/screenshots/zh-Hans"
