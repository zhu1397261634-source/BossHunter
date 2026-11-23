# 无头 Linux 部署指南（容器 / NAS / 无桌面服务器）

本文面向**没有桌面浏览器**的 Linux 环境（Docker、NAS、CI、远程服务器）。官方的
[QUICKSTART](QUICKSTART.md) 和 [Windows/macOS 启动器](windows-launcher.md) 假设你有一台
带 GUI 的桌面机，本文档补充无头场景下会遇到的三类问题及解法。

> ⚠️ 先读风险提示：自动化操作招聘平台存在账号限制或封禁风险。本项目仅供学习、研究和
> 个人求职效率提升；请遵守平台规则，保持低频，并自行承担使用风险。

---

## 1. 环境要求

| 组件 | 版本 | 说明 |
|---|---|---|
| Python | 3.10+ | 建议 3.11+ |
| Node.js | 22+ | Browser Runtime 是 Node 写的 |
| Chrome / Chromium | 最新稳定版 | 需支持 CDP（远程调试） |
| AI API Key | — | Anthropic 或 OpenAI 兼容接口 |

---

## 2. 三类必踩的坑

### 坑 1：代理环境变量会让 AI 调用静默失败

这是最容易踩、也最难查的一个。

**症状**：`bosshunter ai-status` 显示 "✓ AI 接口连接正常"，但实际评分/生成招呼语时
什么也不产出，日志无报错，AI 调用返回 `None`。

**原因**：两条独立的故障叠加。

**(a) `NO_PROXY` 的 IPv6 方括号写法非法。** 本项目开发环境曾导出：

```bash
NO_PROXY="localhost,127.0.0.1,::1,[::1]"
```

`httpx2` 的 URL 解析器无法处理 `[::1]`，直接抛：

```
httpx2.InvalidURL: Invalid port: ':1]'
```

注意 `::1`（裸 IPv6）和 `[::1]`（带方括号，标准写法）是两种形式 —— httpx2 只接受后者，
但**方括号形式在 env 变量里反而会炸**，因为 `[` `]` 会被解析成 port 的一部分。

**(b) `httpx` 与 `httpx2` 类型不兼容。** `anthropic>=2.12` SDK 已迁移到 `httpx2`。
而 `src/bosshunter/ai/credentials.py` 在检测到任意代理变量时，会构造一个
`httpx.Client(trust_env=False)` 传给 SDK：

```python
if _ambient_proxy_vars():
    kwargs["http_client"] = httpx.Client(trust_env=False)
```

SDK 期望的是 `httpx2.Client`，于是抛：

```
TypeError: Invalid `http_client` argument; `httpx.Client` is from the `httpx`
package, but this SDK uses `httpx2`. Use `httpx2.Client` instead.
```

**解法**：启动前清空全部代理变量。

```bash
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
unset http_proxy https_proxy all_proxy no_proxy
```

`scripts/linux/headless-launch.sh` 已经内置这一步。

> 如果你的网络**必须**走代理，请在 `unset` 之后再单独设置，并用正确的形式：
> `NO_PROXY="localhost,127.0.0.1"`（不要写 `[::1]`）。

### 坑 2：完整版 Chrome 二进制在容器里崩溃

**症状**：`chromium-*/chrome-linux64/chrome` 启动即退出：

```
chrome_crashpad_handler: --database is required
[ERROR:third_party/crashpad/crashpad/util/linux/socket.cc:120] recvmsg: Connection reset by peer
[1574895:1574895:1123/110430.929180:ERROR:... ] Trace/breakpoint trap
```

加上 `--no-sandbox --disable-gpu --single-process --disable-breakpad` 也一样崩。

**原因**：crashpad handler 需要一个可写的 database 路径，容器里缺少该配置时会在
crashpad 初始化阶段直接 abort。

**解法**：改用 Playwright 提供的 **headless shell** 构建，它不依赖 crashpad：

```bash
# 正确：headless shell
$PLAYWRIGHT_BROWSERS_PATH/chromium_headless_shell-*/chrome-headless-shell-linux64/chrome-headless-shell \
  --no-sandbox --disable-gpu --disable-dev-shm-usage \
  --remote-debugging-port=9222 --user-data-dir=/tmp/hs-profile about:blank
```

