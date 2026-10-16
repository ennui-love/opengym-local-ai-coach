# openGym 自部署实例：把电脑上的本地大模型变成手机 App 的 AI 教练

一套**已验证跑通**的 openGym 自部署方案。核心目标只有一个：**让手机上的 openGym 用我自己电脑里跑的本地大模型当 AI 教练**，不花一分钱 API 费用，数据不出内网。

本仓库记录这套实例的配置、踩坑过程与运维手册。部署过程与排错日志见 [`logs/`](logs/)。

---

## 1. openGym 是什么

[openGym](https://github.com/DuarteSantos8/openGym) 是一个开源的健身训练管理应用（AGPL-3.0），提供两种形态：

| 形态 | 说明 |
|---|---|
| **安卓 App** | 官方 release 提供 APK（本次使用 `v1.4.1`，约 290 MB） |
| **自建服务器** | 官方 `docker-compose.yml`，两个容器：`api`（Node，passkey 认证 + 用户数据）+ `web`（React 前端 + nginx 反代） |

关键事实（决定了后面所有决策）：

- **安卓 App 自带「纯本地模式」**：首次启动可选 local mode，数据存在 App 私有目录，**完全不需要服务器**。非 AI 的进阶规则、1RM 估算、肌肉热力图在这个模式下都能用。
- **AI Coach（AI 教练）默认关闭，且只在自建服务器上运行**。它不内置模型，而是调用**你自己的** LLM provider —— 支持 Anthropic / OpenAI / Gemini / **OpenAI 兼容端点** / Ollama，其中 **LM Studio 是官方明确列出的 OpenAI 兼容端点**。
- 所以：**想要 AI 教练，就必须自建服务器**。这就是本项目的由来。

---

## 2. 最终成果

| 项 | 值 |
|---|---|
| 访问地址 | `https://<your-device>.<your-tailnet>.ts.net`（电脑与手机通用） |
| HTTPS 来源 | Tailscale Serve，Let's Encrypt 证书，自动续期 |
| 内网映射 | `127.0.0.1:8080` → 仅本机可访问，局域网设备连不上 |
| 模型 | LM Studio，`qwen3.5-9b-deepseek-v4-flash`（Q4_K_M，约 5.6 GB），监听 `127.0.0.1:1234` |
| 容器 | `opengym-api-1`、`opengym-web-1`，`restart: unless-stopped` |
| 服务暴露面 | **零公网暴露**，仅同一 tailnet 内的设备可访问 |

PC 端与手机端均已端到端验证通过：手机能在 `计划 → Coach` 里用本地 9B 模型生成完整周训练计划。

---

## 3. 架构与调用链

```
你的手机 / 浏览器
      │  HTTPS（仅你自己的 tailnet 内可访问）
      ▼
Tailscale Serve  ──>  本机 127.0.0.1:8080  ──>  Docker: openGym web + api
                                                        │
                                                        │ http（仅本机内部）
                                                        ▼
                                             LM Studio 127.0.0.1:1234
```

三点容易搞错的地方：

1. **手机永远不直连 LM Studio**。手机连的是 openGym 服务器，由服务器去调 LM Studio。所以 LM Studio 不需要公网、不需要证书。
2. **Tailscale 在这里同时承担两个角色**：给手机一条能访问到电脑私有服务的加密通道，以及提供一个**固定不变**的 HTTPS 域名。
3. **域名固定这一点是刚需**，不是锦上添花 —— WebAuthn 的 passkey 绑定在 origin 上，域名一变，已注册的 passkey 全部失效。临时隧道（如 `trycloudflare` quick tunnel）每次重启换域名，等于每次都要重新注册。详见 §6。

---

## 4. 复现步骤

### 4.1 前置：Windows 上的 Docker Desktop

本机从零装 Docker Desktop 时，依次撞了三道关卡，全部解决后 Docker 才起得来：

| 报错 | 处理 |
|---|---|
| `Virtual Machine Platform is not enabled` | 管理员 PowerShell：`Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform,Microsoft-Windows-Subsystem-Linux`，然后**完整重启 Windows**（只重启 Docker 不够） |
| `WSL needs updating` | 管理员 PowerShell：`wsl --update` |
| `Virtualization is disabled in firmware` | 进 BIOS/UEFI 打开硬件虚拟化（Intel VT-x / AMD SVM），软件层改不了 |

### 4.2 拉起 openGym 服务

```bash
cd <this-repo>/deploy
cp .env.example .env      # 按注释改 RP_ID / ORIGIN
docker compose pull
docker compose up -d
docker compose ps         # 两个容器都应 Up (healthy)
```

验证：

```bash
curl --noproxy '*' http://localhost:8080/            # 应返回 <title>openGym</title>
curl --noproxy '*' http://localhost:8080/api/health  # 应返回 {"ok":true,"users":0,...}
```

> `--noproxy '*'` 是必需的：本机代理会拦下 localhost 请求，返回 502。

### 4.3 LM Studio 侧

1. 加载模型，点 **Start Server**，保持监听 `127.0.0.1:1234`。
2. 验证：浏览器开 `http://127.0.0.1:1234/v1/models`，能看到模型列表 JSON 即正常。
3. 验证容器能连到它：

```bash
docker exec opengym-api-1 node -e "fetch('http://host.docker.internal:1234/v1/models').then(r=>r.text()).then(t=>console.log('OK',t.slice(0,120))).catch(e=>console.log('FAIL',e.message))"
```

**踩坑**：直接开 `http://127.0.0.1:1234/` 会返回 `{"error":"Unexpected endpoint or method. (GET /)"}` —— 这是**正常的**，根路径本来就不提供网页，不是故障。

**重要**：不需要把 LM Studio 绑到 `0.0.0.0`。实测 Docker Desktop（Windows/WSL2）会对 `host.docker.internal` 做宿主侧转发，容器能直接连到宿主机的 `127.0.0.1:1234`。保持只监听回环更安全。

### 4.4 Tailscale 侧

```bash
# 1. 先在 https://login.tailscale.com/admin/dns 开启 HTTPS Certificates（漏做这步会失败，见 §6）
tailscale cert <your-device>.<your-tailnet>.ts.net

# 2. 把本机 8080 挂上去（后台常驻）
tailscale serve --bg 8080

# 3. 确认
tailscale serve status
```

### 4.5 后台开启 AI Coach

浏览器开 `https://<your-device>.<your-tailnet>.ts.net` → **Settings → Account → Admin dashboard → AI Coach 卡片**（仅管理员可见）：

1. 打开卡片开关（Set up the Coach）
2. Provider 选 **OpenAI-compatible endpoint**
3. **Endpoint** 填 `http://host.docker.internal:1234`（裸主机名会自动补 `/v1`；不要带账号密码或查询参数）
4. **不用填 API key**（无 key 的兼容端点只填 endpoint 即视为 ready）
5. **List models** → 选你的模型
6. **Test the Coach**
7. ⚠️ 最后**打开卡片顶部的主开关** —— 只做 1~6 不生效，主开关关着时服务端会告诉所有 App「没有 Coach」

使用入口：**计划（Plan）→ 标题栏右上角按钮 → `Coach`**，首次进去有告知页 + 简短问卷。

### 4.6 手机接入

1. 手机装 **Tailscale**，用**同一个账号**登录，打开 VPN 开关。
2. 手机装 openGym APK。
3. 电脑浏览器：**Settings → Account → Pair the mobile app** → 得到配对地址 + 一次性 code。
4. 手机 openGym：**Settings → Account → Pair the mobile app** → 填地址和 code。
5. 手机：**Settings → AI Coach → Use my self-hosted openGym**。
6. 手机：**计划 → 右上角 → Coach**。

---

## 5. 三个关键设计决策

### 5.1 用 Tailscale Serve，而不是 Cloudflare 临时隧道

Cloudflare quick tunnel 免费，但**每次重启换域名**。而 passkey 绑定 origin —— 换域名 = 所有 passkey 失效 = 每次都要重新注册。Tailscale 提供固定的 `https://<device>.<tailnet>.ts.net`，一次配好长期有效，且**不对公网暴露端口**，只有你自己的 tailnet 内能访问。

### 5.2 web 端口只绑回环

官方 `docker-compose.yml` 默认是 `"${WEB_PORT}:${NGINX_PORT}"`，会监听 `0.0.0.0`，同局域网的任何设备都能直连。本项目改为：

```yaml
ports:
  - "127.0.0.1:${WEB_PORT:-8080}:${NGINX_PORT:-80}"
```

外部访问一律走 Tailscale 那条私有 HTTPS 通道（它从宿主 `127.0.0.1` 转发，不受影响）。

### 5.3 不用 coach 镜像

官方 compose 里 `api` 服务有个 `API_TARGET=coach` 的构建目标。但那只在需要内置 AI runtime 时才用；**LM Studio 属于 OpenAI 兼容端点，走 HTTP 调用，`default` 镜像就够了**。

---

## 6. 踩坑记录（按价值排序）

### 6.1 手机端「教练无法运行」的真根因 —— 上下文被并行槽切分

现象：手机端配对成功、能看到教练问候语，但生成计划时报「教练无法运行。需要实例所有者检查配置」。

排查路径：`data/coach.json` 的 `log` 字段给出了真实错误：

```json
{ "outcome": "failed", "errorClass": "provider", "ms": 42454,
  "detail": "the answer was cut off at the output limit; try a smaller plan or a bigger model" }
```

根因不在 openGym，在 **LM Studio 的加载参数**：模型以 `loaded_context_length=8192` + `PARALLEL=4` 加载，8192 的上下文被 4 个并行槽切分，**单次请求实际只有约 2048 token**。而教练的规则提示词本身就有数千 token —— 输出必然被截断。

修复：用 `lms` CLI 重载模型。

```bat
lms unload --all
lms load qwen3.5-9b-deepseek-v4-flash -c 16384 --parallel 1 -y
```

验证 `lms ps` 显示 `CONTEXT 16384 / PARALLEL 1`，直连 `/v1/chat/completions` 连续生成 3000 token 成功。

**两个坑**：
- `lms load` 对已加载的模型会生成 `:2` 后缀的新实例，而 openGym 配置的模型名不带后缀会命中旧实例 —— **必须先 `unload` 再 `load`**。
- **CLI 加载参数不持久**：LM Studio 重启后需重新运行脚本，或在 GUI 里把该模型的 Context Length 改成 16384 再加载。本仓库提供 [`deploy/reload-model-16k.bat`](deploy/reload-model-16k.bat)。

### 6.2 passkey 绑定 origin，换域名就得重新注册

WebAuthn 把凭证绑定到域名。从 `localhost` 切到 Tailscale 域名时，旧账号直接不可用。处理方式：

1. 先备份 `./data`
2. 只删除**账号相关**文件（`db.json`、`db.json.bak`、`state-<uid>.json`、`coach/<uid>.json`）
3. **保留** `coach.json`（AI Coach 全局配置）、`vapid.json`、`secret`、`audit.log` —— 这样不用重配教练
4. 重启容器，用新域名重新注册（首个注册者因 `FIRST_USER_ADMIN=1` 自动成为管理员）

### 6.3 `tailscale cert` 报 500

```
500 Internal Server Error: your Tailscale account does not support getting TLS certs
```

不是 bug，是 **HTTPS Certificates 没在管理后台开启**：https://login.tailscale.com/admin/dns → 拉到底 → HTTPS Certificates → Enable。

另外：`tailscale serve --bg` 在证书未开时会静默失败（exit 1），`serve reset` 却是 rc=0 —— 别被误导。

### 6.4 Git Bash 的 curl 不认 Tailscale 证书

证书是**真的 Let's Encrypt**（issuer `CN=YE1`，SAN 为 Tailscale 域名）。但 Git Bash 自带的 curl 不加载该系统证书链，所以：

- `curl https://<domain>/` → http 000
- `curl -k https://<domain>/` → http 200

浏览器和安卓系统默认信任，**不需要任何处理**。测通只需加 `-k`。

### 6.5 Docker Compose 会插值 `.env` 里的 `$`

`.env` 里写 `CF_CONNECTING_IP=$http_cf_connecting_ip`（官方 `.env.example` 的原样写法）会让 compose 把它当变量插值，产生 4 条 warning。改为 `CF_CONNECTING_IP=`（不使用 Cloudflare 时留空）。

### 6.6 桌面的部署文件夹不能删 —— 它是 live 数据目录

`docker-compose.yml` 里有 `./data:/data` 绑定挂载，容器内 `/data` 直接映射到宿主机那个文件夹。所以那个目录**不只是部署包，是正在运行的数据库本体**：

| 文件 | 内容 |
|---|---|
| `db.json` | 用户与 passkey |
| `state-<uid>.json` | 该用户的训练方案 |
| `coach.json` | AI Coach 全局配置与调用日志 |
| `secret` | passkey 签名密钥 |
| `vapid.json` | Web Push 密钥 |
| `audit.log` | 审计日志 |

删除 = 丢账号 + 丢计划 + 教练配置失效 + 容器重启变全新实例。

想搬家的话是安全的：`docker compose down` → 剪切整个文件夹 → 在新位置 `docker compose up -d`（相对路径 + 固定 `name: opengym`，数据不丢）。

> **本仓库不含任何 `data/` 内容。** `.gitignore` 已排除 `data/`、`backups/`、`.env`、`*.key`、`*.crt`。

### 6.7 安卓端两个实际障碍

- **Tailscale 在国内默认走 Google Play**，装不上。改用官方 APK 直链（`https://pkgs.tailscale.com/stable/tailscale-android-universal-<version>.apk`）。但首次登录仍需能打开 Google OAuth 授权页。
- **部分安卓厂商的激进省电管理会杀掉 Tailscale**（国产 ROM 尤其常见，VPN 类 App 易被后台清理）。表现为手机突然连不上服务器，而 PC 侧 `docker compose ps`、`tailscale status`、`tailscale serve status` 全部正常。根治：设置 → 应用 → Tailscale → 电池 → 关闭自动管理，勾选允许自启动 / 后台活动 / 关联启动；多任务界面锁定 Tailscale 卡片；设置 → 电池 → 更多 → 休眠时始终保持网络连接。

报错解码：`ERR_NAME_NOT_RESOLVED` = MagicDNS 未开；超时 = 隧道断了；`Connection refused` = 端口问题。

### 6.8 AI Coach 每天 10 次是内置限额

`coach.json` 里的 `caps.perProfileDaily: 10` 是 openGym 的默认每日上限，**不是模型或网络问题**。需要调整改这个字段。

### 6.9 小模型 + CPU 很慢

9B 模型纯 CPU 首次请求（规则缓存预热前）可能要十几分钟。`.env` 里 `COACH_JOB_TIMEOUT_MS=1500000`（25 分钟）是为此留的兜底。另外 thinking 类模型会占用同一份额度，方案被截断时优先调大 `Admin → AI Coach → Advanced → Max output tokens`（默认 16000）。

---

## 7. 目录说明

```
.
├── README.md                       # 本文档
├── deploy/
│   ├── docker-compose.yml          # 容器编排（web 端口已收紧为 127.0.0.1）
│   ├── .env.example                # 配置模板，含逐项注释
│   └── reload-model-16k.bat        # LM Studio 16K 上下文重载脚本
└── logs/
    ├── 2026-10-14-worklog.md       # 完整部署与排错过程
    └── 2026-10-15-worklog.md       # 运维补充（数据目录说明）
```

---

## 8. 日常运维速查

```bash
cd deploy

docker compose ps                    # 状态
docker compose logs api --tail 50    # 日志
docker compose stop                  # 停止
docker compose pull && docker compose up -d   # 更新

# 备份（唯一要备份的就是 ./data）
tar czf backups/data-$(date +%Y%m%d).tar.gz data
```

设备要能访问，前提是：电脑上 **Docker Desktop 在运行** + **Tailscale 在运行**，手机侧 **Tailscale 开关打开**。

| 现象 | 排查 |
|---|---|
| 浏览器/手机打不开 | Docker Desktop、Tailscale 是否都在运行；手机是否登录了**同一个**账号 |
| 打开根地址看到 `Unexpected endpoint or method` | 正常，不是错误 |
| 登录/配对报 passkey 错误 | `RP_ID`/`ORIGIN` 与实际访问地址不一致，或设备名改过 |
| Coach 一直转圈 | LM Studio 是否 Start Server；上下文与并行数是否被切分（§6.1） |
| 方案被截断 | 调大 Max output tokens；检查 `loaded_context_length` |
| 想彻底关掉 Coach | `.env` 加 `COACH_DISABLED=1` → `docker compose up -d` |

---

## 9. 上游与许可

- 上游项目：[DuarteSantos8/openGym](https://github.com/DuarteSantos8/openGym)，**AGPL-3.0**
- `deploy/docker-compose.yml` 取自上游并做了端口绑定收紧（§5.2），沿用上游许可
- 本仓库的文档与脚本为个人部署记录

> **隐私说明**：本仓库已脱敏。真实域名、Tailscale 设备名与 IP、账号 ID、passkey 密钥、VAPID 私钥、用户数据均未包含。
