# 中继（relay）：云端 Render 或本地运行
# Relay: Cloud (Render) or Local

> 🌐 中英双语：本页逐节对照。需要「整篇中文 / 整篇英文 + 篇首切换按钮」请见 👉 [README.html](./README.html)（一键切换 🇨🇳/🇬🇧）。
>
> 🌐 Bilingual: this page is section-by-section. For full-Chinese-then-full-English with a top toggle button, see 👉 [README.html](./README.html) (one-click 🇨🇳/🇬🇧 switch).

`tts_cn` 插件**自己不合成语音**，它把每句话发给一个「中继」服务；中继用微软 edge-tts 合成中文，转成 Kindle 能直接播放的 WAV（16bit / 16000Hz / 单声道）再返回。本目录就是中继服务的全部代码。

The `tts_cn` plugin does **not** synthesize speech by itself — it sends every sentence to a "relay" service. The relay uses Microsoft Edge-TTS to synthesize Chinese, converts it into WAV (16-bit / 16000 Hz / mono) that the Kindle can play directly, then returns it. This directory contains the complete relay service code.

两种跑法：

Two ways to run it:

- **本地**：手机 Termux 或任意电脑，走局域网 `http://`（手机要开着，适合在家）。
- **Local**: a phone running Termux, or any computer, over the LAN `http://` (the phone must stay on; good for home use).
- **云端 Render**：部署到公网，走 `https://`（手机彻底不用参与，适合出门 / 长期稳定）。
- **Cloud (Render)**: deploy to the public internet over `https://` (no phone involved at all; good for going out / long-term stability).

> 部署完成后你会拿到形如 `https://tts-relay-xxxx.onrender.com` 的公网地址，填进 Kindle 即可。
> After deployment you'll get a public address like `https://tts-relay-xxxx.onrender.com` — fill it into the Kindle.

---

## 目录里的文件 / Files in this directory

| 文件 File | 用途 Purpose |
|------|------|
| `tts_relay_android.py` | Flask 中继主程序，**本地 / 云端通用**，直接 `python` 跑 / Flask relay main program, **works both locally and in the cloud**, run directly with `python` |
| `relay.sh` | Termux 一键控制：`setup` / `start` / `stop` / `restart` / `status` / `log` / `test` / Termux one-command control: `setup` / `start` / `stop` / `restart` / `status` / `log` / `test` |
| `requirements.txt` | 依赖（本地 / Render 都用它）/ Dependencies (used by both local and Render) |
| `cloud/render.yaml` | Render 部署配置（Python 运行时，自动读）/ Render deploy config (Python runtime, auto-read) |
| `cloud/Dockerfile` | 备选：Docker 方式部署（Railway / 任意支持 Docker 的平台）/ Alternative: Docker deployment (Railway / any Docker-supporting platform) |
| `cloud/wsgi.py` + `cloud/tts_relay_cloud.py` + `cloud/requirements-cloud.txt` | alwaysdata / PythonAnywhere 等纯 HTTP WSGI 平台用 / For pure-HTTP WSGI platforms like alwaysdata / PythonAnywhere |

---

## 一、本地中继（手机 Termux / 任意电脑）
## 1. Local Relay (Phone Termux / Any Computer)

### 方式 A：手机 Termux（推荐，出门也能用）
### Method A: Phone Termux (recommended, works even when out)

```bash
# 把本目录拷到手机 ~/tts_relay，然后：
# Copy this directory to the phone at ~/tts_relay, then:
bash relay.sh setup     # pkg 装 python/ffmpeg/termux-tools；pip 装 edge-tts/flask；开唤醒锁
                       # pkg installs python/ffmpeg/termux-tools; pip installs edge-tts/flask; acquires wake-lock
bash relay.sh start     # 后台常驻（setsid nohup），打印 Kindle 要填的地址
                       # runs in background (setsid nohup), prints the address to fill into the Kindle
```

