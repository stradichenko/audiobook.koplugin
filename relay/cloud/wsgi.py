# alwaysdata WSGI 入口
# 站点类型选 Python 时，把本文件路径填到 WSGI 文件一栏（如 www/wsgi.py）
import sys, os

HOME = os.path.expanduser("~")
if HOME not in sys.path:
    sys.path.insert(0, HOME)
if os.path.join(HOME, "www") not in sys.path:
    sys.path.insert(0, os.path.join(HOME, "www"))

from tts_relay_cloud import app as application  # noqa: E402,F401
