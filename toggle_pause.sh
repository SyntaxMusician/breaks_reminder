#!/bin/bash
# toggle_pause.sh — пауза напоминаний breaks_reminder
#
# Использование:
#   toggle_pause.sh          переключить паузу
#   toggle_pause.sh on       включить паузу (алиас: pause)
#   toggle_pause.sh off      выключить паузу (алиас: resume)
#   toggle_pause.sh 30       пауза на 30 минут, потом возобновится сама
#
# Флаг: ~/.breaks_paused

PAUSE_FLAG="$HOME/.breaks_paused"
TIMER_PID_FILE="$HOME/.breaks_paused.timer"

usage() { echo "Использование: $0 [on | off | toggle | минуты]" >&2; }

notify() {  # $1 = текст, $2 = иконка
    if command -v notify-send >/dev/null 2>&1; then
        notify-send -a breaks_reminder -i "$2" -t 5000 "breaks_reminder" "$1" 2>/dev/null && return
    fi
    if command -v zenity >/dev/null 2>&1; then
        zenity --info --title="breaks_reminder" --text="$1" 2>/dev/null || true
    fi
}

cancel_timer() {
    if [ -f "$TIMER_PID_FILE" ]; then
        kill "$(cat "$TIMER_PID_FILE" 2>/dev/null)" 2>/dev/null || true
        rm -f "$TIMER_PID_FILE"
    fi
}

start_timer() {  # $1 — минуты
    (
        sleep "$(( $1 * 60 ))"
        rm -f "$PAUSE_FLAG"
        notify "▶ Пауза ($1 мин) закончилась — напоминания возобновлены" appointment-soon
    ) &
    echo $! > "$TIMER_PID_FILE"
    disown 2>/dev/null || true
}

pause_on() {
    touch "$PAUSE_FLAG"
    cancel_timer
    notify "⏸ Пауза включена — напоминания приостановлены" appointment-missed
}

pause_off() {
    cancel_timer
    rm -f "$PAUSE_FLAG"
    notify "▶ Пауза снята — напоминания возобновлены" appointment-soon
}

case "${1:-toggle}" in
    on|pause)
        pause_on
        ;;
    off|resume)
        pause_off
        ;;
    toggle)
        if [ -f "$PAUSE_FLAG" ]; then
            pause_off
        else
            pause_on
        fi
        ;;
    *[!0-9]*)
        usage
        exit 1
        ;;
    *)
        minutes="$1"
        touch "$PAUSE_FLAG"
        cancel_timer
        start_timer "$minutes"
        notify "⏸ Пауза на ${minutes} мин — потом возобновится сама" appointment-missed
        ;;
esac