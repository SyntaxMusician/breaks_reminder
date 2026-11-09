#!/bin/bash
# install.sh — установка / обновление / удаление breaks_reminder
#
# Использование:
#   ./install.sh              установить или обновить
#   ./install.sh --systemd    автозапуск через systemd --user (юниты, journalctl)
#   ./install.sh --autostart  автозапуск через классический .desktop (~/.config/autostart)
#   ./install.sh --uninstall  удалить всё
#
# Без аргументов бэкенд автозапуска выбирается автоматически:
# systemd --user, если graphical-session.target активен, иначе .desktop-автозапуск.
#
# Обновление поверх старой версии (старый install.sh) выполняется этой же
# командой: скрипты перезаписываются, старые процессы останавливаются,
# ярлыки и автозапуск обновляются.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
APP_DIR="$HOME/.local/share/applications"
AUTOSTART_DIR="$HOME/.config/autostart"
SYSTEMD_DIR="$HOME/.config/systemd/user"
STATE_DIR="$HOME/.local/state/breaks_reminder"
CONF_FILE="$HOME/.config/breaks_reminder.conf"
CONF_SRC="$SCRIPT_DIR/breaks_reminder.conf.example"

PY="breaks_reminder.py"
WATCHER="lock_state_watcher.sh"
TOGGLE="toggle_pause.sh"
GENMON="breaks_genmon.sh"
UNITS="breaks-reminder.service breaks-reminder-watcher.service"
AUTOSTART_ENTRY="breaks_reminder_autostart.desktop"

MODE="install"
USE_SYSTEMD="auto"

usage() {
    echo "Использование: ./install.sh [--systemd | --autostart] | --uninstall | --help"
}

ok()   { echo "  ✓ $*"; }
warn() { echo "  ⚠ $*"; }

# Остановить запущенные процессы (при обновлении или удалении):
# сначала TERM, ждём корректного завершения до ~3 с, затем KILL.
stop_running() {
    pkill -f "$BIN_DIR/$PY"      2>/dev/null || true
    pkill -f "$BIN_DIR/$WATCHER" 2>/dev/null || true
    for _ in 1 2 3 4 5 6; do
        pgrep -f "$BIN_DIR/$PY" >/dev/null 2>&1 || pgrep -f "$BIN_DIR/$WATCHER" >/dev/null 2>&1 || break
        sleep 0.5
    done
    pgrep -f "$BIN_DIR/$PY"      >/dev/null 2>&1 && pkill -9 -f "$BIN_DIR/$PY"      2>/dev/null || true
    pgrep -f "$BIN_DIR/$WATCHER" >/dev/null 2>&1 && pkill -9 -f "$BIN_DIR/$WATCHER" 2>/dev/null || true
    sleep 0.3
}

# ---------- разбор аргументов ----------
while [ $# -gt 0 ]; do
    case "$1" in
        --systemd)   USE_SYSTEMD="yes" ;;
        --autostart) USE_SYSTEMD="no" ;;
        --uninstall) MODE="uninstall" ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "Неизвестный аргумент: $1"; usage; exit 1 ;;
    esac
    shift
done

# ---------- удаление ----------
uninstall() {
    echo "=== Удаление breaks_reminder ==="
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user disable --now $UNITS >/dev/null 2>&1 || true
        for u in $UNITS; do rm -f "$SYSTEMD_DIR/$u"; done
        systemctl --user daemon-reload >/dev/null 2>&1 || true
    fi
    rm -f "$AUTOSTART_DIR/$AUTOSTART_ENTRY"
    rm -f "$APP_DIR/breaks_reminder.desktop" "$APP_DIR/toggle_breaks_pause.desktop"

    stop_running

    rm -f "$BIN_DIR/$PY" "$BIN_DIR/$WATCHER" "$BIN_DIR/$TOGGLE" "$BIN_DIR/$GENMON"
    rm -f "$HOME/.breaks_paused" "$HOME/.breaks_paused.timer" "$HOME/.screen_locked"

    local desk
    desk="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
    for d in "$desk" "$HOME/Рабочий стол" "$HOME/Desktop"; do
        if [ -n "$d" ] && [ -d "$d" ]; then
            rm -f "$d/breaks_reminder.desktop" "$d/toggle_breaks_pause.desktop"
        fi
    done

    echo "  ✓ Скрипты, ярлыки, автозапуск и флаги удалены"
    echo "  Оставлены (удалите вручную при желании):"
    echo "      $CONF_FILE  (конфиг)"
    echo "      $STATE_DIR/ (логи)"
}

