#!/bin/sh
# cloud_tts_helper.sh —— audiobook「平台原生(NATIVE)」后端用的云端 TTS helper
#
# audiobook 会以如下方式调用本脚本：
#   cloud_tts_helper.sh --input <文本文件.txt> --output <输出.wav> --speed <倍率>
# 本脚本读取 <文本文件> 的 UTF-8 正文，向云端中继请求语音，把结果直接写入 <输出>。
#
# 设计要点（v3：并发闸门 + 截断重试）
#   - 云端中继（Edge-TTS 类）直接返回 WAV（16000Hz / 单声道 / 16bit）。本设备（墨水屏/
#     Kindle 等）实测可直接播放该 WAV，因此【不再做任何转码】，原样透传即可。
#   - 插件自带的 bin/ffmpeg 在本设备内核过老（"FATAL: kernel too old" → Segmentation
#     fault），一旦调用就崩，且本设备不需要它，故彻底弃用。
#   - 变速（--speed）改用中继自带的 rate 参数实现（Edge-TTS 风格：+50% / -25% …），
#     不依赖本地 ffmpeg。映射：speed 倍率 → rate=±(speed-1)*100%（限幅到 -50%..+100%，
#     即倍速 0.5x~2.0x）。speed≈1.0 时不发 rate，保持原速。
#   - 重试 + 指数退避：Render 等免费托管会休眠/限流，瞬时并发几十个分段请求时部分会
#     超时或 503；退避重试能显著减少「跳段」。若带 rate 的请求报错，会自动降级为原速重试。
#   - 【v3 新增】并发闸门（信号量）：audiobook 会把长文切成几十段、瞬间并发打几十次请求。
#     免费中继（如 Render 免费版）并发一高就过载，表现为「跳段 + 乱码」。本 helper 用目录
#     信号量把同时打中继的并发数限制到 MAX_CONCURRENT（默认 3），其余进程排队，从根本上
#     压低中继过载。闸门仅在打中继的 curl 期间持有，尽快释放。
#   - 【v3 新增】WAV 截断检测：中继过载时偶尔会返回「头是 WAV、但数据被截断」的残破音频，
#     透传出去就会听到「乱码/杂音」。本 helper 读取 RIFF 头声明的文件大小，若大于实际文件
#     大小即判定为截断，当作失败重试（重试通常在中继恢复后拿到完整音频）。
#
# 中继地址与语音在同级 cloud_tts.cfg 里配置（与 tts_cn 共用同一套中继）。
# 依赖：设备上需有 curl（audiobook 自身的下载功能就依赖它，基本都自带）。
# 注意：本文件必须有可执行权限（chmod +x cloud_tts_helper.sh），否则 audiobook 调不起来。
#
# 排错日志（两份，内容相同）：
#   1) 固定文件：本脚本所在目录下的 cloud_tts_last.log（每次运行覆盖）。不管输出路径在哪，
#      你都能在插件目录里直接找到它 —— 首选看这个。
#   2) 跟随输出：<输出音频名>.helper.log（与生成的 wav 同目录，便于按文件追溯）。
#   （若失败，audiobook 也会把本脚本的 stdout/stderr 打进 /tmp/.native_tts_last.log）。

set -u

# ---- 定位脚本所在目录，从而找到同目录的 cloud_tts.cfg ----
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CFG="$SCRIPT_DIR/cloud_tts.cfg"

# 固定位置的排错日志（与输出路径无关，便于在设备上查找）
FIXEDLOG="$SCRIPT_DIR/cloud_tts_last.log"
# 累积日志：追加写、永不截断。每次朗读（长文几十段）的所有调用都会按顺序记录在这里，
# 便于一次性看全「跳段/乱码」的分布规律。排查时把这个文件发回来即可。
FULLLOG="$SCRIPT_DIR/cloud_tts_full.log"
: > "$FIXEDLOG" 2>/dev/null
echo "================ $(date 2>/dev/null)  invocation pid=$$  ================" >> "$FULLLOG" 2>/dev/null
echo "[cloud_tts] invoked: $0 $*" >> "$FIXEDLOG" 2>/dev/null
echo "[cloud_tts] invoked: $0 $*" >> "$FULLLOG" 2>/dev/null
START_TS=$(date +%s 2>/dev/null || echo 0)

# ---- 硬总时限：所有等待/超时都以此为界，保证 helper 早于 audiobook 的 ~60s 上限退出 ----
# budget_left N  —— 打印「剩余预算」与 N 的较小值（整数秒），至少为 0。
# 用法：_cap=$(budget_left "$TIMEOUT")  然后 curl --max-time "$_cap" ...
# 若 TOTAL_BUDGET 为 0 或非数字，则不做限制（退回旧行为）。
# 注意：预算终点 BUDGET_TS 必须等 cfg 读完、TOTAL_BUDGET 定值后才能算，故用惰性初始化
# （首次调用预算函数时按 START_TS + TOTAL_BUDGET 生成一次），避免读到默认值 45。
BUDGET_TS=""
_budget_init() {
    [ -n "$BUDGET_TS" ] && return 0
    # 空/非数字 => 关闭时限（BUDGET_TS=0）。注意用 ${VAR} 长度判断，不能用 ${VAR:-45}：
    # 后者对「空字符串」也会回退成 45，导致空配置被误当成 45s 预算。
    case "$TOTAL_BUDGET" in
        ''|*[!0-9]*) BUDGET_TS=0; return 0 ;;
    esac
    if [ "$TOTAL_BUDGET" -le 0 ]; then
        BUDGET_TS=0
    else
        BUDGET_TS=$(( START_TS + TOTAL_BUDGET ))
    fi
}
budget_left() {
    _want="$1"
    _budget_init
    [ "$BUDGET_TS" -eq 0 ] && { echo "$_want"; return; }   # 未启用限制
    _now=$(date +%s 2>/dev/null || echo 0)
    _left=$(( BUDGET_TS - _now ))
    [ "$_left" -lt 0 ] && _left=0
    # 返回「剩余预算」与「期望值」的较小值
    if [ "$_want" -le "$_left" ] 2>/dev/null; then echo "$_want"; else echo "$_left"; fi
}
# 剩余预算是否已耗尽
budget_exhausted() {
    _budget_init
    [ "$BUDGET_TS" -eq 0 ] && return 1   # 未启用限制 = 永不耗尽
    _now=$(date +%s 2>/dev/null || echo 0)
    [ $(( BUDGET_TS - _now )) -le 0 ]
}

