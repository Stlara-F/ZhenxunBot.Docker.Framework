# syntax=docker/dockerfile:1
# check=skip=SecretsUsedInArgOrEnv
#
# Zhenxun Docker Framework
# ============================================================================
# 绪山真寻 Bot (zhenxun-org/zhenxun_bot) 的 Linux Docker 运行框架
#
# 结构参考 SnowLuma.Docker.Framework:
#   - 预取源码到 sources/ (scripts/fetch-sources.sh), 或由 prepare 阶段按 ARG 自动 clone
#   - 镜像内以 supervisord 管理 zhenxun 进程, start.sh 负责配置注入与数据库等待
#   - 多架构: linux/amd64 + linux/arm64
#
# 构建:
#   ./scripts/build-image.sh                      # amd64 load 到本地
#   PLATFORM=linux/arm64 ./scripts/build-image.sh # arm64
#   PUSH=1 IMAGE=xxx/xxx:tag ./scripts/build-image.sh
# ============================================================================

ARG PYTHON_VERSION=3.11

# ---------------------------------------------------------------------------
# prepare: 汇总 zhenxun_bot / 官方插件 / UI 主题资源
# 优先使用 sources/ 下已预取的源码; 缺失时按 ARG 自动 git clone
# ---------------------------------------------------------------------------
FROM python:${PYTHON_VERSION}-slim-bookworm AS prepare

ARG ZHENXUN_REPO=zhenxun-org/zhenxun_bot
ARG ZHENXUN_REF=main
ARG PLUGINS_REPO=zhenxun-org/zhenxun_bot_plugins
ARG PLUGINS_REF=main
ARG RESOURCES_REPO=zhenxun-org/zhenxun-bot-resources
ARG RESOURCES_REF=main

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY sources/ /sources/

RUN set -eux; \
    if [ ! -d /sources/zhenxun_bot ]; then \
      git clone --depth 1 --branch "${ZHENXUN_REF}" "https://github.com/${ZHENXUN_REPO}.git" /sources/zhenxun_bot; \
    fi; \
    if [ ! -d /sources/zhenxun_bot_plugins ]; then \
      git clone --depth 1 --branch "${PLUGINS_REF}" "https://github.com/${PLUGINS_REPO}.git" /sources/zhenxun_bot_plugins; \
    fi; \
    if [ ! -d /sources/zhenxun-bot-resources ]; then \
      git clone --depth 1 --branch "${RESOURCES_REF}" "https://github.com/${RESOURCES_REPO}.git" /sources/zhenxun-bot-resources; \
    fi; \
    rm -rf /sources/zhenxun_bot/.git \
           /sources/zhenxun_bot_plugins/.git \
           /sources/zhenxun-bot-resources/.git

# ---------------------------------------------------------------------------
# runtime: 运行环境
# ---------------------------------------------------------------------------
FROM python:${PYTHON_VERSION}-slim-bookworm AS runtime

ARG TARGETARCH
ARG PYTHON_VERSION

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    UV_PROJECT_ENVIRONMENT=/app/zhenxun/.venv \
    PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers \
    ZHENXUN_HOME=/app/zhenxun \
    ZHENXUN_UID=1000 \
    ZHENXUN_GID=1000 \
    PATH="/app/zhenxun/.venv/bin:/usr/local/bin:/usr/bin:/bin"

# 基础运行库:
#   - git / ca-certificates / curl : 插件商店、自动更新、健康检查
#   - ffmpeg                         : 语音/视频相关插件
#   - 字体 (noto emoji + 文泉驿)      : 图片渲染中文与 emoji
#   - playwright chromium 依赖        : htmlrender 渲染服务
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      ffmpeg \
      fontconfig \
      fonts-noto-color-emoji \
      fonts-wqy-zenhei \
      git \
      libasound2 \
      libatk-bridge2.0-0 \
      libatk1.0-0 \
      libcups2 \
      libgbm1 \
      libgl1 \
      libglib2.0-0 \
      libgtk-3-0 \
      libnss3 \
      libxcomposite1 \
      libxkbcommon0 \
      libxrandr2 \
      procps \
      supervisor \
      tzdata \
 && echo "${TZ}" > /etc/timezone \
 && ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime \
 && fc-cache -fv \
 && mkdir -p /etc/supervisor/conf.d \
 && groupadd --gid "${ZHENXUN_GID}" zhenxun \
 && useradd --no-log-init --uid "${ZHENXUN_UID}" --gid "${ZHENXUN_GID}" \
      --create-home --shell /bin/bash zhenxun \
 && rm -rf /var/lib/apt/lists/*

# uv (Python 包管理器)
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

WORKDIR /app/zhenxun

# 先复制依赖声明文件, 利用 Docker layer cache
COPY --from=prepare /sources/zhenxun_bot/pyproject.toml ./pyproject.toml
COPY --from=prepare /sources/zhenxun_bot/uv.lock ./uv.lock

# 安装依赖 (frozen 锁定版本; no-install-project 暂不安装项目本体)
RUN uv sync --frozen --no-install-project --no-dev

# 复制 zhenxun_bot 全部源码
COPY --from=prepare /sources/zhenxun_bot ./

# 安装项目本体 (editable) 并保证 venv 与锁文件一致
RUN uv sync --frozen --no-dev

# Playwright + Chromium (htmlrender 渲染服务), --with-deps 自动补齐系统依赖
# 浏览器安装到 /opt/pw-browsers 并授权 zhenxun 用户, 避免非 root 运行时无权限
RUN uv run playwright install --with-deps chromium \
 && chown -R zhenxun:zhenxun /opt/pw-browsers \
 && rm -rf /var/lib/apt/lists/* /tmp/* /root/.cache

# 官方插件 -> zhenxun/plugins (空卷首次挂载时会自动回填到卷内)
COPY --from=prepare /sources/zhenxun_bot_plugins/plugins/ ./zhenxun/plugins/

# UI 主题资源 -> resources/themes (zhenxun-bot-resources, 仓库根目录为 themes/)
COPY --from=prepare /sources/zhenxun-bot-resources/themes/ ./resources/themes/

# 框架文件: 进程管理 + 启动引导
COPY supervisord.conf /etc/supervisord.conf
COPY start.sh /usr/local/bin/start.sh
COPY scripts/bootstrap.py /usr/local/bin/zhenxun-bootstrap.py
RUN chmod +x /usr/local/bin/start.sh

# 数据目录 (后续由 start.sh 按 ZHENXUN_UID/GID 修正属主)
RUN mkdir -p data log resources \
 && chown -R zhenxun:zhenxun /app/zhenxun

VOLUME ["/app/zhenxun/data", "/app/zhenxun/resources", "/app/zhenxun/log", "/app/zhenxun/zhenxun/plugins"]

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/start.sh"]