if [ "$MODE" = "uninstall" ]; then
    uninstall
    exit 0
fi

# ---------- установка / обновление ----------
echo "=== Установка breaks_reminder ==="
echo

echo "Проверка зависимостей:"
if command -v python3 >/dev/null 2>&1; then
    ok "python3"
else
    echo "  ✗ python3 обязателен — установка прервана"
    exit 1
fi
for spec in \
    "notify-send:уведомления-карточки (пакет libnotify-bin / xfce4-notifyd)" \
    "xprintidle:умная задержка при вводе и детект «ушёл от стола» (пакет xprintidle)" \
    "paplay:звук при напоминании «разминка» (пакет pulseaudio-utils)" \
    "dbus-monitor:мгновенные события блокировки экрана (пакет dbus)" \
    "zenity:резервный показ уведомлений"; do
    c="${spec%%:*}"
    desc="${spec#*:}"
    if command -v "$c" >/dev/null 2>&1; then
        ok "$c — $desc"
    else
        warn "нет $c — $desc (не критично)"
    fi
done
python3 -m py_compile "$SCRIPT_DIR/$PY" && ok "breaks_reminder.py: синтаксис ок"
echo

echo "[1/6] Остановка ранее запущенной версии (если была)"
stop_running

echo "[2/6] Скрипты → $BIN_DIR"
mkdir -p "$BIN_DIR"
install -m 755 "$SCRIPT_DIR/$PY" "$SCRIPT_DIR/$WATCHER" "$SCRIPT_DIR/$TOGGLE" "$SCRIPT_DIR/$GENMON" "$BIN_DIR/"
ok "breaks_reminder.py, lock_state_watcher.sh, toggle_pause.sh, breaks_genmon.sh"

echo "[3/6] Конфиг"
if [ -f "$CONF_FILE" ]; then
    ok "$CONF_FILE уже существует — сохранён без изменений"
elif [ -f "$CONF_SRC" ]; then
    mkdir -p "$(dirname "$CONF_FILE")"
    cp "$CONF_SRC" "$CONF_FILE"
    ok "создан $CONF_FILE (правится в любом редакторе, применяется на лету)"
else
    warn "нет $CONF_SRC — программа будет работать со значениями по умолчанию"
fi

echo "[4/6] Ярлыки"
mkdir -p "$APP_DIR"
for f in breaks_reminder.desktop toggle_breaks_pause.desktop; do
    cp "$SCRIPT_DIR/$f" "$APP_DIR/"
    if [ "$f" = "toggle_breaks_pause.desktop" ]; then
        exe="$BIN_DIR/$TOGGLE"
    else
        exe="$BIN_DIR/$PY"
    fi
    sed -i "s|^Exec=.*|Exec=$exe|" "$APP_DIR/$f"
    ok "меню приложений: $f"
done

desk="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
if [ -z "$desk" ] || [ ! -d "$desk" ]; then
    for d in "$HOME/Рабочий стол" "$HOME/Desktop"; do
        if [ -d "$d" ]; then
            desk="$d"
            break
        fi
    done
