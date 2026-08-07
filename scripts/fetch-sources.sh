#!/usr/bin/env bash
# 预取 zhenxun-org 源码到 sources/ (构建镜像用, 避免每次构建都 clone)
#
# 用法:
#   ./scripts/fetch-sources.sh                        # 默认 main 分支
#   ZHENXUN_REF=v0.2.4-fix3 ./scripts/fetch-sources.sh  # 指定版本
#   FRESH=1 ./scripts/fetch-sources.sh                # 强制重新拉取
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCES_DIR="${FRAMEWORK_DIR}/sources"

ZHENXUN_REPO="${ZHENXUN_REPO:-zhenxun-org/zhenxun_bot}"
ZHENXUN_REF="${ZHENXUN_REF:-main}"
PLUGINS_REPO="${PLUGINS_REPO:-zhenxun-org/zhenxun_bot_plugins}"
PLUGINS_REF="${PLUGINS_REF:-main}"
RESOURCES_REPO="${RESOURCES_REPO:-zhenxun-org/zhenxun-bot-resources}"
RESOURCES_REF="${RESOURCES_REF:-main}"

mkdir -p "${SOURCES_DIR}"

fetch_repo() {
  local repo="$1" ref="$2" dir="$3"
  local target="${SOURCES_DIR}/${dir}"
  if [ "${FRESH:-0}" = "1" ]; then
    rm -rf "${target}"
  fi
  if [ -d "${target}" ] && [ -n "$(ls -A "${target}" 2>/dev/null)" ]; then
    echo "[fetch] 已存在 ${dir}, 跳过 (FRESH=1 可强制更新)"
    return
  fi
  echo "[fetch] 克隆 ${repo}@${ref} -> sources/${dir}"
  git clone --depth 1 --branch "${ref}" "https://github.com/${repo}.git" "${target}"
  rm -rf "${target}/.git"
}

fetch_repo "${ZHENXUN_REPO}" "${ZHENXUN_REF}" "zhenxun_bot"
fetch_repo "${PLUGINS_REPO}" "${PLUGINS_REF}" "zhenxun_bot_plugins"
fetch_repo "${RESOURCES_REPO}" "${RESOURCES_REF}" "zhenxun-bot-resources"

echo "[fetch] 完成:"
du -sh "${SOURCES_DIR}"/* 2>/dev/null || true