`relay.sh` 子命令：`setup` / `start` / `stop` / `restart` / `status` / `log` / `test`。
`relay.sh` sub-commands: `setup` / `start` / `stop` / `restart` / `status` / `log` / `test`.

### 方式 B：任意电脑 / 服务器（非 Termux）
### Method B: Any PC / Server (non-Termux)

```bash
pip install -r requirements.txt
python tts_relay_android.py
# 自定义端口 / 采样率：
# Custom port / sample rate:
PORT=8080 TTS_WAV_RATE=22050 python tts_relay_android.py
```

控制台（`http://手机IP:5000/`）和启动日志都会打印 Kindle 要填的地址：

Both the web console (`http://phone-IP:5000/`) and the startup log print the address to fill into the Kindle:

```
http://<手机IP>:5000/tts?voice=zh-CN-XiaoxiaoNeural&text={text}
```

### ⚠️ 背景保活（Termux 最小化后 Kindle 收不到请求）
### ⚠️ Background keep-alive (Kindle stops receiving requests after Termux is minimized)

**现象**：Termux 浮窗时能正常朗读，一最小化 / 切到别的 App，Kindle 端就卡住收不到音频。
**Symptom**: reading works fine while Termux is a floating window, but once it's minimized / you switch to another app, the Kindle stalls and stops receiving audio.

**原因**：Android 后台执行限制（Doze + 电池优化），不是代码 bug——App 进后台后系统挂起它的 CPU/网络。
**Cause**: Android background execution limits (Doze + battery optimization), not a code bug — once the app goes to the background the system suspends its CPU/network.

按优先级处理（前两步通常就够）：
Handle in priority order (the first two steps are usually enough):

1. **关闭 Termux 的电池优化（最关键）**：系统设置 → 应用 → Termux → 电池/省电优化 → 设为「不限制」。小米/三星/OPPO 等还有厂商自带的「神隐模式 / 内存加速 / 自启动管理」，把 Termux 加进白名单。
   **Disable Termux battery optimization (most critical)**: System Settings → Apps → Termux → Battery/Saving Optimization → set to "Unrestricted". On Xiaomi/Samsung/OPPO etc. there are also vendor "hidden-mode / memory-acceleration / auto-start managers" — add Termux to their whitelist.
2. **装 Termux:API（F-Droid）** → `relay.sh` 已自动调用 `termux-wake-lock` 持 partial wakelock，降低被挂起概率。
   **Install Termux:API (F-Droid)** → `relay.sh` already calls `termux-wake-lock` automatically to hold a partial wakelock, reducing the chance of being suspended.
3. **Termux:Boot** → 开机自启，作为系统拉起的后台进程更抗杀。
   **Termux:Boot** → auto-starts on boot; as a system-launched background process it's more resistant to being killed.
4. **Termux:Float** → 常驻浮窗，始终前台，最稳但占屏幕。
   **Termux:Float** → stays as a floating window, always in the foreground; most stable but uses screen space.
5. **仍不稳定 / 想「最小化就忘掉」** → 做成 **APK 前台服务（带常驻通知）** 才是根治：前台服务系统不敢随意杀，最小化、锁屏都持续收请求（本项目另含 APK 方案，不在本中继仓库内）。
   **Still unstable / want to "minimize and forget"** → the real fix is an **APK foreground service (with a persistent notification)**: the system won't casually kill a foreground service, so it keeps receiving requests even when minimized or screen-locked (this project also ships an APK variant, outside this relay repo).

> 判断标准：能接受「手机留个浮窗 / 关电池优化」→ 用本中继；想彻底无感后台 → 走 APK 前台服务。
> Rule of thumb: if you can accept "leaving a floating window / disabling battery optimization" → use this relay; if you want a fully invisible background → go with the APK foreground service.

---

## 二、云端 Render（公网 https，手机不用参与）
## 2. Cloud (Render) (public https, no phone needed)

