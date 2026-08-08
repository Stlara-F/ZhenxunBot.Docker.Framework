#!/usr/bin/env python3
"""Zhenxun Docker Framework 启动引导脚本

职责(以 root 运行, 在 supervisord 拉起 Bot 前执行):
  1. 根据环境变量生成 /app/zhenxun/.env.dev (NoneBot 配置入口)
  2. 按需生成/合并 data/configs/plugins2config.yaml 中的 web-ui 账号密码
     (WebUI 登录必须存在 username/password, 未设置时自动生成临时密码并输出)
  3. 若使用 PostgreSQL, 等待数据库就绪
  4. 按 ZHENXUN_UID / ZHENXUN_GID 修正数据目录属主
"""

from __future__ import annotations

import json
import os
import secrets
import shutil
import socket
import sys
import time
import urllib.parse
from pathlib import Path

PROJECT_ROOT = Path(os.environ.get("ZHENXUN_HOME", "/app/zhenxun"))
ENV_DEV = PROJECT_ROOT / ".env.dev"
CONFIG_YAML = PROJECT_ROOT / "data" / "configs" / "plugins2config.yaml"

# ---------------------------------------------------------------------------
# 1. .env.dev 生成
# ---------------------------------------------------------------------------

# 默认值: 与 zhenxun_bot/.env.example 保持一致, HOST 改为 0.0.0.0 以支持容器端口映射
ENV_DEFAULTS: dict[str, str] = {
    "SUPERUSERS": '[""]',
    "COMMAND_START": '[""]',
    "SESSION_RUNNING_EXPRESSION": "别急呀,小真寻要休眠机哒?QAQ",
    "NICKNAME": '["真寻", "小真寻", "绪山真寻", "小寻子"]',
    "SESSION_EXPIRE_TIMEOUT": "00:00:30",
    "ALCONNA_USE_COMMAND_START": "True",
    "IMAGE_TO_BYTES": "True",
    "SELF_NICKNAME": "小真寻",
    "QBOT_ID_DATA": "{}",
    "DB_URL": "",
    "CACHE_MODE": "MEMORY",
    "REDIS_HOST": "127.0.0.1",
    "REDIS_PORT": "6379",
    "REDIS_PASSWORD": "",
    "REDIS_EXPIRE": "600",
    "SYSTEM_PROXY": "",
    "PLATFORM_SUPERUSERS": "{}",
    "DRIVER": "~fastapi+~httpx+~websockets",
    "HOST": "0.0.0.0",
    "PORT": "8080",
    "EXT_PATH": "[]",
    "QQ_ADAPTER_LOAD": "False",
}

# 可选键: 仅当环境变量已设置时才写入
OPTIONAL_ENV_KEYS = (
    "ONEBOT_ACCESS_TOKEN",
    "LOG_LEVEL",
    "REDIS_EXPIRE",
)


def _json_or_default(env_key: str, default: str) -> str:
    """读取 JSON 型环境变量, 非法 JSON 回退默认值"""
    raw = os.environ.get(env_key)
    if not raw:
        return default
    try:
        json.loads(raw)
        return raw
    except json.JSONDecodeError:
        print(f"[bootstrap] 警告: 环境变量 {env_key} 不是合法 JSON, 已忽略 (值: {raw})", file=sys.stderr)
        return default


def build_db_url() -> str:
    """从 DB_* 环境变量组装 postgres 连接串"""
    user = os.environ.get("DB_USER", "zhenxun")
    password = os.environ.get("DB_PASSWORD", "zhenxun")
    host = os.environ.get("DB_HOST", "db")
    port = os.environ.get("DB_PORT", "5432")
    name = os.environ.get("DB_NAME", "zhenxun")
    return f"postgres://{user}:{password}@{host}:{port}/{name}"