# ---- 默认值 ----
RELAY_BASE=""
VOICE="zh-CN-XiaoxiaoNeural"
METHOD="get"
TIMEOUT="25"
# 失败重试次数（兜住 Render 冷启动的第一次超时；TIMEOUT×(RETRIES+1) 应 < audiobook 60s 上限）
RETRIES="2"
# 并发闸门：同时打中继的最大进程数（默认 2，压低免费托管的并发过载）
MAX_CONCURRENT="2"
# 等待闸门的最长时间（秒）。超时则“尽力而为”直接打（宁可偶尔过载也不让该段必被跳过）
LOCK_WAIT="12"
# ⚠️⚠️ 硬总时限（秒）：audiobook 等待 helper 的上限约 60s（_synthesizeNativeOneshot
#   max_polls=120 × 0.5s）。若 helper 超过它才结束，audiobook 会判超时并 callback(false)，
#   播放器【停在原地不推进】——这正是用户看到的「自动暂停」。
#   旧版只有 LOCK_WAIT 与 TIMEOUT 各自受控，却漏算了叠加：
#     acquire_slot(LOCK_WAIT) + acquire_hashlock(LOCK_WAIT) + 每轮 acquire_slot(LOCK_WAIT)
#     + 每轮 curl(TIMEOUT) × (RETRIES+1) + backoff ⇒ 最坏可达 ~150s ≫ 60s。
#   故这里设一个绝对预算 TOTAL_BUDGET：helper 从启动起最多花这么多秒，所有等待/超时
#   都按「剩余预算」动态收缩，保证在任何路径下都早于 audiobook 的 60s 上限退出。
#   经验值 45s：留 ~15s 给 audiobook 轮询/音频校验/UI 推进。
TOTAL_BUDGET="45"

# ---- 读取配置（简单 KEY=VALUE，忽略空行与 # 注释）----
if [ -f "$CFG" ]; then
    while IFS= read -r line; do
        case "$line" in
            ''|\#*) continue ;;
        esac
        key=$(echo "$line" | cut -d= -f1 | tr -d ' ')
        val=$(echo "$line" | cut -d= -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        case "$key" in
            RELAY_BASE)     RELAY_BASE="$val" ;;
            VOICE)          VOICE="$val" ;;
            VOLUME)         VOLUME="$val" ;;
            METHOD)         METHOD="$val" ;;
            TIMEOUT)        TIMEOUT="$val" ;;
            RETRIES)        RETRIES="$val" ;;
            MAX_CONCURRENT) MAX_CONCURRENT="$val" ;;
            LOCK_WAIT)      LOCK_WAIT="$val" ;;
            TOTAL_BUDGET)   TOTAL_BUDGET="$val" ;;
        esac
    done < "$CFG"
fi

# ---- 解析参数 ----
INPUT=""
OUTPUT=""
SPEED="1.0"
while [ $# -gt 0 ]; do
    case "$1" in
        --input)  INPUT="$2";  shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --speed)  SPEED="$2";  shift 2 ;;
        *) shift ;;
    esac
done

LOG="$OUTPUT.helper.log"
: > "$LOG" 2>/dev/null
log() { echo "[cloud_tts] $*" >> "$LOG" 2>/dev/null; echo "[cloud_tts] $*" >> "$FIXEDLOG" 2>/dev/null; echo "[cloud_tts] $*" >> "$FULLLOG" 2>/dev/null; }

log "start $(date 2>/dev/null)"
log "input=$INPUT output=$OUTPUT speed=$SPEED"
log "cfg=$CFG relay=$RELAY_BASE voice=$VOICE method=$METHOD timeout=$TIMEOUT retries=$RETRIES max_concurrent=$MAX_CONCURRENT lock_wait=$LOCK_WAIT budget=$TOTAL_BUDGET volume=${VOLUME:-<none>}"
log "design: passthrough (no ffmpeg); speed via relay rate param; semaphore-gated concurrency; wav-truncation retry; hard-deadline guard"

# ---- 诊断：把输入文本的前/后若干字节(hex)与是否含 %XX 转义记下来，用于排查「乱码/跳段」 ----
# 乱码/跳段的常见根因：① 文本被百分号转义成 %E4%BD%A0 字面量；② UTF-8 被从多字节字符中间截断。
if [ -f "$INPUT" ]; then
    in_size=$(wc -c < "$INPUT" 2>/dev/null | tr -d ' ')
    log "input_size=$in_size"
    log "input_head_hex=$(head -c 200 "$INPUT" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    log "input_tail_hex=$(tail -c 32 "$INPUT" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    if grep -Eq '%[0-9A-Fa-f][0-9A-Fa-f]' "$INPUT" 2>/dev/null; then
        log "input_has_pct_escape=YES  <-- 文本疑似被百分号转义（%乱码根因）"
    fi
else
    log "input file MISSING: $INPUT"
fi

# ---- 百分号转义解码（可移植版：统一转成八进制 \OOO，避免依赖 GNU 扩展 \xHH）----
# 注意：Kindle/Kobo 等设备跑的是 busybox/dash，其 printf '%b' 不一定支持 \xHH（仅 POSIX 的
# 八进制 \ooo 可移植）。旧版用 \xHH 会在设备上静默失败 → %XX 文本保持双重编码 → 中继拒收/念
# 出“百分之五C”乱码，严重时该句超时被判失败而跳段。这里改用八进制，确保设备端也能正确解码。
url_decode() {
    _raw=$(cat)
    _out=""
    while [ -n "$_raw" ]; do
        case "$_raw" in
            %[0-9A-Fa-f][0-9A-Fa-f]*)
                _hh=$(printf '%s' "$_raw" | cut -c2-3)
                _raw=$(printf '%s' "$_raw" | cut -c4-)
                _oct=$(printf '%o' "0x$_hh" 2>/dev/null)
                _out="$_out$(printf '%b' "\\$_oct" 2>/dev/null)"
                ;;
            *)
                _ch=$(printf '%s' "$_raw" | cut -c1)
                _raw=$(printf '%s' "$_raw" | cut -c2-)
                _out="$_out$_ch"
                ;;
        esac
    done
    printf '%s' "$_out"
}