免费、不用绑卡，部署一次长期可用。Render 免费层会**休眠**，首次访问冷启动几秒，之后正常。
Free, no card binding required, deploy once and use long-term. Render's free tier will **sleep**; the first visit has a cold-start of a few seconds, then it runs normally.

### 0. 注册 Render 账号（首次）
### 0. Sign up for a Render account (first time)

1. 打开 <https://render.com> ，点右上角 **Sign Up**。
   Open <https://render.com> and click **Sign Up** in the top-right.
2. 推荐点 **Continue with GitHub**（用 GitHub 登录）：在弹出的 GitHub 授权页点 **Authorize render**，这样后面部署能直接在下拉里选到你的仓库。也可以用 Google 或邮箱注册（邮箱注册需点开验证邮件激活）。
   Recommended: click **Continue with GitHub** (log in with GitHub): on the popup GitHub authorization page click **Authorize render**, so later you can pick your repo directly from the dropdown. You can also sign up with Google or email (email sign-up requires clicking the verification email to activate).
3. 登录后进入 **Dashboard**（控制台首页），说明账号已就绪。
   After logging in you reach the **Dashboard** (console home) — this means the account is ready.
4. （可选）**Account → Billing** 确认是免费套餐；Web Service 免费层够用（会休眠，首次访问冷启动几秒）。
   (Optional) **Account → Billing** to confirm the free plan; the Web Service free tier is enough (it sleeps, cold-start a few seconds on first visit).
   > 不绑定支付方式也能部署免费层；若平台要求绑卡做风控校验，按提示绑一张（仅校验、不扣费），或改用下面的 Railway / 纯 HTTP 平台。
   > You can deploy the free tier without binding a payment method; if the platform requires a card for risk-control verification, bind one as prompted (verification only, no charge), or switch to Railway / a pure-HTTP platform below.
5. 账号就绪后，继续下面的「1. 准备代码 / 2. 部署」。
   Once the account is ready, continue with "1. Prepare code / 2. Deploy" below.

### 1. 准备代码
### 1. Prepare code

把本 `relay/` 目录（至少含 `tts_relay_android.py`、`requirements.txt`）推到你的 GitHub 仓库。
（仓库里已带 `cloud/render.yaml`；Render 连上仓库会自动读取。）
Push this `relay/` directory (at least `tts_relay_android.py` and `requirements.txt`) to your GitHub repo.
(The repo already includes `cloud/render.yaml`; Render reads it automatically when connected.)

### 2. 部署
### 2. Deploy

- Render 控制台 → **New** → **Web Service** → 连该 GitHub 仓库；
  Render console → **New** → **Web Service** → connect that GitHub repo;
- Render 自动读 `cloud/render.yaml`：Python 运行时、free 套餐、构建时装 ffmpeg + 依赖、启动 `python tts_relay_android.py`、健康检查 `/healthz`；
  Render auto-reads `cloud/render.yaml`: Python runtime, free plan, installs ffmpeg + deps at build, starts `python tts_relay_android.py`, health check `/healthz`;
- 确认 Build / Start 命令后点 **Deploy**；
  Confirm the Build / Start commands, then click **Deploy**;
- 几分钟后得到形如 **`https://tts-relay-xxxx.onrender.com`** 的地址——这就是控制台地址，也是 Kindle 要填的地址。
  After a few minutes you get an address like **`https://tts-relay-xxxx.onrender.com`** — this is both the console address and the address to fill into the Kindle.

`render.yaml` 关键内容（已内置，无需手改）：
Key contents of `render.yaml` (built-in, no manual edit needed):

```yaml
services:
  - type: web
    name: tts-relay
    runtime: python
    plan: free
    buildCommand: "apt-get update && apt-get install -y ffmpeg && pip install -r requirements.txt"
    startCommand: "python tts_relay_android.py"
    healthCheckPath: /healthz
    envVars:
      - key: TTS_WAV_RATE
        value: "16000"
      - key: TTS_RATE
        value: "+0%"
```