def render_env_dev() -> str:
    lines: list[str] = []

    def put(key: str, value: str) -> None:
        lines.append(f"{key}={value}")

    # 必填键: 环境变量优先, 否则默认值
    for key, default in ENV_DEFAULTS.items():
        if key in ("SUPERUSERS", "COMMAND_START", "NICKNAME", "PLATFORM_SUPERUSERS"):
            put(key, _json_or_default(key, default))
        elif key == "DB_URL":
            put(key, os.environ.get("DB_URL") or build_db_url())
        elif key == "CACHE_MODE":
            value = os.environ.get("CACHE_MODE", default).upper()
            if value not in ("NONE", "MEMORY", "REDIS"):
                print(f"[bootstrap] 警告: CACHE_MODE={value} 无效, 使用 MEMORY", file=sys.stderr)
                value = "MEMORY"
            put(key, value)
        else:
            put(key, os.environ.get(key, default))

    # Chromium 渲染参数: Docker 内必须禁用沙箱, 并规避 /dev/shm 过小问题
    put("htmlrender_browser_args", os.environ.get("HTMLRENDER_BROWSER_ARGS", "--no-sandbox --disable-dev-shm-usage"))

    # 可选键
    for key in OPTIONAL_ENV_KEYS:
        if os.environ.get(key) is not None:
            put(key, os.environ[key])

    return "\n".join(lines) + "\n"


def write_env_dev() -> None:
    ENV_DEV.parent.mkdir(parents=True, exist_ok=True)
    ENV_DEV.write_text(render_env_dev(), encoding="utf-8")
    print("[bootstrap] 已生成 .env.dev")


# ---------------------------------------------------------------------------
# 2. web-ui 配置播种
# ---------------------------------------------------------------------------

def _load_yaml(path: Path):
    """ruamel 加载; 不可用时回退为普通 dict (仅用于合并)"""
    try:
        from ruamel.yaml import YAML
        yaml = YAML()
        yaml.preserve_quotes = True
        data = {}
        if path.exists():
            with open(str(path), 'r', encoding='utf-8') as fh:
                data = yaml.load(fh)
        return data if isinstance(data, dict) else {}, yaml
    except Exception:
        return {}, None


def seed_webui_config() -> None:
    """确保 plugins2config.yaml 存在 web-ui 模块且包含账号密码"""
    username = os.environ.get("WEBUI_USERNAME", "admin")
    password = os.environ.get("WEBUI_PASSWORD", "")
    secret = os.environ.get("WEBUI_SECRET", "")

    if not password:
        password = secrets.token_urlsafe(12)
        print(f"[bootstrap] WebUI 未设置 WEBUI_PASSWORD, 已生成临时密码: {password} (请尽快在 WebUI/配置中修改)")
    if not secret:
        secret = secrets.token_urlsafe(32)

    if CONFIG_YAML.exists():
        data, yaml = _load_yaml(CONFIG_YAML)
        if yaml is None:
            print("[bootstrap] 警告: 无法解析已有 plugins2config.yaml (ruamel 不可用), 跳过 web-ui 播种", file=sys.stderr)
            return
    else:
        data, yaml = {}, None

    module = data.setdefault("web-ui", {})
    module.setdefault("USERNAME", {"value": username, "help": "前端管理用户名", "default_value": "admin"})
    module.setdefault("PASSWORD", {"value": password, "help": "前端管理密码", "default_value": None})
    module.setdefault("SECRET", {"value": secret, "help": "JWT密钥", "default_value": None})

    CONFIG_YAML.parent.mkdir(parents=True, exist_ok=True)
    if yaml is not None:
        with open(str(CONFIG_YAML), 'w', encoding='utf-8') as fh:
            yaml.dump(data, fh)
    else:
        CONFIG_YAML.write_text(_dump_plain_yaml(data), encoding="utf-8")
    print("[bootstrap] 已就绪 WebUI 登录配置 (data/configs/plugins2config.yaml)")


def _dump_plain_yaml(data: dict) -> str:
    """ruamel 不可用时的极简 YAML 序列化 (仅覆盖本脚本写入的结构)"""
    lines = []
    for module, configs in data.items():
        lines.append(f"{module}:")
        if not isinstance(configs, dict):
            continue
        for key, item in configs.items():
            lines.append(f"  {key}:")
            if not isinstance(item, dict):
                continue
            for k, v in item.items():
                if v is None:
                    lines.append(f"    {k}: null")
                elif isinstance(v, str):
                    lines.append(f"    {k}: {json.dumps(v, ensure_ascii=False)}")
                else:
                    lines.append(f"    {k}: {json.dumps(v, ensure_ascii=False)}")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# 3. 数据库等待
# ---------------------------------------------------------------------------

def db_host_port(db_url: str) -> tuple[str, str] | None:
    """从 DB_URL 提取 postgres 主机与端口"""
    parsed = urllib.parse.urlparse(db_url)
    if parsed.scheme not in ("postgres", "postgresql"):
        return None
    if not parsed.hostname:
        return None
    return parsed.hostname, str(parsed.port or 5432)


