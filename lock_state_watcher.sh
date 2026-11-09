#!/bin/bash
# lock_state_watcher — следит за блокировкой экрана и ведёт флаг ~/.screen_locked
#
# Как работает:
#   * если есть dbus-monitor — слушает сигналы ActiveChanged
#     (org.xfce.ScreenSaver / org.freedesktop.ScreenSaver / org.gnome.ScreenSaver)
#     и мгновенно обновляет флаг; параллельно раз в POLL_INTERVAL секунд сверяет
#     флаг с реальным состоянием (страховка от пропущенных событий);
#   * если dbus-monitor нет — просто опрашивает состояние каждые FAST_POLL_INTERVAL сек.
#
# Состояние определяется через (первый доступный):
#   loginctl LockedHint, xfce4-screensaver, light-locker, gnome-screensaver,
#   xscreensaver, DPMS («монитор выключен» = пользователь отошёл).
#   «Ушёл по idle» здесь не определяется — это делает breaks_reminder.py
#   через xprintidle (параметр afk_reset в конфиге).
#
# В флаг записывается PID watcher'а: breaks_reminder.py считает флаг устаревшим,
# если процесс с этим PID больше не существует (watcher умер после сбоя).
#
# Переменные окружения: LOCK_WATCHER_POLL (сек, по умолчанию 30),
#                       LOCK_WATCHER_FAST_POLL (сек, по умолчанию 2).

LOCK_FLAG="$HOME/.screen_locked"
POLL_INTERVAL="${LOCK_WATCHER_POLL:-30}"
FAST_POLL_INTERVAL="${LOCK_WATCHER_FAST_POLL:-2}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# --- окружение (для запуска из autostart/systemd, где DISPLAY может быть пуст) ---
if [ -z "${DISPLAY:-}" ] && [ -d /tmp/.X11-unix ]; then
    first_x=$(ls /tmp/.X11-unix 2>/dev/null | sed -n 's/^X\([0-9]\{1,\}\)$/\1/p' | head -n 1)
    [ -n "$first_x" ] && export DISPLAY=":$first_x"
fi
if [ -z "${XAUTHORITY:-}" ] && [ -f "$HOME/.Xauthority" ]; then
    export XAUTHORITY="$HOME/.Xauthority"
fi
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "/run/user/$(id -u)/bus" ]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
fi

set_locked() {
    # перезаписываем файл только при смене состояния, чтобы не дёргать mtime
    [ "$(cat "$LOCK_FLAG" 2>/dev/null)" = "$$" ] || echo "$$" > "$LOCK_FLAG"
}

set_unlocked() {
    rm -f "$LOCK_FLAG"
}

check_locked() {
    # 1) loginctl: LockedHint (его ставят light-locker, xfce4-screensaver, gnome-screensaver)
    if command -v loginctl >/dev/null 2>&1; then
        sid="${XDG_SESSION_ID:-}"
        if [ -z "$sid" ]; then
            sid=$(loginctl list-sessions --no-legend 2>/dev/null \
                  | awk -v u="$(id -un)" '$3 == u {print $1; exit}')
        fi
        if [ -n "$sid" ] && loginctl show-session "$sid" -p LockedHint 2>/dev/null | grep -qi yes; then
            return 0
        fi
    fi

    # 2) демоны хранителей экрана.
    #    Сначала отсекаем «не активен» ("unlocked"/"not active"), иначе эти слова
    #    ложно совпадают с шаблонами "locked"/"active".
    for cmd in xfce4-screensaver-command light-locker-command gnome-screensaver-command xscreensaver-command; do
        command -v "$cmd" >/dev/null 2>&1 || continue
        case "$cmd" in
            xscreensaver-command) out=$("$cmd" -time 2>/dev/null || true) ;;
            *)                    out=$("$cmd" -q 2>/dev/null || true) ;;
        esac
        lc=$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')
        case "$lc" in
            *"not active"*|*"not running"*|*"not locked"*|*"currently unlocked"*) continue ;;
            *"is active"*|*"is running"*|*"currently locked"*|*"locked at"*|*"blanked at"*) return 0 ;;
        esac
    done

    # 3) DPMS: монитор погашен — пользователь точно отошёл
    if command -v xset >/dev/null 2>&1 && xset -q 2>/dev/null | grep -qi 'monitor is off'; then
        return 0
    fi

    return 1
}

reconcile() {
    if check_locked; then set_locked; else set_unlocked; fi
}

dbus_watch() {
    dbus-monitor --session \
        "type='signal',interface='org.xfce.ScreenSaver',member='ActiveChanged'" \
        "type='signal',interface='org.freedesktop.ScreenSaver',member='ActiveChanged'" \
        "type='signal',interface='org.gnome.ScreenSaver',member='ActiveChanged'" 2>/dev/null |
    while IFS= read -r line; do
        case "$line" in
            *boolean\ true*)  log "D-Bus: экран заблокирован";  set_locked ;;
            *boolean\ false*) log "D-Bus: экран разблокирован"; set_unlocked ;;
        esac
    done
}

cleanup() {
    # убиваем ветку dbus-watch вместе с её dbus-monitor
    if [ -n "${DBUS_PID:-}" ]; then
        pkill -P "$DBUS_PID" 2>/dev/null || true
        kill "$DBUS_PID" 2>/dev/null || true
    fi
    rm -f "$LOCK_FLAG"
}

# «сон», прерываемый сигналами: trap в bash откладывается до завершения
# foreground-команды, поэтому спим в фоне и ждём через wait
napping() {
    sleep "$1" &
    NAP_PID=$!
    wait "$NAP_PID"
}

main() {
    log "стартовал (PID $$), флаг: $LOCK_FLAG"
    reconcile   # чистим устаревший флаг сразу при старте

    trap 'cleanup; exit 0' TERM INT
    trap 'cleanup' EXIT

    if command -v dbus-monitor >/dev/null 2>&1; then
        dbus_watch &
        DBUS_PID=$!
        napping 3   # если шины сессии нет, dbus-monitor завершается мгновенно
        if kill -0 "$DBUS_PID" 2>/dev/null; then
            log "слушаю D-Bus + сверка состояния каждые ${POLL_INTERVAL} c"
            while kill -0 "$DBUS_PID" 2>/dev/null; do
                napping "$POLL_INTERVAL"
                kill -0 "$DBUS_PID" 2>/dev/null || break
                reconcile
            done
        fi
        log "WARN: dbus-monitor не работает (нет шины/демона с сигналами) — опрос каждые ${FAST_POLL_INTERVAL} c"
    else
        log "dbus-monitor не найден — опрос состояния каждые ${FAST_POLL_INTERVAL} c"
    fi

    while true; do
        napping "$FAST_POLL_INTERVAL"
        reconcile
    done
}

main "$@"