# 循环解码：对输入反复跑 url_decode，直到内容不再变化为止（最多 3 轮，纯 POSIX、不依赖 grep）。
# 目的：处理「双重（或更多重）百分号编码」。例如上游把反斜杠预编码成 %5C，
# 若再被编码一层就成了 %255C；单次解码只把 %25→%，剩下 %5C，curl 再编码回 %255C →
# 中继把「百分之五C」念出来（%xx 乱码）。循环解码能把 %255C 一路解回 \，彻底消除乱码。
#
# 关键：本函数【不依赖 grep】判断要不要解码——url_decode 本身是纯 POSIX 的 case 匹配，
# 只改写「% 后跟两个十六进制字符」的序列，对普通中文文本是无操作（原样拷贝），因此
# 即使输入完全干净，多跑几轮也绝不会损坏内容。这避免了老版本用 grep 当开关、在 busybox
# 上 grep -E 行为不定导致「整段解码被跳过、%xx 原样发出」的严重 bug。
decode_until_clean() {
    _src="$1"
    _dst="$2"
    [ -z "$_dst" ] && return 1
    cp -f "$_src" "$_dst" 2>/dev/null
    _r=0
    _prev=$(wc -c < "$_dst" 2>/dev/null | tr -d ' ')
    while [ "$_r" -lt 3 ]; do
        _tmp="$OUTPUT.dec.tmp"
        url_decode < "$_dst" 2>/dev/null > "$_tmp"
        if [ ! -s "$_tmp" ]; then
            rm -f "$_tmp" 2>/dev/null
            break
        fi
        # 停止判据用【字节数】而非 cmp：%XX（3 字节）解码后必成 1 字节，字节数必变；
        # 若字节数不变则说明本轮没有任何 %XX 被解，已到底，停止。纯 POSIX、不依赖 cmp，
        # 在 busybox 上也 100% 可靠，绝不会无限循环或卡死。
        _now=$(wc -c < "$_tmp" 2>/dev/null | tr -d ' ')
        if [ "$_now" = "$_prev" ]; then
            rm -f "$_tmp" 2>/dev/null
            break
        fi
        cp -f "$_tmp" "$_dst" 2>/dev/null
        rm -f "$_tmp" 2>/dev/null
        _prev="$_now"
        _r=$((_r + 1))
    done
}

# ---- 修复非法 UTF-8：丢弃「孤立续字节 / 非法 lead / 截断的多字节序列」 ----
# 动机：audiobook（或上游）在分段时若把多字节 UTF-8 字符从中间切断，会留下坏字节
# （如 0x9C / 0x88 / 0x80 这类孤立续字节）。本 helper 用 curl --data-urlencode 发送时，
# 坏字节会被编码成 %9C / %88 等，中继端 Edge-TTS 把它们当成「百分之九 c」念出来 =
# 用户听到的 %xx 乱码（与 tts_cn 的 segmenter.lua 第 53-88 行 to_codepoints 同根因）。
# 这里在发送前严格校验并丢弃坏字节（与 tts_cn 逻辑一致），彻底消除该乱码。
# 纯 POSIX（od/tr/printf 八进制），busybox/dash 可用。
repair_utf8() {
    _in="$1"; _out="$2"
    [ -f "$_in" ] || { cp -f "$_in" "$_out" 2>/dev/null; return; }
    od -An -tx1 "$_in" 2>/dev/null | tr -s ' \t' '\n' | grep -v '^$' | {
        _acc=""    # 已通过校验、确认提交的字节（八进制转义串）
        _pend=""   # 正在校验中的多字节序列，尚未提交
        _need=0    # 还需要几个续字节
        while IFS= read -r hx; do
            [ -z "$hx" ] && continue
            _b=$((0x$hx))
            _esc="\\$(printf '%o' "$_b")"
            # 处于某个多字节序列中间：期待续字节
            if [ "$_need" -gt 0 ]; then
                if [ "$_b" -ge 128 ] && [ "$_b" -le 191 ]; then
                    _pend="$_pend$_esc"
                    _need=$((_need - 1))
                    # 凑齐全部续字节 -> 该序列合法，正式提交
                    if [ "$_need" -eq 0 ]; then
                        _acc="$_acc$_pend"
                        _pend=""
                    fi
                    continue
                fi
                # 非续字节：当前半截序列作废（连同它的 lead 一起丢弃），
                # _need 归零后把这个字节当作新的 lead 重新对齐。
                _need=0
                _pend=""
            fi
            # 期待一个 lead 字节
            if [ "$_b" -lt 128 ]; then
                _acc="$_acc$_esc"
            elif [ "$_b" -ge 194 ] && [ "$_b" -le 223 ]; then
                _pend="$_esc"; _need=1
            elif [ "$_b" -ge 224 ] && [ "$_b" -le 239 ]; then
                _pend="$_esc"; _need=2
            elif [ "$_b" -ge 240 ] && [ "$_b" -le 244 ]; then
                _pend="$_esc"; _need=3
            else
                : # 非法 lead（0x80-0xC1 / 0xF5-0xFF）：丢弃并继续
            fi
        done
        # EOF 时 _pend 非空 = 末尾是多字节字符被切断的残段，直接丢弃（不提交）
        printf '%b' "$_acc" > "$2"
    }
}