安装命令：

```bash
export PLAYWRIGHT_BROWSERS_PATH=/tmp/pw-browsers
.venv/bin/python -m patchright install chromium
```

### 坑 3：patchright 找不到已安装的浏览器

**症状**：

```
chromium executable: /vol3/@appshare/Harness/.cache/ms-playwright/chromium-1248/chrome-linux64/chrome
exists: False
```

**原因**：SDK 默认用 `~/.cache/ms-playwright`，但你可能装到了别处。

**解法**：显式设置 `PLAYWRIGHT_BROWSERS_PATH`，并**确保它对启动 Chrome 和启动
BossHunter 的两个进程都生效**。

---

## 3. 完整部署步骤

```bash
# 1. 获取源码
git clone https://github.com/shengjidaguai-china/BossHunter.git
cd BossHunter

# 2. Python 环境
python3 -m venv .venv
.venv/bin/pip install -e .

# 3. 前端构建（dist 不随仓库跟踪，必须本地构建）
npm --prefix src/bosshunter/web/frontend ci
npm --prefix src/bosshunter/web/frontend run build

# 4. 浏览器
export PLAYWRIGHT_BROWSERS_PATH=/tmp/pw-browsers
.venv/bin/python -m patchright install chromium

# 5. 配置 AI
export ANTHROPIC_API_KEY="sk-..."
# Anthropic 兼容网关（可选）
export ANTHROPIC_BASE_URL="https://tokencenter.rynnova.com"

# 6. 启动
./scripts/linux/headless-launch.sh
```

面板地址：<http://127.0.0.1:8686>

### 拆成手工步骤（便于排查）

```bash
# 清空代理变量 —— 必须最先执行
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
unset http_proxy https_proxy all_proxy no_proxy

export PLAYWRIGHT_BROWSERS_PATH=/tmp/pw-browsers

# 启动 headless chrome
$PLAYWRIGHT_BROWSERS_PATH/chromium_headless_shell-*/chrome-headless-shell-linux64/chrome-headless-shell \
  --no-sandbox --disable-gpu --disable-dev-shm-usage \
  --remote-debugging-port=9222 --user-data-dir=/tmp/hs-profile about:blank &

# 验证 CDP
curl -s http://127.0.0.1:9222/json/version

# 验证 BossHunter 能连上
.venv/bin/python -m bosshunter.main connect

# 验证 AI
.venv/bin/python -m bosshunter.main ai-status

# 启动面板
.venv/bin/python -m bosshunter.main web
```

---

## 4. 验证清单

| 检查项 | 命令 | 期望输出 |
|---|---|---|
| 前端产物 | `ls src/bosshunter/web/frontend/dist` | 有 `index.html` 和 `assets/` |
| CLI 可用 | `.venv/bin/python -m bosshunter.main --help` | 列出全部子命令 |
| CDP 存活 | `curl -s http://127.0.0.1:9222/json/version` | 返回 `Browser` 字段 |
| BossHunter 连通 | `.venv/bin/python -m bosshunter.main connect` | `✓ 已连接 Chrome` |
| AI 凭证 | `.venv/bin/python -m bosshunter.main ai-status` | `✓ AI 接口连接正常` |
| 面板 | `curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8686/` | `200` |

> `ai-status` 只探测模型列表接口，**不发送生成请求**。要验证真实生成，请直接跑一次
> 评分或招呼语流程 —— 坑 1 的失败正是在这一步才暴露。

---

## 5. ⚠️ 无头模式下的登录难题

这是无头部署**最实质的障碍**，请务必先了解：

**BossHunter 不自带浏览器，它连接的是"你自己的、已登录的" Chrome。** 官方设计是
桌面场景 —— 你手动打开 Chrome、扫码登录招聘平台，BossHunter 再通过 CDP 接管。

在无头容器里：

- 没有图形界面，无法扫码登录
- BOSS 直聘、智联招聘等平台的**登录墙、验证码、滑块、扫码验证**在 headless
  环境下基本无法通过