def wait_for_db() -> None:
    if os.environ.get("DB_WAIT", "1") == "0":
        return
    db_url = os.environ.get("DB_URL") or build_db_url()
    target = db_host_port(db_url)
    if target is None:
        return
    host, port = target
    timeout = int(os.environ.get("DB_WAIT_TIMEOUT", "120"))
    deadline = time.monotonic() + timeout
    last_err: Exception | None = None
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((host, int(port)), timeout=5):
                print(f"[bootstrap] 数据库已就绪: {host}:{port}")
                return
        except OSError as e:
            last_err = e
            time.sleep(2)
    print(f"[bootstrap] 错误: 等待数据库 {host}:{port} 超时 ({timeout}s): {last_err}", file=sys.stderr)
    if os.environ.get("DB_WAIT_FATAL", "1") == "1":
        sys.exit(1)


# ---------------------------------------------------------------------------
# 3.5 word_clouds 分词器池 patch (异步化 + 降池, 降低启动阻塞与内存)
# ---------------------------------------------------------------------------

def patch_wordclouds_segmenter() -> None:
    """幂等 patch: 分词器池 on_startup 同步初始化会联网下载 pkuseg 模型并
    阻塞 uvicorn 启动 (日志可见 5 分钟阻塞); 改为后台异步初始化并把池大小
    5 -> 2, 显著降低启动时间与内存占用"""
    target = (
        PROJECT_ROOT
        / "zhenxun"
        / "plugins"
        / "word_clouds"
        / "utils"
        / "segmenter_pool.py"
    )
    if not target.exists():
        print("[bootstrap] 未找到 word_clouds 分词器池, 跳过 patch")
        return
    s = target.read_text(encoding="utf-8")
    orig = s
    s = s.replace("POOL_SIZE = 5", "POOL_SIZE = 2")
    s = s.replace(
        "@driver.on_startup\nasync def _():\n    await segmenter_pool.initialize()",
        "@driver.on_startup\nasync def _():\n    asyncio.create_task(segmenter_pool.initialize())",
    )
    if s != orig:
        target.write_text(s, encoding="utf-8")
        print("[bootstrap] 已 patch word_clouds 分词器池: 异步初始化 + 池大小 5->2")
    else:
        print("[bootstrap] word_clouds 分词器池已是目标状态")


# ---------------------------------------------------------------------------
# 4. 目录属主
# ---------------------------------------------------------------------------

def fix_ownership() -> None:
    if os.environ.get("CHOWN_DIRS", "1") == "0":
        return
    uid = int(os.environ.get("ZHENXUN_UID", "1000"))
    gid = int(os.environ.get("ZHENXUN_GID", "1000"))
    def _chown_recursive(path: Path, what: str) -> None:
        # 递归修正属主: 仅 chown 目录本身会导致子文件仍为 root,
        # 非 root 运行的 zhenxun 进程无法写入 (如 data/configs/plugins2config.yaml)
        try:
            for root_dir, dirs, files in os.walk(path):
                for d in dirs:
                    shutil.chown(os.path.join(root_dir, d), user=uid, group=gid)
                for f in files:
                    shutil.chown(os.path.join(root_dir, f), user=uid, group=gid)
                shutil.chown(root_dir, user=uid, group=gid)
        except (OSError, AttributeError) as e:
            # 非 root 运行或平台不支持时仅警告, 不阻塞启动
            print(f"[bootstrap] 警告: 无法修正 {what} 属主: {e}", file=sys.stderr)

    for sub in ("data", "log", "resources", "zhenxun/plugins"):
        path = PROJECT_ROOT / sub
        if path.exists():
            _chown_recursive(path, sub)
    if ENV_DEV.exists():
        try:
            shutil.chown(ENV_DEV, user=uid, group=gid)
        except (OSError, AttributeError) as e:
            print(f"[bootstrap] 警告: 无法修正 .env.dev 属主: {e}", file=sys.stderr)
    print(f"[bootstrap] 已修正数据目录属主为 {uid}:{gid}")


def main() -> None:
    write_env_dev()
    seed_webui_config()
    wait_for_db()
    patch_wordclouds_segmenter()
    fix_ownership()
    print("[bootstrap] 引导完成")


if __name__ == "__main__":
    main()
