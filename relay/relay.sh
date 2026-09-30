#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# TTS 中继 —— Termux 单窗口控制脚本
# 只要你一个窗口就能完成所有操作，不需要新建会话。
#
# 用法（先 ./relay.sh setup 做一次安装）：
#   ./relay.sh setup     安装依赖 + 获取屏幕常亮
#   ./relay.sh start     启动中继（后台常驻，断开 Termux 也活着）
#   ./relay.sh status    查看是否活着 + 最近 15 行请求日志
#   ./relay.sh log       实时滚动日志（Ctrl+C 退出）
#   ./relay.sh test      本地自检：合成一句，显示返回字节数
#   ./relay.sh restart   重启
#   ./relay.sh stop      停止
#
# 可选微调（启动前加在命令前面即可）：
#   TTS_WAV_RATE=22050 ./relay.sh start    采样率更高 → 人声更亮（文件大 37%）
#   TTS_RATE=+20%      ./relay.sh start    整体语速加快 20%
#   临时调速不改配置：Kindle 设置里的接口地址末尾加  &rate=+20%
# ============================================================

APP=tts_relay_android.py
# 从本脚本自身所在目录加载 py：无论你把这两个文件放哪个目录，启动方式都一样
# （不再写死 ~/ ，避免"文件在别的目录就报找不到"）。
# 仍可用环境变量强制指定目录： TTS_RELAY_DIR=/sdcard/Download bash relay.sh start
DIR="${TTS_RELAY_DIR:-$(cd "$(dirname "$0")" && pwd)}"
LOG="$DIR/relay.log"
SCRIPT="$DIR/$APP"

cd "$DIR" || exit 1

is_running() {
    pgrep -f "$APP" >/dev/null 2>&1
}

case "$1" in
  setup)
    echo "== 安装依赖 =="
    pkg update -y && pkg install python ffmpeg termux-tools -y
    pip install --upgrade pip
    pip install edge-tts flask
    termux-wake-lock && echo "已开启唤醒锁（防止息屏被杀）"
    echo "== 完成 =="
    ;;

  start)
    if is_running; then
        echo "中继已在运行，PID=$(pgrep -f "$APP" | tr '\n' ' ')"
        ./relay.sh status
        exit 0
    fi
    if [ ! -f "$SCRIPT" ]; then
        echo "找不到 $SCRIPT"
        echo "请把 $APP 放到家目录：$DIR"
        exit 1
    fi
    termux-wake-lock 2>/dev/null
    setsid nohup python "$SCRIPT" >> "$LOG" 2>&1 < /dev/null &
    NEW_PID=$!
    sleep 3
    if is_running; then
        echo "✅ 中继已启动，PID=$NEW_PID（后台常驻）"
        echo "   日志：$LOG"
        grep -m1 "http://" "$LOG" 2>/dev/null && true
    else
        echo "❌ 启动失败，以下是日志尾部："
        tail -n 20 "$LOG"
    fi
    ;;

  stop)
    pkill -f "$APP" 2>/dev/null
    sleep 1
    if is_running; then echo "未能停止"; else echo "已停止"; fi
    ;;

  restart)
    ./relay.sh stop
    sleep 1
    ./relay.sh start
    ;;

  status)
    if is_running; then
        echo "✅ 运行中，PID=$(pgrep -f "$APP" | tr '\n' ' ')"
    else
        echo "❌ 未运行（执行 ./relay.sh start 启动）"
    fi
    echo "---- 最近 15 行日志 ----"
    tail -n 15 "$LOG" 2>/dev/null || echo "(无日志)"
    ;;

  log)
    echo "实时日志，Ctrl+C 退出"
    tail -f "$LOG"
    ;;

  test)
    echo "合成测试中，请稍等几秒..."
    curl -s "http://127.0.0.1:5000/tts?text=%E6%B5%8B%E8%AF%95%E4%B8%AD%E6%96%87%E6%9C%97%E8%AF%BB" \
         -o "$DIR/t.wav"
    SZ=$(stat -c%s "$DIR/t.wav" 2>/dev/null || echo 0)
    if [ "$SZ" -gt 10000 ]; then
        echo "✅ 正常，返回 $SZ 字节"
    else
        echo "❌ 异常，只有 $SZ 字节（检查中继是否运行：./relay.sh status）"
    fi
    ;;

  *)
    echo "用法: ./relay.sh {setup|start|stop|restart|status|log|test}"
    ;;
esac