- 项目检测到验证码/登录墙/频率限制时会**安全停止**，不会尝试绕过（这是设计意图，
  也是合规要求）

**实际影响**：`bosshunter connect` 会一直报 "未发现 BOSS直聘 页面"。

可行的应对方式：

1. **无头 Chrome + 持久化 profile**：把 `--user-data-dir` 指向一个持久化目录，
   先在有 GUI 的机器上用同一目录登录一次，容器内复用该 profile 的登录态。
   登录态有时效性，需定期刷新。
2. **X11 转发 + 虚拟显示**：用 `Xvfb` 起虚拟屏，或 `ssh -X` 转发，
   在图形会话中完成扫码登录。仍需人工介入登录环节。
3. **只用只读功能**：智联招聘、51job、猎聘的**岗位采集 + AI 评分 + 招呼语准备**
   走只读接口，投递环节回原平台手动完成 —— 这部分对浏览器的依赖最轻。

> 平台能力边界详见 README 的「平台能力边界」表：只有 BOSS 直聘支持投递与回复监听，
> 其余三家均为只读采集。

---

## 6. 常见问题

**Q: `bosshunter ai-status` 通过了，但评分没输出？**
A: 坑 1。`ai-status` 只测模型列表接口，不测生成。检查代理变量是否已清空。

**Q: `pip install -e .` 报 `frontend/dist` 缺失？**
A: 先构建前端。`dist` 不随 git 跟踪，wheel 构建时会强制包含它。

**Q: `npm ci` 报 `errno -13` / cache 目录权限错误？**
A: npm 缓存目录被 root 占用。改用本地缓存：
   `export npm_config_cache=/tmp/npmcache`。

**Q: Chrome 进程起来但 CDP 端口不通？**
A: 看 `/tmp/bosshunter-chrome.log`。多半是用了完整版 chrome 而非 headless shell
   （坑 2），或者 `--user-data-dir` 不可写。

**Q: 能用 Docker 吗？**
A: 可以，但要额外注意：容器内需要 `--no-sandbox`（脚本已含）、`--disable-dev-shm-usage`
   （规避 `/dev/shm` 过小导致的渲染崩溃），并把 profile 目录挂载出来持久化登录态。

---

## 7. AI 模型选型建议

BossHunter 的 `ai.model` 接受任意模型名，具体能力取决于你所选模型。

| 任务 | 建议 | 理由 |
|---|---|---|
| 岗位评分、招呼语生成（默认） | 性价比优先的中等模型 | 评分是结构化 JSON 输出，对推理深度要求不高，但调用量大 |
| 需要长文档理解（整份 JD） | 长上下文模型 | 部分招聘平台 JD 很长 |
| 简历解析 | 支持视觉/多模态更好 | 部分简历是扫描件 PDF，需 OCR 或视觉模型 |

配置方式见 [CONFIGURATION.md](CONFIGURATION.md)，或直接在面板 <http://127.0.0.1:8686>
的 AI 设置页填写。

---

## 8. 安全提醒

- **API Key 只在本地面板输入**，不要发送到聊天、Issue 或提交到仓库。
  项目会把 Key 单独存到被 gitignore 的本地凭据文件里。
- 无头容器建议只暴露 `127.0.0.1`，通过 SSH 端口转发访问面板：
  `ssh -L 8686:127.0.0.1:8686 user@host`
- 本项目的 Agent Tool API（见 [AGENT_API.md](AGENT_API.md)）提供回环访问控制，
  不要在公网暴露。

---

## 9. 相关文档

| 文档 | 内容 |
|---|---|
| [QUICKSTART.md](QUICKSTART.md) | 桌面环境完整上手指南 |
| [windows-launcher.md](windows-launcher.md) | Windows 一键启动器 |
| [macos-launcher.md](macos-launcher.md) | macOS 一键启动器 |
| [CONFIGURATION.md](CONFIGURATION.md) | 平台、AI、简历与风控配置 |
| [CLI.md](CLI.md) | CLI 命令详解 |
| [FAQ.md](FAQ.md) | 封号风险、平台边界、连接排错 |
| [AGENT_API.md](AGENT_API.md) | 本机 Agent Tool API |
