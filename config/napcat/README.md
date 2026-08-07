# NapCat 接入配置

## 方式一: 使用 WebUI 配置 (推荐)

1. 启动: `docker compose --profile onebot up -d`
2. 打开 `http://<IP>:6099` (NapCat WebUI), 登录后扫码登录 QQ
3. 在网络配置中**新建 WebSocket 客户端 (反向 WS)**:
   - 地址: `ws://zhenxun:8080/onebot/v11/ws`
   - 令牌: 与 `ONEBOT_ACCESS_TOKEN` 保持一致 (未设置则留空)

## 方式二: 预置配置文件

将 `onebot11.json.example` 复制为 `onebot11_<你的QQ号>.json` 并放到 NapCat 配置卷:

```bash
docker cp config/napcat/onebot11.json.example zhenxun-napcat:/app/napcat/config/onebot11_123456789.json
docker compose --profile onebot restart napcat
```

或直接修改宿主机 NapCat 配置目录 (若使用 bind mount):

```bash
mkdir -p napcat-config
cp config/napcat/onebot11.json.example napcat-config/onebot11_123456789.json
# 修改 url 中的令牌与 QQ 号
docker compose --profile onebot up -d
```

> 注意: 容器内 `zhenxun` 即 Bot 服务名, 反向 WS 地址为 `ws://zhenxun:8080/onebot/v11/ws`