> 备选 Docker 方式：把 `runtime` 改成 `docker`、删 `buildCommand`/`startCommand`，Render 会用同目录 `Dockerfile` 构建（更稳，但免费层镜像构建稍慢）。
> Alternative Docker method: change `runtime` to `docker` and remove `buildCommand`/`startCommand`; Render will build with the same-directory `Dockerfile` (more stable, but the free-tier image build is a bit slower).

### 3. 控制台 / 验证
### 3. Console / Verify

打开 `https://你的域名/` 可在线试听、看 Kindle 请求计数（确认连到了云端）。
Open `https://your-domain/` to audition online and see the Kindle request counter (confirms it's connected to the cloud).

部署完成后你会拿到自己的实例地址，形如 **`https://tts-relay-xxxx.onrender.com`**。
After deployment you'll get your own instance address, like **`https://tts-relay-xxxx.onrender.com`**.

---

## 三、Kindle 端怎么填
## 3. Kindle Configuration

插件里：**设置 → 在线接口地址**，填下面这种完整 URL（**务必保留 `{text}` 和 `{voice}` 占位符**，插件会自动把当前句文本和所选音色替换进去）：
In the plugin: **Settings → Online API URL**, fill in a complete URL like below (**keep the `{text}` and `{voice}` placeholders**, the plugin will substitute the current sentence text and the selected voice automatically):

- 本地：`http://<手机IP>:5000/tts?voice=zh-CN-XiaoxiaoNeural&text={text}`
  Local: `http://<phone-IP>:5000/tts?voice=zh-CN-XiaoxiaoNeural&text={text}`
- 云端：`https://tts-relay-xxxx.onrender.com/tts?voice=zh-CN-XiaoxiaoNeural&text={text}`
  Cloud: `https://tts-relay-xxxx.onrender.com/tts?voice=zh-CN-XiaoxiaoNeural&text={text}`

### 请求格式（中继接口）
### Request format (relay API)

```
GET /tts?voice=<音色>&text=<URL 编码的中文>
GET /tts?voice=<voice>&text=<URL-encoded Chinese>
```

- `voice`：微软音色，如 `zh-CN-XiaoxiaoNeural`（晓晓）/`zh-CN-YunxiNeural`（云希）/`zh-CN-YunyangNeural`（云扬）；
  `voice`: a Microsoft voice, e.g. `zh-CN-XiaoxiaoNeural` (Xiaoxiao) / `zh-CN-YunxiNeural` (Yunxi) / `zh-CN-YunyangNeural` (Yunyang);
- `text`：要朗读的中文，按字节 UTF-8 百分比编码（插件里的 `urlencode` 已处理）；
  `text`: the Chinese to read aloud, percent-encoded byte-by-byte in UTF-8 (handled by the plugin's `urlencode`);
- **返回**：16bit PCM 单声道 WAV（16000Hz），Kindle 端 ALSA 直写播放。
  **Returns**: 16-bit PCM mono WAV (16000 Hz), written straight to ALSA on the Kindle side for playback.

> 当前插件版本会从 `build_url` 强制把 `voice` 参数替换成设置里选的音色，所以 `{voice}` 占位符和写死 `XiaoxiaoNeural` 都能正确生效；`{text}` 永远是必填占位符。
> The current plugin version forces the `voice` parameter from `build_url` to the voice selected in settings, so both the `{voice}` placeholder and a hard-coded `XiaoxiaoNeural` work correctly; `{text}` is always a required placeholder.

---

## 四、其他云端（备选）
## 4. Other Cloud Platforms (alternatives)

- **Railway**：与 Render 同思路（用 `render.yaml`/Dockerfile），生成 `https://tts-relay-xxxx.up.railway.app`。
  **Railway**: same idea as Render (uses `render.yaml`/Dockerfile), produces `https://tts-relay-xxxx.up.railway.app`.
- **alwaysdata / PythonAnywhere**：**纯 HTTP** 域名（`http://用户名.alwaysdata.net`、`http://用户名.pythonanywhere.com`）。仅当 **Kindle 3 的 TLS 栈坏、`https://` 一律连不上** 时才需要——用 `cloud/wsgi.py` 作为 WSGI 入口 + `cloud/requirements-cloud.txt` 装依赖，控制台填 `http://...`。
  **alwaysdata / PythonAnywhere**: **pure-HTTP** domains (`http://username.alwaysdata.net`, `http://username.pythonanywhere.com`). Only needed when **the Kindle 3's TLS stack is broken and `https://` can't connect at all** — use `cloud/wsgi.py` as the WSGI entry point + install deps from `cloud/requirements-cloud.txt`, and fill `http://...` in the console.

---

## 五、排错速查
## 5. Troubleshooting

| 现象 Symptom | 排查 Fix |
|------|------|
| 云端连不上 / 超时 / Cloud unreachable / timeout | 看 Render 控制台「请求计数」是否在涨；免费层冷启动慢，第一次访问等几秒。睡了的点一下控制台唤醒 / Check whether the Render console "request counter" is rising; the free tier cold-starts slowly, wait a few seconds on first visit. Click the console to wake a sleeping instance |
| 本地最小化后断 / Local drops after minimize | 见上方「Termux 背景保活」5 步 / See the "Termux background keep-alive" 5 steps above |
| Kindle 3 对 `https://` 域名连不上 / Kindle 3 can't connect to `https://` | TLS 栈坏 → 换 alwaysdata / PythonAnywhere 纯 HTTP，或本地局域网 / Broken TLS stack → switch to alwaysdata / PythonAnywhere pure HTTP, or use the local LAN |
| 听到「百分之九 c」之类噪声 / Hearing noise like "percent-nine-c" | 取文混入了孤立坏字节；v1.83+ 插件已 `sanitize_utf8` 兜底，升级插件即可 / Stray bad bytes slipped into the text; plugin v1.83+ already has `sanitize_utf8` fallback — just upgrade the plugin |
| 蓝牙音箱没声（Oasis 等）/ No Bluetooth speaker sound (Oasis etc.) | 插件默认直写内置声卡，蓝牙连接时本机扬声器被静音；设置里把「音频后端优先级」切到「系统音频(蓝牙)」（v1.85+），或填蓝牙 ALSA 设备名 / The plugin writes straight to the built-in sound card by default, muting the local speaker when Bluetooth is connected; in settings switch "Audio backend priority" to "System audio (Bluetooth)" (v1.85+), or fill in the Bluetooth ALSA device name |

---

## 可选：极简单文件版（relay/standalone）
## Optional: Minimal single-file relay (relay/standalone)

如果你只想先在电脑上跑通、懒得部署上面的完整中继，仓库还附带一个零额外配置的极简单文件中继
[`relay/standalone/relay_server.py`](./standalone/relay_server.py)：

If you just want to get it running on a PC first without deploying the full relay above, the repo also ships a zero-extra-config minimal single-file relay
[`relay/standalone/relay_server.py`](./standalone/relay_server.py):

```bash
cd relay/standalone
pip install -r requirements.txt
python relay_server.py --host 0.0.0.0 --port 5000
# 然后 cloud_tts.cfg 填 RELAY_BASE=http://<中继IP>:5000/tts
# Then set RELAY_BASE=http://<relay-IP>:5000/tts in cloud_tts.cfg
```

> 它与上面的 `tts_relay_android.py` 功能等价（Edge-TTS → WAV），但只有一个文件、无 Web 控制台；适合快速本地验证。
> It is functionally equivalent to `tts_relay_android.py` above (Edge-TTS → WAV) but is a single file with no web console; good for a quick local check.