# 若文本被百分号转义（如 %5C / %E4%BD%A0），说明上游把文本预编码过一次；本 helper 又会用
# --data-urlencode 再编码一次 → 中继拿到“字面 %5C”，TTS 会念出“百分之五C”乱码，或中继拒收
# 该句 → 表现为“跳段前的大段停顿 + 跳段”。这里先把 %XX 解码回原始字节（恢复成正常 UTF-8），
# 再由 curl 正常编码，乱码/跳段消除。
#
# 重要：这里【无条件】对输入跑解码（不再用 grep 当开关）。url_decode 只改写“% 后跟两 hex”
# 的序列，对干净中文是无操作；grep 仅用于日志提示。这样即便设备的 grep -E 行为异常，
# 解码也一定会执行，彻底消除“%xx 原样发给中继被念出来”的乱码。
DECODED_INPUT="$INPUT"
_dec="$OUTPUT.dec"
decode_until_clean "$INPUT" "$_dec"
if [ -s "$_dec" ]; then
    _in_sz=$(wc -c < "$INPUT" 2>/dev/null | tr -d ' ')
    _dec_sz=$(wc -c < "$_dec" 2>/dev/null | tr -d ' ')
    if [ "$_in_sz" != "$_dec_sz" ]; then
        # 字节数变了 = 确有 %XX 被解开（%XX 3字节→1字节，必变）。用解码后的干净文本。
        DECODED_INPUT="$_dec"
        # 日志门控（仅提示，失败不影响功能）：输入本身是否含 %XX
        if grep -Eq '%[0-9A-Fa-f][0-9A-Fa-f]' "$INPUT" 2>/dev/null; then
            log "pct-escape detected -> URL-decoded (loop, grep-free) before sending; decoded_head=$(head -c 60 "$_dec" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
        else
            log "input rewritten by decode (byte count changed); decoded_head=$(head -c 60 "$_dec" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
        fi
    else
        # 字节数没变 = 没有任何 %XX 被解，丢弃解码产物，原样发送（绝不损坏正常文本）
        rm -f "$_dec" 2>/dev/null
    fi
fi
# 解码后若仍残留 %XX（极少数：解码轮次不足或本就是合法百分号文本），记一条警告便于排查
if [ -f "$DECODED_INPUT" ] && grep -Eq '%[0-9A-Fa-f][0-9A-Fa-f]' "$DECODED_INPUT" 2>/dev/null; then
    log "WARN: residual %XX still present after decode: $(head -c 80 "$DECODED_INPUT" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
fi
FETCH_INPUT="$DECODED_INPUT"

# 发送前修复非法 UTF-8：分段切断留下的坏字节（0x80-0xBF 孤立续字节等）若不经处理，
# 会被 curl --data-urlencode 编成 %XX 发往中继，Edge-TTS 念成「百分之X」乱码。
# 这里先剥掉坏字节再发送（与 tts_cn segmenter.lua 的 to_codepoints 同逻辑）。
_FETCH_REPAIRED="$OUTPUT.repaired"
repair_utf8 "$FETCH_INPUT" "$_FETCH_REPAIRED"
if [ -s "$_FETCH_REPAIRED" ]; then
    _before=$(wc -c < "$FETCH_INPUT" 2>/dev/null | tr -d ' ')
    _after=$(wc -c < "$_FETCH_REPAIRED" 2>/dev/null | tr -d ' ')
    FETCH_INPUT="$_FETCH_REPAIRED"
    if [ "$_before" != "$_after" ]; then
        log "repaired invalid UTF-8: dropped $(($_before - $_after)) bad byte(s) before sending"
    fi
else
    # 修复后为空（极少见：整段都是坏字节）则退回原文件，避免空请求
    rm -f "$_FETCH_REPAIRED" 2>/dev/null
fi

if [ -z "$INPUT" ] || [ -z "$OUTPUT" ]; then
    echo "usage: cloud_tts_helper.sh --input <txt> --output <audio> --speed <n>" >&2
    log "ERROR: missing --input/--output"
    exit 2
fi
if [ -z "$RELAY_BASE" ]; then
    echo "cloud_tts.cfg: RELAY_BASE 未配置（请填你的中继基础地址，不含 text= 参数）" >&2
    log "ERROR: RELAY_BASE empty"
    exit 3
fi

CURL=$(command -v curl 2>/dev/null)
if [ -z "$CURL" ]; then
    echo "未找到 curl，无法请求云端 TTS（请安装 curl）" >&2
    log "ERROR: curl not found"
    exit 4
fi
log "curl=$CURL"

# ---- 并发闸门（原子目录锁实现的“真·信号量”，跨进程严格限流）----
# 旧版用“ls 计数后建文件”，存在竞态：多个进程可同时越过计数→闸门失效→免费中继被并发打爆
# →「跳段+乱码」。这里改用 mkdir（POSIX 下对“已存在的目录”做 mkdir 会原子失败）实现 N 个槽位
# 的互斥锁，真正把同时打中继的进程数硬限到 MAX_CONCURRENT。
SEM_DIR="$SCRIPT_DIR/.cloud_tts_sema"
mkdir -p "$SEM_DIR" 2>/dev/null
SLOT=""
SEM_STALE=120   # 槽位超过该年龄（秒）视为陈旧（进程被 audiobook 超时杀掉等），回收之

