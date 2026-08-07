#!/usr/bin/env bash
# Zhenxun Docker Framework 容器入口
# 以 root 启动: 配置注入 -> 数据库等待 -> 目录属主 -> supervisord 拉起 zhenxun
set -euo pipefail

TZ="${TZ:-Asia/Shanghai}"
export TZ

# 时区
if [ -f "/usr/share/zoneinfo/${TZ}" ]; then
  ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime
  echo "${TZ}" > /etc/timezone
fi

echo "[start] Zhenxun Docker Framework 启动中..."
echo "[start] 执行配置引导 (bootstrap)"

# 使用 venv 内 python 运行引导脚本 (ruamel 等依赖可用)
VENV_PY="${ZHENXUN_HOME:-/app/zhenxun}/.venv/bin/python"
if [ ! -x "${VENV_PY}" ]; then
  echo "[start] 错误: 未找到 ${VENV_PY}, 镜像可能不完整" >&2
  exit 1
fi

"${VENV_PY}" /usr/local/bin/zhenxun-bootstrap.py

echo "[start] 启动 supervisord (zhenxun)"
exec supervisord -c /etc/supervisord.conf
