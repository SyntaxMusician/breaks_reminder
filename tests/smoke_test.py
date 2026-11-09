#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Smoke-тест breaks_reminder (только stdlib, запуск: python3 tests/smoke_test.py).

Проверяет:
  1. модуль импортируется, в DEFAULTS есть afk_action=pause;
  2. breaks_reminder.conf.example парсится, все его ключи известны, afk_action нормализуется;
  3. регрессия KVM/AFK: при простое >= afk_reset таймеры замораживаются (afk_action=pause)
     и напоминание срабатывает сразу после «возврата», а при afk_action=reset — как раньше
     (сброс, в том же окне напоминаний нет).
"""

import configparser
import importlib.util
import os
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_module():
    spec = importlib.util.spec_from_file_location("br", os.path.join(REPO, "breaks_reminder.py"))
    br = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(br)
    return br


class StopLoop(Exception):
    pass


class FakeTime:
    def __init__(self):
        self.t = 0.0

    def monotonic(self):
        self.t += 1.0
        return self.t

    def time(self):
        return self.t

    def sleep(self, s):
        pass


def run_scenario(br, action, ticks_active=119, ticks_away=10, ticks_back=15):
    """Прогон основного цикла run(): активность -> простой (KVM на другом ПК) -> возврат."""
    tmp = tempfile.mkdtemp()
    conf = os.path.join(tmp, "breaks_reminder.conf")
    with open(conf, "w", encoding="utf-8") as f:
        f.write("[reminder]\neye_interval = 2\nbreak_interval = 10\n"
                "[idle]\nafk_reset = 1\nafk_action = %s\n" % action)
    br.CONFIG_PATH = conf
    br.HOME = tmp
    br.PAUSE_FLAG = os.path.join(tmp, ".breaks_paused")
    br.LOCK_FLAG = os.path.join(tmp, ".screen_locked")
    br.INSTANCE_LOCK = os.path.join(tmp, "instance.lock")

    ft = FakeTime()
    br.time = ft

    idles = [0] * ticks_active + [600000] * ticks_away + [0] * ticks_back  # 600000 мс >= 1 мин AFK
    it = iter(idles)
    br.get_idle_ms = lambda: next(it, 0)

    notes = []
    br.notify_async = lambda title, message, **kw: notes.append(title)
    br.show_notification = lambda *a, **k: None

    state = {"n": 0}

    def fake_sleep(s):
        state["n"] += 1
        if state["n"] > len(idles):
            raise StopLoop()

    ft.sleep = fake_sleep
    try:
        br.run()
    except StopLoop:
        pass
    return notes


def test_defaults_and_config_example():
    br = load_module()
    assert br.DEFAULTS.get("afk_action") == "pause", br.DEFAULTS.get("afk_action")

    example = os.path.join(REPO, "breaks_reminder.conf.example")
    parser = configparser.ConfigParser(inline_comment_prefixes=("#", ";"))
    assert parser.read(example, encoding="utf-8")
    unknown = [key for section in parser.sections() for key in parser.options(section)
               if key not in br.DEFAULTS]
    assert not unknown, "неизвестные ключи в conf.example: %s" % unknown

    br.CONFIG_PATH = example
    br.cfg = br.load_config()
    assert br.afk_action() == "pause", br.afk_action()

    br.cfg = {"afk_action": "RESET"}
    assert br.afk_action() == "reset"
    br.cfg = {"afk_action": "banana"}
    assert br.afk_action() == "pause"
    br.cfg = {}
    assert br.afk_action() == "pause"
    print("ok: defaults + conf.example + нормализация afk_action")


def test_afk_pause_vs_reset():
    br = load_module()
    notes_pause = run_scenario(br, "pause")
    assert notes_pause, "afk_action=pause: напоминание должно сработать сразу после возврата"
    br2 = load_module()
    notes_reset = run_scenario(br2, "reset")
    assert not notes_reset, "afk_action=reset: в этом окне напоминаний быть не должно, got %r" % notes_reset
    print("ok: afk pause (напоминание после возврата: %r) vs reset (%r)" % (notes_pause, notes_reset))


if __name__ == "__main__":
    test_defaults_and_config_example()
    test_afk_pause_vs_reset()
    print("SMOKE TEST PASSED")