acquire_slot() {
    _now=$(date +%s 2>/dev/null || echo 0)
    # 等待上限 = min(LOCK_WAIT, 剩余总预算)；预算耗尽则直接尽力而为，绝不再等
    _wait_cap=$(budget_left "$LOCK_WAIT")
    if budget_exhausted; then
        log "semaphore: budget exhausted — skip waiting, proceed best-effort immediately"
        SLOT="$SEM_DIR/slot_force_$$"
        mkdir "$SLOT" 2>/dev/null
        return 0
    fi
    _deadline=$(( _now + _wait_cap ))
    while [ "$(date +%s 2>/dev/null || echo 0)" -lt "$_deadline" ]; do
        _i=1
        while [ "$_i" -le "$MAX_CONCURRENT" ]; do
            _d="$SEM_DIR/slot_$_i"
            if [ -d "$_d" ]; then
                _pid=$(cat "$_d/pid" 2>/dev/null)
                if [ -n "$_pid" ] && ! kill -0 "$_pid" 2>/dev/null; then
                    rmdir "$_d" 2>/dev/null   # 持有者已死，回收陈旧槽位
                fi
            fi
            if mkdir "$_d" 2>/dev/null; then
                echo "$$" > "$_d/pid" 2>/dev/null
                SLOT="$_d"
                return 0
            fi
            _i=$((_i + 1))
        done
        sleep 0.2
    done
    # 超时：加一点随机抖动再“尽力而为”直接打，避免所有排队进程在同一时刻集体涌向中继（雪崩式过载）
    _jit=$(od -An -tu1 -N1 /dev/urandom 2>/dev/null | tr -d ' ')
    case "$_jit" in ''|*[!0-9]*) _jit=2 ;; esac
    _jit=$(( (_jit % 5) + 1 ))
    sleep "$_jit" 2>/dev/null
    SLOT="$SEM_DIR/slot_force_$$"
    mkdir "$SLOT" 2>/dev/null
    log "semaphore: waited ${LOCK_WAIT}s without a free slot; proceeding best-effort after ${_jit}s jitter (may overload relay)"
    return 0
}

release_slot() {
    if [ -n "$SLOT" ]; then
        rm -f "$SLOT/pid" 2>/dev/null
        rmdir "$SLOT" 2>/dev/null
        SLOT=""
    fi
}

# ---- 按文本内容加锁（配合缓存，消除“同一句被并发取两次”造成的 2× 中继负载）----
# audiobook 会对同一句话同时发两次 helper 调用（疑似预读），旧逻辑等于把中继负载翻倍；
# 长文排队过深时，后排调用会卡在 audiobook 的单段 ~60s 上限之外被放弃 → 跳段。
# 这里用“内容校验和”做键：相同文本只打一次中继，并发的另一次直接复用缓存。
HASHLOCK_DIR="$SEM_DIR/.hashlock"
mkdir -p "$HASHLOCK_DIR" 2>/dev/null
acquire_hashlock() {
    _l="$HASHLOCK_DIR/$CONTENT_KEY"
    # 等待上限同样受剩余总预算约束，避免「两个 LOCK_WAIT 叠加」突破 audiobook 60s 上限
    _wait_cap=$(budget_left "$LOCK_WAIT")
    if budget_exhausted; then return 0; fi
    _deadline=$(( $(date +%s 2>/dev/null || echo 0) + _wait_cap ))
    while [ "$(date +%s 2>/dev/null || echo 0)" -lt "$_deadline" ]; do
        if mkdir "$_l" 2>/dev/null; then return 0; fi
        sleep 0.1
    done
    return 0
}
release_hashlock() { [ -n "$CONTENT_KEY" ] && rmdir "$HASHLOCK_DIR/$CONTENT_KEY" 2>/dev/null; }

# ---- 取文件头的十六进制串（用 od，避免命令替换吞掉二进制里的 NUL 字节）----
head_hex() {
    head -c "${2:-4}" "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n'
}

# ---- 判断输出是否为有效音频（避免把错误网页当音频写出去）----
is_audio() {
    _f="$1"
    [ -s "$_f" ] || return 1
    _h12=$(head_hex "$_f" 12)
    case "$_h12" in
        52494646* ) return 0 ;;   # RIFF (WAV/AVI)
        494433*    ) return 0 ;;   # ID3  (mp3 with tag)
        4f676753*  ) return 0 ;;   # OggS
        664c6143*  ) return 0 ;;   # fLaC
        52463634*  ) return 0 ;;   # RF64 (大 WAV)
    esac
    _b2=$(head_hex "$_f" 2)
    case "$_b2" in
        fffb|fff3|ffe3|fff2|fff9|fffa|fffd) return 0 ;;
    esac
    case "$_h12" in
        ????????66747970*) return 0 ;;
    esac
    return 1
}

is_wav() {
    _h=$(head_hex "$1" 12)
    case "$_h" in
        52494646????????57415645*) return 0 ;;
    esac
    return 1
}

