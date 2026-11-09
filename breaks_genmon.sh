#!/bin/bash
# breaks_genmon.sh — индикатор состояния для панели XFCE (xfce4-genmon-plugin).
#
# Показывает иконку состояния напоминаний; клик переключает паузу.
#
# Настройка: ПКМ по панели → Панель → Добавить новые элементы → Монитор
# (Generic Monitor): в поле Command указать путь к этому скрипту,
# интервал обновления 5–10 с.

TOGGLE="$HOME/.local/bin/toggle_pause.sh"

if [ -f "$HOME/.breaks_paused" ]; then
    icon="media-playback-pause"
    tip="Пауза включена — напоминания отключены (клик: возобновить)"
else
    icon="appointment-soon"
    tip="Напоминания активны (клик: включить паузу)"
fi

printf '<icon>%s</icon><click>%s</click><tool>%s</tool>' "$icon" "$TOGGLE" "$tip"