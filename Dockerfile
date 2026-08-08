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
ARG WEBUI_REPO=zhenxun-org/zhenxun_bot_webui
ARG WEBUI_DIST_REF=dist

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
    if [ ! -d /sources/zhenxun_bot_webui_dist ]; then \
      git clone --depth 1 --branch "${WEBUI_DIST_REF}" "https://github.com/${WEBUI_REPO}.git" /sources/zhenxun_bot_webui_dist; \
    fi; \
    rm -rf /sources/zhenxun_bot/.git \
           /sources/zhenxun_bot_plugins/.git \
           /sources/zhenxun-bot-resources/.git \
           /sources/zhenxun_bot_webui_dist/.git

# 下载 pkuseg web 分词模型 (word_clouds 词云用, 避免运行期联网下载阻塞启动)
RUN python3 - <<'PY'
import pathlib, urllib.request, zipfile
url = "https://github.com/lancopku/pkuseg-python/releases/download/v0.0.16/web.zip"
dest = pathlib.Path("/sources/pkuseg_web")
dest.mkdir(parents=True, exist_ok=True)
zip_path = "/tmp/pkuseg_web.zip"
urllib.request.urlretrieve(url, zip_path)
with zipfile.ZipFile(zip_path) as z:
    z.extractall(dest)
print("pkuseg model files:", sorted(x.name for x in dest.iterdir()))
PY

# 记录上游版本到镜像元数据
RUN python - <<'PY'
import pathlib, tomllib
root = pathlib.Path("/sources/zhenxun_bot")
try:
    ver = tomllib.loads((root / "pyproject.toml").read_text())["project"]["version"]
except Exception:
    ver = "unknown"
pathlib.Path("/tmp/zhenxun_version").write_text(ver)
print(f"zhenxun_bot version: {ver}")
PY

# ---------------------------------------------------------------------------
# runtime: 运行环境
# ---------------------------------------------------------------------------
FROM python:${PYTHON_VERSION}-slim-bookworm AS runtime

LABEL org.opencontainers.image.title="Zhenxun Docker Framework" \
      org.opencontainers.image.description="绪山真寻 Bot (zhenxun-org) 的 Linux Docker 运行框架 / 后端 Bot 框架" \
      org.opencontainers.image.source="https://github.com/Stlara-F/ZhenxunBot.Docker.Framework" \
      org.opencontainers.image.vendor="zhenxun-org" \
      org.opencontainers.image.licenses="AGPL-3.0"

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
    PATH="/app/zhenxun/.venv/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# 基础运行库:
#   - git / ca-certificates / curl : 插件商店、自动更新、健康检查
#   - ffmpeg                         : 语音/视频相关插件
#   - 字体 (noto emoji + 文泉驿)      : 图片渲染中文与 emoji
#   - playwright chromium 依赖        : htmlrender 渲染服务
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      gcc \
      libffi-dev \
      libssl-dev \
      python3-dev \
      curl \
      ffmpeg \
      libavcodec-extra \
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
      passwd \
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

# 安装官方插件依赖: 聚合各插件 requirements.txt + 补充已知缺失依赖
# (bym_ai: tomli; jmcomic_downloader: jmcomic/pyminizip/pikepdf)
# 单个依赖失败仅警告, 不影响镜像构建与其他插件
RUN set -eux; \
    reqs="$(find zhenxun/plugins -mindepth 2 -maxdepth 2 -name requirements.txt 2>/dev/null | sort)"; \
    if [ -n "${reqs}" ]; then \
      args=""; for f in ${reqs}; do args="${args} -r ${f}"; done; \
      echo "安装插件依赖: ${args}"; \
      uv pip install --python /app/zhenxun/.venv/bin/python ${args} \
        || echo "[warn] 部分插件依赖安装失败, 对应插件将不可用"; \
    fi; \
    uv pip install --python /app/zhenxun/.venv/bin/python \
      tomli jmcomic pyminizip pikepdf \
      || echo "[warn] 补充插件依赖安装失败"

# 完整资源包 -> resources/ (font/image/record/themes/__version__)
# 满足 resources.spec 版本要求(>=1.1.1)与 check_resources_exists(font 非空),
# 启动时不再触发阿里云资源下载
COPY --from=prepare /sources/zhenxun-bot-resources/ ./resources/

# 预置 WebUI 前端资源 -> data/web_ui/public (zhenxun_bot_webui dist 分支)
# check_webui_exists() 为真则跳过启动时的网络克隆, 保证离线可用
COPY --from=prepare /sources/zhenxun_bot_webui_dist/ ./data/web_ui/public/

# Patch 前端 API 地址为同源: 上游默认 http://localhost:8080, 远程部署时
# 登录请求会发到访问者本机导致 CORS/连接失败; 改为 window.location.origin
# 后按实际访问地址同源请求 (含 WebSocket), 端口由访问地址自动决定
RUN python3 - <<'PY'
import pathlib
count = 0
for js in pathlib.Path("data/web_ui/public/js").glob("*.js"):
    s = js.read_text(encoding="utf-8")
    if "http://localhost" in s:
        s = s.replace('wi="http://localhost"', 'wi=window.location.origin')
        s = s.replace('xi=()=>Ai()+":"+bi()', 'xi=()=>Ai()')
        js.write_text(s, encoding="utf-8")
        count += 1
        print(f"patched webui: {js.name}")
print(f"total patched files: {count}")
PY

# 预置 pkuseg 分词模型 (word_clouds 词云), 避免启动时联网下载
COPY --from=prepare /sources/pkuseg_web/ /home/zhenxun/.pkuseg/web/
RUN chown -R zhenxun:zhenxun /home/zhenxun/.pkuseg

# 框架文件: 进程管理 + 启动引导
COPY supervisord.conf /etc/supervisord.conf
COPY start.sh /usr/local/bin/start.sh
COPY scripts/bootstrap.py /usr/local/bin/zhenxun-bootstrap.py
RUN chmod +x /usr/local/bin/start.sh

# 数据目录 (后续由 start.sh 按 ZHENXUN_UID/GID 修正属主)
RUN mkdir -p data log resources \
 && chown -R zhenxun:zhenxun /app/zhenxun

# 上游版本元数据
COPY --from=prepare /tmp/zhenxun_version /app/VERSION

VOLUME ["/app/zhenxun/data", "/app/zhenxun/resources", "/app/zhenxun/log", "/app/zhenxun/zhenxun/plugins"]

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/start.sh"]
