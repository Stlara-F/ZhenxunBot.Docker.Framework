#!/usr/bin/env bash
# 本地构建 Zhenxun Docker 镜像 (单平台; 多架构请走 CI)
#
# 用法:
#   ./scripts/build-image.sh                              # amd64, load 到本地
#   PLATFORM=linux/arm64 ./scripts/build-image.sh         # arm64
#   PUSH=1 IMAGE=user/zhenxun:v0.2.4 ./scripts/build-image.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

IMAGE="${IMAGE:-zhenxun/docker-framework:latest}"
PUSH="${PUSH:-0}"
PLATFORM="${PLATFORM:-linux/amd64}"
ZHENXUN_REF="${ZHENXUN_REF:-main}"
PLUGINS_REF="${PLUGINS_REF:-main}"
RESOURCES_REF="${RESOURCES_REF:-main}"

if [ "${PUSH}" = "1" ] || [ "${PUSH}" = "true" ]; then
  OUTPUT="--push"
else
  OUTPUT="--load"
fi

case ",${PLATFORM}," in
  *,*,*) echo "PLATFORM 仅支持单平台 (linux/amd64 或 linux/arm64), 多架构请走 CI" >&2; exit 1 ;;
esac

# 确保源码就绪
"${SCRIPT_DIR}/fetch-sources.sh"

echo "[build] ${PLATFORM} -> ${IMAGE} (ZHENXUN_REF=${ZHENXUN_REF})"
docker buildx build \
  --platform "${PLATFORM}" \
  --build-arg "ZHENXUN_REF=${ZHENXUN_REF}" \
  --build-arg "PLUGINS_REF=${PLUGINS_REF}" \
  --build-arg "RESOURCES_REF=${RESOURCES_REF}" \
  --tag "${IMAGE}" \
  --file "${FRAMEWORK_DIR}/Dockerfile" \
  ${OUTPUT} \
  "${FRAMEWORK_DIR}"

echo "[build] 完成: ${IMAGE} (${PLATFORM})"
