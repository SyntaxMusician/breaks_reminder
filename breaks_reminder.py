#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""breaks_reminder — напоминания об отдыхе для глаз и разминке.

Как работает:
  * считает активное время, пока экран не заблокирован и не включена пауза;
  * каждые eye_interval минут — карточка «отдых для глаз» (обычная, исчезает сама);
  * каждые break_interval минут — карточка «разминка» (critical + звук,
    в xfce4-notifyd не исчезает, пока не закрыта);
  * если пользователь прямо сейчас печатает/водит мышью (xprintidle),
    карточка откладывается до паузы в вводе, но не более чем на max_defer секунд;
  * если за столом никого >= afk_reset минут — таймеры сбрасываются
    (перерыв уже был, напоминания не копятся «стадом» по возвращении);
  * при блокировке экрана (флаг ~/.screen_locked от lock_state_watcher.sh)
    и при паузе (флаг ~/.breaks_paused) таймеры сбрасываются;
  * конфиг ~/.config/breaks_reminder.conf перечитывается на лету.

Зависимости: python3 (только stdlib). Опционально: notify-send (уведомления),
xprintidle (умная задержка, детект AFK), paplay (звук), zenity (fallback).
Рассчитано на X11; под Wayland умные функции тихо отключаются.
"""

import configparser
import fcntl
import os
import shutil
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime, timedelta

APP_NAME = "breaks_reminder"
HOME = os.path.expanduser("~")
LOCK_FLAG = os.path.join(HOME, ".screen_locked")
PAUSE_FLAG = os.path.join(HOME, ".breaks_paused")
CONFIG_PATH = os.path.join(HOME, ".config", "breaks_reminder.conf")
INSTANCE_LOCK = "/tmp/breaks_reminder-{}.lock".format(os.getuid())

# Значения по умолчанию (перезакрываются конфигом; раздел в конфиге не важен)
DEFAULTS = {
    "eye_interval": 20,          # минут между напоминаниями про глаза
    "break_interval": 45,        # минут между напоминаниями «встать и размяться»
    "combine_window": 90,        # сек: сработали почти вместе — показать одной карточкой
    "quiet_ms": 2000,            # idle меньше этого = пользователь печатает/водит мышь
    "max_defer": 180,            # сек: максимальное ожидание паузы в вводе
    "afk_reset": 5,              # минут бездействия = перерыв уже был
    "fullscreen_defer": False,   # откладывать карточки, пока активное окно в fullscreen
    "eye_urgency": "normal",
    "eye_expire_ms": 10000,
    "eye_icon": "dialog-information",
    "break_urgency": "critical",
    "break_expire_ms": 0,        # 0 = поведение демона по умолчанию
    "break_icon": "appointment-soon",
    "sound": True,
    "sound_file": "/usr/share/sounds/freedesktop/stereo/bell.oga",
    "notify_on_start": False,
    "log_status": True,
}

cfg = dict(DEFAULTS)
cfg_mtime = None


def log(msg):
    print(f"[{datetime.now():%H:%M:%S}] {msg}", flush=True)


def load_config():
    """Читает конфиг. Разделы не важны, ключи перезакрывают значения по умолчанию."""
    conf = dict(DEFAULTS)
    parser = configparser.ConfigParser(inline_comment_prefixes=("#", ";"))
    try:
        found = parser.read(CONFIG_PATH, encoding="utf-8")
    except (configparser.Error, OSError, UnicodeDecodeError) as exc:
        log(f"WARN: конфиг {CONFIG_PATH} не прочитан ({exc}); использую значения по умолчанию")
        return conf
    if not found:
        return conf
    for section in parser.sections():
        for key in parser.options(section):
            if key not in DEFAULTS:
                continue
            default = DEFAULTS[key]
            try:
                if isinstance(default, bool):
                    conf[key] = parser.getboolean(section, key)
                elif isinstance(default, int):
                    conf[key] = parser.getint(section, key)
                else:
                    conf[key] = parser.get(section, key).strip()
            except ValueError:
                log(f"WARN: неверное значение '{key} = {parser.get(section, key)}'; "
                    f"использую {default!r}")
    return conf


def maybe_reload_config():
    """Перечитывает конфиг, если файл изменился (mtime)."""
    global cfg, cfg_mtime
    try:
        mtime = os.stat(CONFIG_PATH).st_mtime
    except OSError:
        return
    if cfg_mtime is None:
        cfg_mtime = mtime
        return
    if mtime != cfg_mtime:
        cfg_mtime = mtime
        cfg = load_config()
        log("конфиг перечитан")


def ensure_x_env():
    """DISPLAY/XAUTHORITY/DBus — чтобы работало из systemd --user, autostart и cron."""
    if not os.environ.get("DISPLAY") and os.path.isdir("/tmp/.X11-unix"):
        for entry in sorted(os.listdir("/tmp/.X11-unix")):
            if entry.startswith("X") and entry[1:].isdigit():
                os.environ["DISPLAY"] = ":" + entry[1:]
                break
    if not os.environ.get("XAUTHORITY") and os.path.exists(os.path.join(HOME, ".Xauthority")):
        os.environ["XAUTHORITY"] = os.path.join(HOME, ".Xauthority")
    if not os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
        bus = f"/run/user/{os.getuid()}/bus"
        if os.path.exists(bus):
            os.environ["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=" + bus


# ---------- вспомогательные инструменты ----------

XPRINTIDLE = shutil.which("xprintidle")
XPROP = shutil.which("xprop")
NOTIFY_SEND = shutil.which("notify-send")
ZENITY = shutil.which("zenity")
PAPLAY = shutil.which("paplay")


def get_idle_ms():
    """Миллисекунды с последнего события ввода; None — определить нечем."""
    if not XPRINTIDLE:
        return None
    try:
        res = subprocess.run([XPRINTIDLE], capture_output=True, text=True, timeout=3)
        return int(res.stdout.strip() or "0")
    except (subprocess.SubprocessError, ValueError):
        return None


def fullscreen_active():
    """True, если активное окно развёрнуто на весь экран (видео, созвоны)."""
    if not XPROP:
        return False
    try:
        out = subprocess.run([XPROP, "-root", "-notype", "_NET_ACTIVE_WINDOW"],
                             capture_output=True, text=True, timeout=3).stdout
        win = out.split()[-1] if out.split() else ""
        if not win.startswith("0x"):
            return False
        state = subprocess.run([XPROP, "-id", win, "-notype", "_NET_WM_STATE"],
                               capture_output=True, text=True, timeout=3).stdout
        return "_NET_WM_STATE_FULLSCREEN" in state
    except subprocess.SubprocessError:
        return False


def lock_flag_is_stale():
    """Флаг блокировки устарел, если watcher, оставивший в нём свой PID, умер."""
    try:
        with open(LOCK_FLAG, "r", encoding="utf-8", errors="replace") as fh:
            content = fh.read().strip()
    except OSError:
        return False
    if content.isdigit():
        try:
            os.kill(int(content), 0)   # проверка существования процесса
            return False
        except ProcessLookupError:
            return True
        except PermissionError:
            return False
    # флаг старого формата (просто текст "locked"): считаем живым не дольше 10 минут
    try:
        return time.time() - os.stat(LOCK_FLAG).st_mtime > 600
    except OSError:
        return False


# ---------- уведомления ----------

def show_notification(title, message, urgency="normal", expire_ms=10000,
                      icon=None, sound=None):
    """Уведомление: notify-send (карточка в углу, фокус не крадёт) с fallback на zenity."""
    if sound and PAPLAY and os.path.exists(sound):
        subprocess.Popen([PAPLAY, sound],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if NOTIFY_SEND:
        cmd = [NOTIFY_SEND, "-u", urgency, "-a", APP_NAME]
        if icon:
            cmd += ["-i", icon]
        if expire_ms and expire_ms > 0:
            cmd += ["-t", str(expire_ms)]
        cmd += [title, message]
        subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    elif ZENITY:
        # запасной вариант: отдельный процесс, чтобы не блокировать основной цикл
        subprocess.Popen([ZENITY, "--info", "--title", title, "--text", message],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        log(f"WARN: нет ни notify-send, ни zenity — уведомление пропущено: {title}")
    log(f"🔔 {title}: {message}")


def notify_when_quiet(title, message, **kwargs):
    """Показать карточку, когда в вводе появится пауза (но не позже max_defer секунд)."""
    idle = get_idle_ms()
    if idle is None:
        show_notification(title, message, **kwargs)   # idle не определить — показываем сразу
        return
    waited = 0
    while waited < cfg["max_defer"]:
        # пока ждали, включили паузу или заблокировали экран — карточка не нужна
        if os.path.exists(PAUSE_FLAG) or os.path.exists(LOCK_FLAG):
            return
        if idle >= cfg["quiet_ms"] and not (cfg["fullscreen_defer"] and fullscreen_active()):
            break
        time.sleep(5)
        waited += 5
        idle = get_idle_ms() or 0
    show_notification(title, message, **kwargs)


def notify_async(title, message, **kwargs):
    threading.Thread(target=notify_when_quiet, args=(title, message),
                     kwargs=kwargs, daemon=True).start()


# ---------- основной цикл ----------

def minutes(td):
    return max(0, int(td.total_seconds() // 60))


def eye_params():
    return dict(urgency=cfg["eye_urgency"], expire_ms=cfg["eye_expire_ms"],
                icon=cfg["eye_icon"])


def break_params():
    return dict(urgency=cfg["break_urgency"], expire_ms=cfg["break_expire_ms"],
                icon=cfg["break_icon"],
                sound=cfg["sound_file"] if cfg["sound"] else None)


def reset_timers():
    return (timedelta(), timedelta(minutes=cfg["eye_interval"]),
            timedelta(minutes=cfg["break_interval"]))


def run():
    global cfg, cfg_mtime
    ensure_x_env()

    # один экземпляр на пользователя (двойной запуск = двойные уведомления)
    try:
        lock_fp = open(INSTANCE_LOCK, "w")
    except OSError:
        lock_fp = None
    if lock_fp is not None:
        try:
            fcntl.flock(lock_fp, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            sys.exit(f"{APP_NAME}: уже запущен (флаг экземпляра: {INSTANCE_LOCK})")
        lock_fp.write(str(os.getpid()))
        lock_fp.flush()

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: sys.exit(0))

    cfg = load_config()
    try:
        cfg_mtime = os.stat(CONFIG_PATH).st_mtime
    except OSError:
        cfg_mtime = 0

    active, next_eye, next_break = reset_timers()
    was_paused = False
    last_tick = time.monotonic()
    last_status = datetime.now()

    if cfg["notify_on_start"]:
        show_notification(APP_NAME, "Напоминания запущены ✅", expire_ms=5000,
                          icon=cfg["eye_icon"])
    log(f"стартовал: глаза каждые {cfg['eye_interval']} мин, "
        f"разминка каждые {cfg['break_interval']} мин, конфиг: {CONFIG_PATH}")

    try:
        while True:
            time.sleep(1)
            now_mono = time.monotonic()
            delta, last_tick = max(0.0, now_mono - last_tick), now_mono
            now = datetime.now()
            maybe_reload_config()

            # --- пауза ---
            if os.path.exists(PAUSE_FLAG):
                if not was_paused:
                    log("⏸ пауза — напоминания приостановлены")
                    was_paused = True
                active, next_eye, next_break = reset_timers()
                continue
            if was_paused:
                log("▶ напоминания возобновлены")
                was_paused = False

            # --- блокировка экрана ---
            if os.path.exists(LOCK_FLAG):
                if lock_flag_is_stale():
                    try:
                        os.remove(LOCK_FLAG)
                        log("WARN: удалён устаревший флаг блокировки (watcher не работает?)")
                    except OSError:
                        pass
                else:
                    active, next_eye, next_break = reset_timers()
                    continue

            # --- AFK: за столом давно никого ---
            idle = get_idle_ms()
            if idle is not None and idle >= cfg["afk_reset"] * 60000:
                active, next_eye, next_break = reset_timers()
                continue

            # считаем активное время
            active += timedelta(seconds=delta)

            # --- напоминания ---
            eye_due = active >= next_eye
            break_due = active >= next_break
            if eye_due and (break_due or (next_break - active).total_seconds()
                            <= cfg["combine_window"]):
                next_eye += timedelta(minutes=cfg["eye_interval"])
                next_break += timedelta(minutes=cfg["break_interval"])
                log("оба напоминания пришли вместе — показываю одной карточкой")
                notify_async("Пора отдохнуть",
                             "Отведи взгляд вдаль 👀 и встань, разомнись 🧘",
                             **break_params())
            elif eye_due:
                next_eye += timedelta(minutes=cfg["eye_interval"])
                notify_async("Отдых для глаз", "Посмотри вдаль или в окно 👀",
                             **eye_params())
            elif break_due:
                next_break += timedelta(minutes=cfg["break_interval"])
                notify_async("Разминка", "Пора встать и размяться 🧘",
                             **break_params())

            if cfg["log_status"] and (now - last_status).total_seconds() >= 60:
                last_status = now
                log(f"активно {minutes(active)} мин | "
                    f"глаза через {minutes(next_eye - active)} мин | "
                    f"разминка через {minutes(next_break - active)} мин")
    finally:
        log("остановлен")


if __name__ == "__main__":
    run()