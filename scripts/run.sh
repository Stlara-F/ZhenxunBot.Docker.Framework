#!/usr/bin/env bash
# 一键启动 Zhenxun 全栈 (compose: bot + postgres + redis)
#
# 用法:
#   ./scripts/run.sh
#   PROFILE=onebot ./scripts/run.sh        # 额外启动 NapCat QQ 客户端
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${FRAMEWORK_DIR}"

# 首次运行生成 .env
if [ ! -f ".env" ]; then
  echo "[run] 生成 .env (请编辑超级用户等配置后重新执行)"
  cp .env.example .env
  exit 0
fi

IMAGE="${ZHENXUN_IMAGE:-zhenxun/docker-framework:latest}"
if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  echo "[run] 镜像不存在, 开始构建..."
  "${SCRIPT_DIR}/build-image.sh"
fi

PROFILE_ARGS=()
if [ -n "${PROFILE:-}" ]; then
  PROFILE_ARGS=(--profile "${PROFILE}")
fi

docker compose "${PROFILE_ARGS[@]}" up -d
echo "[run] 已启动: docker compose logs -f zhenxun"
echo "[run] WebUI: http://127.0.0.1:${ZHENXUN_PORT:-8080}/"