fi
if [ -n "${desk:-}" ] && [ -d "$desk" ]; then
    for f in breaks_reminder.desktop toggle_breaks_pause.desktop; do
        cp "$APP_DIR/$f" "$desk/"
        chmod +x "$desk/$f" 2>/dev/null || true
    done
    ok "рабочий стол: $desk"
    warn "если ярлык не запускается двойным кликом — ПКМ по нему → «Разрешить запуск»"
else
    warn "папка рабочего стола не найдена — ярлыки на стол не ставим"
fi

if [ "$USE_SYSTEMD" = "auto" ]; then
    if command -v systemctl >/dev/null 2>&1 \
       && systemctl --user is-active -q graphical-session.target 2>/dev/null; then
        USE_SYSTEMD="yes"
    else
        USE_SYSTEMD="no"
    fi
fi

if [ "$USE_SYSTEMD" = "yes" ]; then
    echo "[5/6] Автозапуск: systemd --user"
    mkdir -p "$SYSTEMD_DIR"
    for u in $UNITS; do
        cp "$SCRIPT_DIR/systemd/$u" "$SYSTEMD_DIR/"
        ok "$u"
    done
    rm -f "$AUTOSTART_DIR/$AUTOSTART_ENTRY"   # чтобы не было двух копий
    systemctl --user daemon-reload
    systemctl --user enable breaks-reminder.service breaks-reminder-watcher.service >/dev/null 2>&1 || true
else
    echo "[5/6] Автозапуск: ~/.config/autostart"
    mkdir -p "$AUTOSTART_DIR"
    cp "$SCRIPT_DIR/$AUTOSTART_ENTRY" "$AUTOSTART_DIR/"
    sed -i "s|^Exec=.*|Exec=$BIN_DIR/$PY|" "$AUTOSTART_DIR/$AUTOSTART_ENTRY"
    ok "$AUTOSTART_ENTRY"
    if command -v systemctl >/dev/null 2>&1; then
        # если раньше стояли юниты — убираем, чтобы не было двух копий
        systemctl --user disable --now $UNITS >/dev/null 2>&1 || true
        for u in $UNITS; do rm -f "$SYSTEMD_DIR/$u"; done
        systemctl --user daemon-reload >/dev/null 2>&1 || true
    fi
fi

echo "[6/6] Запуск"
if [ "$USE_SYSTEMD" = "yes" ]; then
    systemctl --user daemon-reload
    systemctl --user restart breaks-reminder.service breaks-reminder-watcher.service
    ok "проверка: systemctl --user status breaks-reminder breaks-reminder-watcher"
    ok "логи: journalctl --user -u breaks-reminder -f"
else
    mkdir -p "$STATE_DIR"
    start_bg() {
        local logfile="$2"
        # простая ротация: если лог разросся, оставляем последние 2000 строк
        if [ -f "$logfile" ] && [ "$(stat -c%s "$logfile" 2>/dev/null || echo 0)" -gt 5242880 ]; then
            tail -n 2000 "$logfile" > "$logfile.tmp" && mv "$logfile.tmp" "$logfile"
        fi
        setsid nohup "$1" >> "$logfile" 2>&1 < /dev/null &
    }
    start_bg "$BIN_DIR/$PY"      "$STATE_DIR/reminder.log"
    start_bg "$BIN_DIR/$WATCHER" "$STATE_DIR/watcher.log"
    ok "логи: $STATE_DIR/reminder.log, $STATE_DIR/watcher.log"
fi

echo
echo "============================================"
echo "  ✅ Готово. Напоминания работают."
echo "============================================"
echo
echo "📌 Пауза:      toggle_pause.sh [on|off|минуты]  (ярлык «Пауза напоминаний»)"
echo "📌 Конфиг:     $CONF_FILE (интервалы, звук, задержки)"
echo "📌 Уведомления не крадут фокус клавиатуры и откладываются, пока вы печатаете"
echo "📌 Индикатор на панель: xfce4-genmon-plugin + $BIN_DIR/$GENMON"
echo "📌 Удаление:   ./install.sh --uninstall"