# ---- WAV 截断检测：读 RIFF 头声明的文件大小（offset 4 起 4 字节 LE），
#      若声明大小 > 实际文件大小-8，说明数据被截断（过载时常见，会导致乱码）----
wav_truncated() {
    _f="$1"
    _fs=$(wc -c < "$_f" 2>/dev/null | tr -d ' ')
    [ -z "$_fs" ] && return 1
    [ "$_fs" -lt 8 ] && return 1
    _h=$(head -c 8 "$_f" 2>/dev/null | od -An -tx1 | tr -d ' \n')
    [ ${#_h} -lt 16 ] && return 1
    _b0=$(echo "$_h" | cut -c9-10)
    _b1=$(echo "$_h" | cut -c11-12)
    _b2=$(echo "$_h" | cut -c13-14)
    _b3=$(echo "$_h" | cut -c15-16)
    _decl=$(( 0x$_b0 + 0x$_b1 * 256 + 0x$_b2 * 65536 + 0x$_b3 * 16777216 )) 2>/dev/null
    [ -z "$_decl" ] && return 1
    if [ "$_decl" -gt $(( _fs - 8 )) ]; then
        return 0
    fi
    return 1
}

# ---- 规范化 WAV：剥离 LIST/fact 等附加块，重建纯 44 字节 PCM 头 ----
# 中继（ffmpeg 产出）的 WAV 头里常在 fmt 与 data 之间夹一个 LIST 元数据块，
# PCM 实际起始偏移不是 44。而 audiobook 的播放器（mediaengine/_playSystemGstLaunch、
# wavutils）按「固定 44 字节头」读 PCM（HEADER_SIZE=44 硬编码），会把 LIST 的
# 内容当 PCM 放出来 → 每句开头一截噪声/爆音 =「乱码」，严重时整段异常。
# 纯 POSIX shell 实现（od 读头 + tail/head 切数据），不依赖 ffmpeg。
# 用法: normalize_wav <src> <dst>   返回 0=成功（dst 为规范 WAV）
_w16() {  # 16 位小端写入
    printf '%b' "\\$(printf '%03o' $(( $1 % 256 )))\\$(printf '%03o' $(( ($1 / 256) % 256 )))"
}
_w32() {  # 32 位小端写入
    printf '%b' "\\$(printf '%03o' $(( $1 % 256 )))\\$(printf '%03o' $(( ($1 / 256) % 256 )))\\$(printf '%03o' $(( ($1 / 65536) % 256 )))\\$(printf '%03o' $(( ($1 / 16777216) % 256 )))"
}
normalize_wav() {
    _src="$1"; _dst="$2"
    [ -s "$_src" ] || return 1
    is_wav "$_src" || return 1
    _fs=$(wc -c < "$_src" 2>/dev/null | tr -d ' ')
    [ -z "$_fs" ] && return 1
    [ "$_fs" -lt 60 ] && return 1

    # 遍历 RIFF 块：找 fmt 与 data 的实际位置
    _off=12
    _fmt_hex=""; _data_off=""; _data_size=""
    while [ "$_off" -gt 0 ] && [ "$_off" -le $((_fs - 8)) ]; do
        _ch=$(dd if="$_src" bs=1 skip="$_off" count=8 2>/dev/null | od -An -tx1 | tr -d ' \n')
        [ ${#_ch} -lt 16 ] && break
        _id=$(printf '%s' "$_ch" | cut -c1-8)
        _hx=$(printf '%s' "$_ch" | cut -c9-16)
        _s0=$(printf '%s' "$_hx" | cut -c1-2); _s1=$(printf '%s' "$_hx" | cut -c3-4)
        _s2=$(printf '%s' "$_hx" | cut -c5-6); _s3=$(printf '%s' "$_hx" | cut -c7-8)
        _csz=$(( 0x$_s0 + 0x$_s1 * 256 + 0x$_s2 * 65536 + 0x$_s3 * 16777216 )) 2>/dev/null
        [ -z "$_csz" ] && break
        [ "$_csz" -lt 0 ] && break
        [ "$_csz" -gt "$_fs" ] && break
        _payload=$((_off + 8))
        case "$_id" in
            666d7420) _fmt_hex=$(dd if="$_src" bs=1 skip="$_payload" count=16 2>/dev/null | od -An -tx1 | tr -d ' \n') ;;
            64617461) _data_off=$_payload; _data_size=$_csz ;;
        esac
        _off=$((_payload + _csz + _csz % 2))   # 奇数长度块有 1 字节对齐填充
    done

    [ ${#_fmt_hex} -lt 32 ] && return 1
    [ -z "$_data_off" ] && return 1
    # 解析 fmt 块：format(2) channels(2) rate(4) byteRate(4) align(2) bits(2)
    _fb0=$(printf '%s' "$_fmt_hex" | cut -c1-2);  _fb1=$(printf '%s' "$_fmt_hex" | cut -c3-4)
    _cb0=$(printf '%s' "$_fmt_hex" | cut -c5-6);  _cb1=$(printf '%s' "$_fmt_hex" | cut -c7-8)
    _r0=$(printf '%s' "$_fmt_hex" | cut -c9-10);  _r1=$(printf '%s' "$_fmt_hex" | cut -c11-12)
    _r2=$(printf '%s' "$_fmt_hex" | cut -c13-14); _r3=$(printf '%s' "$_fmt_hex" | cut -c15-16)
    _b0=$(printf '%s' "$_fmt_hex" | cut -c29-30); _b1=$(printf '%s' "$_fmt_hex" | cut -c31-32)
    _format=$(( 0x$_fb0 + 0x$_fb1 * 256 ))
    _channels=$(( 0x$_cb0 + 0x$_cb1 * 256 ))
    _rate=$(( 0x$_r0 + 0x$_r1 * 256 + 0x$_r2 * 65536 + 0x$_r3 * 16777216 ))
    _bits=$(( 0x$_b0 + 0x$_b1 * 256 ))
    if [ "$_format" -ne 1 ]; then return 1; fi                       # 仅支持 PCM
    if [ "$_channels" -lt 1 ] || [ "$_channels" -gt 2 ]; then return 1; fi
    if [ "$_bits" -ne 8 ] && [ "$_bits" -ne 16 ]; then return 1; fi
    [ "$_rate" -le 0 ] && return 1

    # 已经是纯 44 字节头 → 原样复用，不重写
    if [ "$_data_off" -eq 44 ]; then
        cp -f "$_src" "$_dst" 2>/dev/null
        log "wav canonical (rate=$_rate ch=$_channels bits=$_bits) — passthrough copy"
        return 0
    fi

    # data 大小按实际文件钳制，并对齐到整帧（半帧会让后续样本整体错位成白噪声）
    _avail=$((_fs - _data_off))
    [ "$_avail" -le 0 ] && return 1
    if [ "$_data_size" -le 0 ] || [ "$_data_size" -gt "$_avail" ]; then _data_size=$_avail; fi
    _fbytes=$((_channels * _bits / 8))
    [ "$_fbytes" -le 0 ] && return 1
    _data_size=$(( _data_size - _data_size % _fbytes ))
    [ "$_data_size" -le 0 ] && return 1

    {
        printf 'RIFF'
        _w32 $(( _data_size + 36 ))
        printf 'WAVEfmt '
        _w32 16
        _w16 "$_format"
        _w16 "$_channels"
        _w32 "$_rate"
        _w32 $(( _rate * _fbytes ))
        _w16 "$_fbytes"
        _w16 "$_bits"
        printf 'data'
        _w32 "$_data_size"
        tail -c +$((_data_off + 1)) "$_src" 2>/dev/null | head -c "$_data_size"
    } > "$_dst" 2>/dev/null || return 1
    [ -s "$_dst" ] || return 1
    is_wav "$_dst" || return 1
    log "normalized wav: data was at offset $_data_off (extra chunks before data) — rebuilt 44-byte header rate=$_rate ch=$_channels bits=$_bits data=$_data_size"
    return 0
}

# ---- 由 --speed（倍率）构造中继的 rate 参数（Edge-TTS 风格）----
# 返回如 "rate=+50%" / "rate=-25%" 或空串（≈1.0 倍速时不变速）。
# Edge-TTS 支持区间：-50% .. +100%  →  倍速 0.5x .. 2.0x；超出则限幅。
build_rate_arg() {
    s="$SPEED"
    case "$s" in
        ''|*[!0-9.]*) echo ""; return ;;
    esac
    near=$(awk "BEGIN{d=$s-1.0; if(d<0)d=-d; print (d<0.03)?1:0}" 2>/dev/null)
    [ "$near" = "1" ] && { echo ""; return; }
    pct=$(awk "BEGIN{printf \"%d\", ($s-1.0)*100}" 2>/dev/null)
    [ -z "$pct" ] && { echo ""; return; }
    pct=$(awk "BEGIN{p=$pct; if(p<-50)p=-50; if(p>100)p=100; print p}" 2>/dev/null)
    [ -z "$pct" ] && { echo ""; return; }
    if [ "$pct" -lt 0 ]; then
        echo "rate=-$((-pct))%"
    else
        echo "rate=+${pct}%"
    fi
}
RATEARG=$(build_rate_arg)
log "rate_arg=${RATEARG:-<none, 1.0x>}"

# ---- 由 --speed 之外的 VOLUME 配置构造中继的 volume 参数（Edge-TTS 风格）----
# 仅当 cloud_tts.cfg 里 VOLUME 非空时附加（默认空 = 不调整，最稳妥）。
# 中继是否真的放大音量取决于它是否转发 volume 参数；若中继不认该参数，
# 表现为“填了反而无声/报错”，届时把 VOLUME 改回留空即可恢复。
build_volume_arg() {
    v="$VOLUME"
    [ -z "$v" ] && { echo ""; return; }
    echo "volume=$v"
}
VOLARG=$(build_volume_arg)
log "volume_arg=${VOLARG:-<none>}"

# ---- 内容缓存：相同文本只向中继请求一次，并发的重复请求直接复用 ----
CACHE_DIR="$SCRIPT_DIR/.cloud_tts_cache"
mkdir -p "$CACHE_DIR" 2>/dev/null
CONTENT_KEY=""
if [ -f "$FETCH_INPUT" ]; then
    CONTENT_KEY=$(cksum "$FETCH_INPUT" 2>/dev/null | awk '{print $1"_"$2}')
fi
[ -z "$CONTENT_KEY" ] && CONTENT_KEY="nosum"
CACHE_FILE="$CACHE_DIR/$CONTENT_KEY.wav"
CACHE_MAX=400   # 缓存文件上限，超出则不再写入（避免无限增长）

# ---- 尝试用 curl 抓取一次（先落到 .raw，验证后再透传为正式输出）----
RAW="$OUTPUT.raw"
META="$OUTPUT.meta"
VLOG="$OUTPUT.vlog"
try_fetch() {
    # $1 = "norate" 时强制不发 rate（rate 请求失败后的降级重试）
    _norate="$1"
    _rate="$RATEARG"
    [ "$_norate" = "norate" ] && _rate=""
    # 单次 curl 超时 = min(TIMEOUT, 剩余总预算)；预算耗尽则给 1s 让请求速败而非挂死
    _mt=$(budget_left "$TIMEOUT")
    [ "$_mt" -lt 1 ] 2>/dev/null && _mt=1
    if [ "$METHOD" = "post" ]; then
        if [ -n "$_rate" ]; then
            curl -sS -L --max-time "$_mt" -X POST \
                -H "Content-Type: text/plain; charset=utf-8" \
                --data-binary "@$INPUT" --data-urlencode "$_rate" \
                -o "$RAW" -w "http=%{http_code} type=%{content_type}\n" "$RELAY_BASE" >"$META" 2>"$VLOG"
        else
            curl -sS -L --max-time "$_mt" -X POST \
                -H "Content-Type: text/plain; charset=utf-8" \
                --data-binary "@$INPUT" \
                -o "$RAW" -w "http=%{http_code} type=%{content_type}\n" "$RELAY_BASE" >"$META" 2>"$VLOG"
        fi
    else
        # VOLUME 配置非空时，附加 volume 参数（取决于中继是否转发；空=不附加）
        _volarg=""
        [ -n "$VOLARG" ] && _volarg="--data-urlencode volume=$VOLUME"
        if [ -n "$_rate" ]; then
            # shellcheck disable=SC2086
            curl -sS -G --max-time "$_mt" \
                --data-urlencode "voice=$VOICE" \
                --data-urlencode "text@$FETCH_INPUT" \
                --data-urlencode "$_rate" \
                $_volarg \
                -o "$RAW" -w "http=%{http_code} type=%{content_type}\n" "$RELAY_BASE" >"$META" 2>"$VLOG"
        else
            # shellcheck disable=SC2086
            curl -sS -G --max-time "$_mt" \
                --data-urlencode "voice=$VOICE" \
                --data-urlencode "text@$FETCH_INPUT" \
                $_volarg \
                -o "$RAW" -w "http=%{http_code} type=%{content_type}\n" "$RELAY_BASE" >"$META" 2>"$VLOG"
        fi
    fi
    return $?
}

# ---- 重试（带指数退避 + 并发闸门 + 截断重试 + 内容缓存，缓解托管平台限流导致的跳段/乱码）----
acquire_hashlock
n=0
rate_failed=0
while [ "$n" -le "$RETRIES" ]; do
    rm -f "$RAW" "$OUTPUT" "$META" "$VLOG"
    ok=0
    # 硬总时限：预算已耗尽则不再发起新的一轮（宁可早退被 audiobook 判失败，也不拖过 60s 挂起播放器）
    if [ "$n" -gt 0 ] && budget_exhausted; then
        log "budget exhausted before attempt $n — stop retrying (avoid exceeding audiobook ~60s limit)"
        break
    fi
    # 命中缓存：相同文本已由本次或并发的另一次请求取回，直接复用，省一次中继调用
    if [ -f "$CACHE_FILE" ] && is_wav "$CACHE_FILE" && [ -s "$CACHE_FILE" ]; then
        cp -f "$CACHE_FILE" "$OUTPUT" 2>/dev/null
        if is_wav "$OUTPUT" && [ -s "$OUTPUT" ]; then
            ok=1
            log "cache HIT key=$CONTENT_KEY -> reused (no relay call)"
        fi
    fi
    if [ "$ok" -ne 1 ]; then
        # 占用闸门（仅在打中继期间持有），压低中继并发过载
        acquire_slot
        _arg=""
        [ "$rate_failed" -eq 1 ] && _arg="norate"
        try_fetch "$_arg"
        rc=$?
        raw_size="0"
        [ -f "$RAW" ] && raw_size=$(wc -c < "$RAW" 2>/dev/null | tr -d ' ')
        if [ -f "$META" ]; then
            log "attempt $n: curl rc=$rc meta=[$(cat "$META" 2>/dev/null | tr -d '\n')] raw_size=$raw_size"
        else
            log "attempt $n: curl rc=$rc raw_size=$raw_size"
        fi
        case "$rc" in
            28) log "  -> curl rc=28 连接超时（中继冷启动/网络慢/地址不可达）；下次重试通常中继已热身" ;;
            7)  log "  -> curl rc=7  无法连接中继（RELAY_BASE 地址错 / 设备无公网 / 本地须用 http:// 而非 https://）" ;;
            0)  : ;;
            *)  log "  -> curl rc=$rc（非零非超时，详见上方 meta / raw head）" ;;
        esac
        if [ -f "$VLOG" ]; then
            _req=$(grep -m1 -i '^> GET ' "$VLOG" 2>/dev/null | head -c 400)
            [ -z "$_req" ] && _req=$(grep -m1 -i '^> POST ' "$VLOG" 2>/dev/null | head -c 400)
            [ -n "$_req" ] && log "request: $_req"
        fi

        if [ "$rc" -eq 0 ] && is_audio "$RAW"; then
            if is_wav "$RAW"; then
                if wav_truncated "$RAW"; then
                    # 中继返回了被截断的残破 WAV —— 当作失败重试（重试后大概率拿到完整音频）
                    log "relay returned TRUNCATED wav (declared size > actual) — treat as failure, will retry"
                else
                    # 规范化 WAV（剥离 LIST 等附加块、重建 44 字节头）；
                    # 失败则退回原样拷贝，保持旧行为不倒退
                    if ! normalize_wav "$RAW" "$OUTPUT"; then
                        log "normalize_wav failed — falling back to raw copy"
                        cp -f "$RAW" "$OUTPUT" 2>/dev/null
                    fi
                    if is_wav "$OUTPUT" && [ -s "$OUTPUT" ]; then
                        ok=1
                    fi
                fi
            else
                # 拿到非 WAV 音频（如 mp3）：本设备无 ffmpeg 无法转码，当作失败重试
                log "relay returned non-WAV audio (head=$(head_hex "$RAW" 4)); cannot transcode on this device (no ffmpeg) — will retry"
            fi
        else
            if [ -f "$META" ]; then
                log "relay returned non-audio: $(cat "$META" 2>/dev/null | tr -d '\n')"
            fi
            if [ -s "$RAW" ]; then
                _hex=$(head_hex "$RAW" 16)
                _asc=$(head -c 120 "$RAW" 2>/dev/null | tr -dc '[:print:]' | tr '\n' ' ')
                log "raw head hex=$_hex ascii=$_asc"
            fi
            # 若本次带 rate 且失败，下次降级为原速重试
            if [ -n "$RATEARG" ] && [ "$_arg" != "norate" ]; then
                rate_failed=1
                log "rate request failed; will retry WITHOUT rate (degrade to 1.0x)"
            fi
        fi
        # 释放闸门（无论成败都尽快释放，让排队中的其它分段打中继）
        release_slot
    fi

    if [ "$ok" -eq 1 ]; then
        # 写入内容缓存（限流上限内），并发的相同文本可直接复用
        _cc=$(ls -1 "$CACHE_DIR" 2>/dev/null | wc -l | tr -d ' ')
        [ -z "$_cc" ] && _cc=0
        if [ "$_cc" -lt "$CACHE_MAX" ]; then
            cp -f "$OUTPUT" "$CACHE_FILE" 2>/dev/null
        fi
        rm -f "$RAW" "$META" "$VLOG" "$OUTPUT.dec" "$OUTPUT.repaired"
        _dur=$(( $(date +%s 2>/dev/null || echo 0) - START_TS ))
        log "SUCCESS output_size=$(wc -c < "$OUTPUT" 2>/dev/null | tr -d ' ') (passthrough, no ffmpeg; ${RATEARG:-1.0x})"
        echo "---- END pid=$$ RESULT=OK dur=${_dur}s input=$in_size out=$(wc -c < "$OUTPUT" 2>/dev/null | tr -d ' ') ----" >> "$FULLLOG" 2>/dev/null
        release_hashlock
        exit 0
    fi

    rm -f "$RAW" "$OUTPUT" "$META" "$VLOG"
    if [ "$n" -lt "$RETRIES" ]; then
        _wait=$(awk "BEGIN{print 1*(2^$n)}" 2>/dev/null)
        [ -z "$_wait" ] && _wait=1
        # 退避等待也受剩余预算约束；预算不足则直接结束不再重试
        if budget_exhausted; then
            log "budget exhausted — skip backoff, give up retrying"
            break
        fi
        log "backoff sleep ${_wait}s"
        sleep "$_wait"
    fi
    n=$((n + 1))
done

echo "cloud TTS 请求失败（relay=$RELAY_BASE —— 检查中继是否在线 / 地址是否正确 / 设备能否访问公网）；详见 $LOG" >&2
log "FAILED after retries"
_dur=$(( $(date +%s 2>/dev/null || echo 0) - START_TS ))
echo "---- END pid=$$ RESULT=FAIL dur=${_dur}s input=$in_size ----" >> "$FULLLOG" 2>/dev/null
release_hashlock
release_slot
exit 1
