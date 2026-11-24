import os
import re
import sys
import termios
import threading
import tty
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
os.environ["MNRH_ICONS"] = "emoji"  # раскладку проверяем на emoji, картинки отдельно в Icons
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                "libexec", "agentmeister", "lib"))
import mnrhlib  # noqa: E402
import claude_menu as m  # noqa: E402
import menu  # noqa: E402

ANSI = re.compile(r"\x1b\[[0-9;]*m")


class Menu(unittest.TestCase):
    def setUp(self):
        self.saved = mnrhlib.lang, m.mode_on
        m.forget_facts()

    def tearDown(self):
        mnrhlib.lang, m.mode_on = self.saved
        m.forget_facts()

    def plain(self, lang, on=()):
        mnrhlib.lang = lambda: lang
        m.mode_on = lambda name: name in on
        return [(k, ANSI.sub("", t)) for k, t in m.rows()]

    def test_back_from_project_reopens_agent_picker(self):
        from unittest.mock import Mock
        screen = Mock()
        screen.pick.side_effect = [0, None]
        with patch.object(m, "harness_options", return_value=[("claude", "Claude"), ("codex", "Codex")]), \
                patch.object(m.open_flow, "flow", return_value=None):
            self.assertIsNone(m.session_action(screen, "open"))
        self.assertEqual(screen.pick.call_count, 2)

    def test_launch_choices_follow_the_language_setting(self):
        with patch.object(mnrhlib, "lang", return_value="en"):
            self.assertIn("normal", m.open_flow.mode_options()[1][1])
            self.assertIn("Direct", m.open_flow.network_options("codex")[0][1])
        with patch.object(mnrhlib, "lang", return_value="ru"):
            self.assertIn("обычная", m.open_flow.mode_options()[1][1])

    def test_rows_match_items(self):
        rows = self.plain("ru")
        self.assertEqual(len(rows), len(m.ITEMS))
        self.assertEqual([k is None for k, _ in rows], [item[0] is None for item in m.ITEMS])

    def test_both_languages(self):
        self.assertIn("Открыть проект", self.plain("ru")[1][1])
        self.assertIn("Open a project", self.plain("en")[1][1])

    def test_every_action_has_icon_and_description(self):
        for key, icon, ru, en, desc_ru, desc_en in m.ITEMS:
            if key:
                self.assertEqual(menu.width(icon), 2, key)
                self.assertTrue(desc_ru and desc_en, key)

    def test_mode_shows_state(self):
        rows = dict((k.split(" ", 2)[1] if k and k.startswith("mode ") else k, t)
                    for k, t in self.plain("en", on={"guard"}))
        self.assertTrue(rows["guard"].endswith("[on]"))
        self.assertTrue(rows["lid"].endswith("[off]"))

    def test_flags_line_up(self):
        for lang in ("ru", "en"):
            cols = {menu.width(t[:t.index("[")]) for k, t in self.plain(lang, on={"humanize"})
                    if k and k.startswith("mode ")}
            self.assertEqual(len(cols), 1, lang)

    def test_mode_rows_pad_only_to_mode_labels(self):
        saved = m.ITEMS
        try:
            m.ITEMS = [("open", "📂", "Очень длинное название пункта", "A very long item label here", "", ""),
                       ("mode guard", "🔒", "Режим", "Mode", "", "")]
            mode = self.plain("en")[1][1]
        finally:
            m.ITEMS = saved
        self.assertEqual(mode, "🔒 Mode  [off]")

    def test_title_shows_versions_when_description_is_hidden(self):
        mnrhlib.lang = lambda: "en"
        d = m.Describe.__new__(m.Describe)
        d.claude, d.codex = "2.1.325", "0.172.0"
        hidden = ANSI.sub("", m.menu_title(d, "guard: on", False))
        self.assertIn("Claude Code 2.1.325 · Codex 0.172.0", hidden)
        self.assertTrue(hidden.endswith("guard: on"))
        self.assertNotIn("Claude Code", m.menu_title(d, "", True))

    def test_description_names_next_command(self):
        mnrhlib.lang = lambda: "en"
        d = m.Describe.__new__(m.Describe)
        d.state, d.proxy, d.claude, d.codex = {"guard": True}, "?", "2.0", "0.169.0"
        i = next(n for n, item in enumerate(m.ITEMS) if item[0] == "mode guard")
        text = [ANSI.sub("", line) for line in d(i, 40)]
        self.assertIn("$ agentmeister guard off", text)
        self.assertTrue(all(len(line) <= 40 for line in text[:6]))

    def test_facts_stay_when_description_is_too_tall(self):
        mnrhlib.lang = lambda: "ru"
        d = m.Describe.__new__(m.Describe)
        d.state, d.proxy, d.claude, d.codex = {"notify": True}, "работает", "2.1.325", "0.172.0"
        i = next(n for n, item in enumerate(m.ITEMS) if item[0] == "mode notify")
        out = []

        class P(menu.Panel):
            def size(self):
                return 18, 100

            def write(self, s):
                out.append(s)

        P(0, m.rows({}), "t", i, d, ("L", "R"), "").draw()
        text = ANSI.sub("", out[-1])
        self.assertIn("СЕЙЧАС", text)
        self.assertIn("Прокси", text)
        self.assertIn("…", text)

    def test_long_fact_value_wraps_under_itself(self):
        mnrhlib.lang = lambda: "en"
        d = m.Describe.__new__(m.Describe)
        d.state, d.proxy, d.claude, d.codex = {}, "?", "2.1.325", "0.172.0"
        i = next(n for n, item in enumerate(m.ITEMS) if item[0] == "doctor")
        with patch.object(m.os, "getcwd", return_value="/x/" + "long-folder/" * 6):
            lines = [ANSI.sub("", line) for line in d(i, 40)]
        at = next(n for n, line in enumerate(lines) if line.startswith("Folder"))
        self.assertTrue(lines[at + 1].startswith(" " * 14 + "long-folder/"))
        self.assertTrue(all(menu.width(line) <= 40 for line in lines))

    def test_broken_binary_gives_question_mark_not_endless_checking(self):
        mnrhlib.lang = lambda: "en"
        d = m.Describe.__new__(m.Describe)
        d.fresh = threading.Event()
        errors = [OSError(8, "Exec format error"), UnicodeDecodeError("utf-8", b"\xff", 0, 1, "bad"), "0.9.0\n"]
        with patch.object(m.shutil, "which", return_value="/tools/claude"), \
                patch.object(m.codex_harness, "executable", return_value="codex"), \
                patch.object(m, "promptsill_path", return_value="promptsill"), \
                patch.object(m, "capture", side_effect=errors), \
                patch.object(m.codex_harness, "configured_humanize_hooks", side_effect=RuntimeError):
            d.ask_versions()
        self.assertEqual((d.claude, d.codex, d.promptsill, d.hooks), ("?", "?", "0.9.0", "?"))
        self.assertTrue(d.fresh.is_set())

    def test_versions_are_cached_until_a_command_runs(self):
        m.FACTS.update(claude="2.1.325", codex="0.172.0", promptsill="0.9.0", hooks="3/3", proxy="running")
        with patch.object(m.threading, "Thread") as thread:
            d = m.Describe({})
        thread.assert_not_called()
        self.assertEqual((d.claude, d.proxy), ("2.1.325", "running"))
        m.forget_facts()
        with patch.object(m.threading, "Thread") as thread:
            d = m.Describe({})
        self.assertEqual(thread.call_count, 2)
        self.assertNotEqual(d.claude, "2.1.325")

    def test_answer_started_before_forget_is_not_cached(self):
        d = m.Describe.__new__(m.Describe)
        d.fresh = threading.Event()

        def probe():
            m.forget_facts()  # команда запустилась, пока шла проверка
            return "old"
        d.ask([("claude", probe)])
        self.assertEqual(d.claude, "old")
        self.assertNotIn("claude", m.FACTS)

    def test_deleted_folder_falls_back_to_pwd(self):
        with patch.object(m.os, "getcwd", side_effect=FileNotFoundError), patch.dict(os.environ, PWD="/gone"):
            self.assertEqual(m.cwd(), "/gone")
        with patch.object(m.os, "getcwd", side_effect=FileNotFoundError), patch.dict(os.environ, PWD=""):
            self.assertEqual(m.cwd(), "?")

    def test_codex_setup_shows_detected_versions_and_hooks(self):
        mnrhlib.lang = lambda: "en"
        d = m.Describe.__new__(m.Describe)
        d.state, d.proxy, d.fresh = {}, "?", threading.Event()
        versions = ["2.1.323 (Claude Code)\n", "codex-cli 0.169.0\n", "0.9.0\n"]
        with patch.dict(os.environ, MNRH_CLAUDE_BIN="custom-claude"), \
                patch.object(m.shutil, "which", return_value="/tools/claude") as which, \
                patch.object(m.codex_harness, "executable", return_value="codex"), \
                patch.object(m, "promptsill_path", return_value="promptsill"), \
                patch.object(m, "capture", side_effect=versions) as probe, \
                patch.object(m.codex_harness, "configured_humanize_hooks", return_value=2):
            d.ask_versions()
        which.assert_called_once_with("custom-claude")
        self.assertEqual(probe.call_args_list[0].args[0], ["/tools/claude", "--version"])
        self.assertTrue(d.dirty())
        i = next(n for n, item in enumerate(m.ITEMS) if item[0] == "--harness codex setup")
        facts = [" ".join(ANSI.sub("", line).split()) for line in d(i, 60)]
        self.assertIn("Claude Code 2.1.323", facts)
        self.assertIn("Codex 0.169.0", facts)
        self.assertIn("promptsill 0.9.0", facts)
        self.assertIn("Humanize hooks 2/3 configured", facts)


class Layout(unittest.TestCase):
    def test_width_counts_emoji_and_ansi(self):
        self.assertEqual(menu.width("\x1b[1m📂 ab\x1b[0m"), 5)
        self.assertEqual(menu.width(menu.fit("📂 abcdef", 4)), 4)
        self.assertEqual(menu.width(menu.cut("📂📂", 3)), 2)

    def test_superscript_digit_is_search_text(self):
        picker = menu.Menu(0, [("m²", "m²")], "", "", 1, 0)
        picker.handle("²")
        self.assertEqual(picker.query, "²")

    def test_split_keys(self):
        self.assertEqual(menu.split_keys("\x1b[B\x1b[B"), ["\x1b[B", "\x1b[B"])
        self.assertEqual(menu.split_keys("ssh\r"), ["s", "s", "h", "\r"])
        self.assertEqual(menu.split_keys("\x1b"), ["\x1b"])
        self.assertEqual(menu.split_keys("qq  "), ["q", "q", " ", " "])
        self.assertEqual(menu.split_keys("я\x1bOB"), ["я", "\x1bOB"])

    def test_two_spaces_in_one_read_mark_two_rows(self):
        picker = menu.Menu(0, [("a", "a"), ("b", "b"), ("c", "c")], "", "", 1, 0)
        picker.marks = set()
        picker.handle_batch(menu.split_keys("  "))
        self.assertEqual(picker.marks, {0, 1})
        self.assertEqual(picker.query, "")

    def test_search_looks_at_visible_text_first(self):
        items = [("--harness claude status", "Claude Code status"), ("--harness codex install", "Install Codex"),
                 ("sessions", "Saved sessions"), ("doctor", "Check the install")]
        picker = menu.Menu(0, items, "", "", 1, 0)
        for ch in "ss":
            picker.handle(ch)
        self.assertEqual(picker.choices(), [2])
        picker.query = ""
        for ch in "doctor":
            picker.handle(ch)
        self.assertEqual(picker.choices(), [3])  # в видимом тексте нет, находит ключ
        picker.query = ""
        for ch in "ыуыы":  # «sess» в русской раскладке
            picker.handle(ch)
        self.assertEqual(picker.choices(), [2])

    def test_panel_lines_have_equal_width(self):
        items = [(None, "Group"), ("a", "📂 Open"), ("b", "\x1b[32m[on]\x1b[0m flag")]
        out = []

        class P(menu.Panel):
            def size(self):
                return 20, 100

            def write(self, s):
                out.append(s)

        P(0, items, "title", 1, lambda i, w: ["x" * (w + 10)], ("L", "R"), "hint").draw()
        lines = ANSI.sub("", "".join(out).replace("\x1b[H", "").replace("\x1b[K", "")
                         .replace("\x1b[J", "")).split("\r\n")
        self.assertEqual(len(lines), 19)  # нижнюю строку не трогаем, чтобы экран не прокрутился
        self.assertEqual({menu.width(line) for line in lines[1:-1]}, {98})


    def test_numbers_and_wide_left_frame(self):
        items = [("a", "x" * 70), ("b", "short")]
        out = []

        class P(menu.Panel):
            def size(self):
                return 20, 140

            def write(self, s):
                out.append(s)

        P(0, items, "t", 0, lambda i, w: [], ("L", "R"), "", start=0, numbers=True).draw()
        lines = ANSI.sub("", "".join(out)).split("\r\n")
        self.assertIn("x" * 70, lines[2])
        self.assertIn("1  short", lines[3])

    def test_columns_show_description_next_to_the_whole_list(self):
        self.assertEqual(menu.columns(120, 46, "auto"), (46, 69))
        self.assertEqual(menu.columns(84, 46, "auto"), (80, 0))  # 33 клетки описанию мало
        self.assertEqual(menu.columns(85, 46, "auto"), (46, 34))
        self.assertEqual(menu.columns(120, 46, "off"), (116, 0))

    def test_tab_forces_description_by_narrowing_the_list(self):
        self.assertEqual(menu.columns(80, 46, "force"), (46, 29))
        self.assertEqual(menu.columns(70, 46, "force"), (37, 28))
        self.assertEqual(menu.columns(120, 46, "force"), (46, 69))
        self.assertEqual(menu.columns(52, 46, "force"), (48, 0))
        self.assertTrue(menu.can_force(60))

    def frame(self, cols, keys=(), title="title", describe=lambda i, w: ["about"], hint=None):
        out = []

        class P(menu.Panel):
            def size(self):
                return 20, cols

            def write(self, s):
                out.append(s)

        items = [("a", "x" * 40), ("b", "short")]
        p = P(0, items, title, 0, describe, ("L" * 90, "R"), hint or menu.tab_hint() + "Esc back")
        for key in keys:
            p.handle(key)
        p.draw()
        return p, ANSI.sub("", out[-1]).split("\r\n")

    def test_long_list_title_does_not_hide_description(self):
        p, lines = self.frame(100)
        self.assertTrue(bool(p.columns(p.size()[1])[1]))
        self.assertIn("about", lines[2])

    def test_tab_toggles_description_from_what_is_shown(self):
        p, lines = self.frame(80)
        self.assertFalse(bool(p.columns(p.size()[1])[1]))
        self.assertIn("Tab", lines[-1])
        p, lines = self.frame(80, ["\t"])
        self.assertTrue(bool(p.columns(p.size()[1])[1]))
        self.assertIn("about", lines[2])
        p, _ = self.frame(80, ["\t", "\t"])
        self.assertFalse(bool(p.columns(p.size()[1])[1]))
        p, _ = self.frame(120, ["\t"])
        self.assertFalse(bool(p.columns(p.size()[1])[1]))

    def test_tab_is_not_advertised_without_description(self):
        _, lines = self.frame(80, describe=None)
        self.assertNotIn("Tab", lines[-1])
        self.assertIn("Esc back", lines[-1])

    def test_title_function_knows_whether_description_is_shown(self):
        _, lines = self.frame(80, title=lambda side: f"side={side}")
        self.assertIn("side=False", lines[0])
        _, lines = self.frame(120, title=lambda side: f"side={side}")
        self.assertIn("side=True", lines[0])

    def test_scroll_marks_sit_on_the_border(self):
        lines = [ANSI.sub("", line) for line in menu.box(" t ", ["row"], 20, 4, True, "↑ 3", "↓ 5")]
        self.assertEqual(lines[0], "╭─ t ──────── ↑ 3 ─╮")
        self.assertEqual(lines[-1], "╰──────────── ↓ 5 ─╯")
        self.assertEqual({menu.width(line) for line in lines}, {20})

    def test_selected_row_is_not_covered_by_scroll_mark(self):
        out = []

        class P(menu.Panel):
            def size(self):
                return 8, 60

            def write(self, s):
                out.append(s)

        items = [(f"k{i}", f"row {i} " + "x" * 40) for i in range(20)]
        p = P(0, items, "t", 19, None, ("L", "R"), "")
        p.draw()
        lines = ANSI.sub("", out[-1]).split("\r\n")
        self.assertIn("↑ 17", lines[1])
        self.assertIn("row 19 " + "x" * 40, lines[-3])
        self.assertNotIn("↓", "".join(lines))

    def test_next_frame_sends_only_changed_parts(self):
        out = []

        class P(menu.Panel):
            def size(self):
                return 20, 100

            def write(self, s):
                out.append(s)

        items = [("a", "📂 alpha"), ("b", "📂 beta"), ("c", "📂 gamma"), ("d", "📂 delta")]
        p = P(0, items, "title", 0, lambda i, w: ["same"], ("L", "R"), "hint")
        p.draw()
        self.assertTrue(out[-1].startswith("\x1b[H"))
        p.handle("\x1b[B")
        p.draw()
        frame = out[-1]
        self.assertEqual(re.findall(r"\x1b\[(\d+);(\d+)H", frame), [("3", "1"), ("4", "1")])
        self.assertIn("alpha", frame)
        self.assertIn("beta", frame)
        self.assertNotIn("gamma", frame)
        self.assertNotIn("same", frame)
        p.draw()
        self.assertEqual(len(out), 2)  # ничего не поменялось: ничего не пишем

    def test_description_change_is_written_at_its_column(self):
        out = []
        text = {"v": "one"}

        class P(menu.Panel):
            def size(self):
                return 20, 100

            def write(self, s):
                out.append(s)

        p = P(0, [("a", "alpha")], "title", 0, lambda i, w: [text["v"]], ("L", "R"), "hint")
        p.draw()
        text["v"] = "two"
        p.draw()
        lw = menu.columns(100, menu.width("alpha") + 6, "auto")[0]
        self.assertEqual(re.findall(r"\x1b\[(\d+);(\d+)H", out[-1]), [("3", str(3 + lw))])

    def test_low_window_drops_title_then_hint(self):
        self.assertEqual(menu.layout_rows(20), (17, True, True))
        self.assertEqual(menu.layout_rows(8), (5, True, True))
        self.assertEqual(menu.layout_rows(7), (5, False, True))
        self.assertEqual(menu.layout_rows(6), (5, False, False))
        for rows in range(6, 20):
            h, title, hint = menu.layout_rows(rows)
            self.assertLessEqual(h + title + hint, rows - 1)

    def test_fallback_list_keeps_title_on_screen(self):
        out = []

        class M(menu.Menu):
            def size(self):
                return 12, 50

            def write(self, s):
                out.append(s)

        m_ = M(0, [(f"k{i}", f"item {i}") for i in range(40)], "Title", "", 1, 20)
        m_.draw()
        lines = out[-1].split("\r\n")
        self.assertLessEqual(len(lines), 11)
        self.assertIn("Title", lines[0])
        self.assertIn("↑", lines[1])

    def test_note_markup(self):
        self.assertEqual([ANSI.sub("", x) for x in menu.render_note(r"Name\npath\n# commits\nfix")],
                         ["Name", "path", "COMMITS", "fix"])
        self.assertEqual(menu.render_note(""), [])

    def test_wrap_keeps_indent(self):
        self.assertEqual(menu.wrap(["  one two three"], 9), ["  one two", "  three"])

    def test_wrap_colored_line_carries_color(self):
        self.assertEqual(menu.wrap(["\x1b[2m$ agentmeister --harness codex\x1b[0m"], 16),
                         ["\x1b[2m$ agentmeister\x1b[0m", "\x1b[2m--harness codex\x1b[0m"])

    def test_wrap_counts_cells_not_characters(self):
        lines = menu.wrap(["📂 📂 📂 📂 📂 📂"], 8)
        self.assertEqual(lines, ["📂 📂 📂", "📂 📂 📂"])
        self.assertTrue(all(menu.width(line) <= 8 for line in lines))

    def test_wrap_cuts_long_words_after_slash(self):
        self.assertEqual(menu.wrap(["~/Developer/agentmeister/.claude"], 20), ["~/Developer/", "agentmeister/.claude"])
        self.assertEqual(menu.wrap(["x" * 25], 10), ["x" * 10, "x" * 10, "x" * 5])

    def test_vs16_emoji_takes_two_cells(self):
        self.assertEqual(menu.width("♻️ x"), 4)
        self.assertEqual(menu.cut("♻️♻️", 3), "♻️")
        self.assertEqual(menu.width("♻ x"), 3)

    def test_squeeze_drops_blank_lines_then_text_and_keeps_facts(self):
        head = ["Title", "", "one", "two", "three", "", "$ cmd"]
        tail = ["", "", "FACTS", "a 1", "b 2"]
        self.assertEqual(menu.squeeze(head, tail, 20, 30), head + tail)
        self.assertEqual(menu.squeeze(head, tail, 9, 30),
                         ["Title", "one", "two", "three", "$ cmd", "", "FACTS", "a 1", "b 2"])
        short = menu.squeeze(head, tail, 6, 30)
        self.assertEqual(short[-3:], ["FACTS", "a 1", "b 2"])
        self.assertEqual(len(short), 6)
        self.assertTrue(ANSI.sub("", short[2]).endswith("…"))


class English(unittest.TestCase):
    def setUp(self):
        self.saved = mnrhlib.lang
        mnrhlib.lang = lambda: "en"

    def tearDown(self):
        mnrhlib.lang = self.saved

    @staticmethod
    def session(**extra):
        s = {"id": "f5fde58d-80df-4a68-8ab4-12f15fbbd06e", "cwd": "/tmp", "started_in": "/tmp", "branch": "",
             "title": "", "prompt": "", "size": 1024, "mtime": 0, "running": None, "link": False, "target": None}
        s.update(extra)
        return s

    def test_session_details_in_english(self):
        import claude_sessions
        text = "\n".join(ANSI.sub("", line) for line in claude_sessions.details(self.session(running=42), 40))
        self.assertIn("untitled", text)
        self.assertIn("folder", text)
        self.assertIn("open now (pid 42)", text)
        self.assertIsNone(re.search("[а-яА-Я]", text), text)
        self.assertTrue(all(menu.width(line) <= 40 for line in text.splitlines()))

    def test_session_actions_in_english(self):
        import claude_sessions
        from unittest.mock import Mock
        screen = Mock()
        screen.pick.side_effect = [0, None, None]
        with patch.object(claude_sessions, "load", return_value=[self.session()]):
            self.assertIsNone(claude_sessions.browse(screen))
        list_call, actions_call = screen.pick.call_args_list[:2]
        shown = [ANSI.sub("", text) for _, text in actions_call.args[0]] + [actions_call.kwargs["title"],
                                                                             list_call.kwargs["title"]]
        self.assertIsNone(re.search("[а-яА-Я]", " ".join(shown)), shown)
        self.assertIn("☕ resume, the Mac stays awake", shown)

    def test_running_session_details_in_english(self):
        import claude_live
        s = {"status": "waiting", "cwd": "/tmp", "pid": 7, "statusUpdatedAt": None}
        with patch.object(claude_live, "title", return_value="t"), patch.object(claude_live, "ago", return_value="now"):
            text = " ".join(ANSI.sub("", line) for line in m.live_details(s, 40))
        self.assertIsNone(re.search("[а-яА-Я]", text), text)
        self.assertIn("waiting for you", text)

    def test_hint_drops_middle_parts_to_keep_esc(self):
        hint = "↑↓ выбрать · Enter · цифра или буквы, быстрый переход · Tab описание · Esc назад"
        self.assertEqual(menu.fit_hint(hint, 76), "↑↓ выбрать · Enter · Tab описание · Esc назад")
        self.assertEqual(menu.fit_hint(hint, 200), hint)
        self.assertLessEqual(menu.width(menu.fit_hint(hint, 20)), 20)


class Signals(unittest.TestCase):
    def test_sigterm_exits_through_finally(self):
        import signal
        saved = signal.getsignal(signal.SIGTERM)
        try:
            signal.signal(signal.SIGTERM, signal.SIG_DFL)
            menu.catch_term()
            with self.assertRaises(SystemExit) as caught:
                os.kill(os.getpid(), signal.SIGTERM)
            self.assertEqual(caught.exception.code, 143)
        finally:
            signal.signal(signal.SIGTERM, saved)

    def test_sigterm_handler_set_elsewhere_is_kept(self):
        import signal
        saved = signal.getsignal(signal.SIGTERM)
        try:
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            menu.catch_term()
            self.assertEqual(signal.getsignal(signal.SIGTERM), signal.SIG_IGN)
        finally:
            signal.signal(signal.SIGTERM, saved)


class Ask(unittest.TestCase):
    @staticmethod
    def drain(fd):
        try:
            while os.read(fd, 4096):
                pass
        except OSError:
            pass

    def answer(self, keys):
        master, slave = os.openpty()
        tty.setcbreak(slave)  # как Screen.open: нажатия приходят сразу, без Enter
        screen = menu.Screen()
        screen.fd = slave
        os.write(master, keys)
        # кадр пишется в pty; если его не читать, буфер заполнится и запись встанет
        reader = threading.Thread(target=self.drain, args=(master,), daemon=True)
        reader.start()
        try:
            return screen.ask("Путь", title="t")
        finally:
            screen.fd = None
            del menu.PENDING[:]
            os.close(slave)  # чтение master получит ошибку, поток закончится, потом закрываем master
            reader.join(2)
            os.close(master)

    def test_typed_text_with_backspace(self):
        self.assertEqual(self.answer(b"~/abx\x7fc\r"), "~/abc")

    def test_esc_cancels(self):
        self.assertIsNone(self.answer(b"abc\x1b"))

    def test_pasted_path_keeps_utf8_at_read_boundaries(self):
        text = "a" * 63 + "папка" * 12
        self.assertEqual(self.answer((text + "\r").encode()), text)

    def test_russian_text(self):
        self.assertEqual(self.answer("папка\r".encode()), "папка")


class Marks(unittest.TestCase):
    def frame(self, keys=()):
        out = []

        class P(menu.Panel):
            def size(self):
                return 20, 100

            def write(self, s):
                out.append(s)

        p = P(0, [("a", "alpha"), ("b", "beta"), ("c", "gamma")], "t", 0, None, ("L", "R"), "")
        p.marks = {0}
        p.summary = lambda marks: f"picked {len(marks)}"
        for key in keys:
            p.handle(key)
        p.draw()
        return p, ANSI.sub("", "".join(out))

    def test_marks_drawn_and_toggled(self):
        p, text = self.frame([" "])  # пробел снимает отметку с первой строки и уходит на вторую
        self.assertEqual(p.marks, set())
        self.assertIn("○ alpha", text)
        p, text = self.frame(["\x1b[B", " "])
        self.assertEqual(p.marks, {0, 1})
        self.assertIn("◉ beta", text)
        self.assertIn("picked 2", text)

    def test_all_or_none(self):
        p, _ = self.frame(["a"])
        self.assertEqual(p.marks, {0, 1, 2})
        p.handle("a")
        self.assertEqual(p.marks, set())


class Framed(unittest.TestCase):
    def test_finished_output_keeps_actions_inside_frame(self):
        out = menu.Output()
        out.feed("\n".join(f"line {i}" for i in range(25)) + "\n")
        screen = menu.Screen()
        with patch.object(menu, "screen_size", return_value=(14, 60)), \
                patch.object(menu, "write_all") as write, patch.object(mnrhlib, "lang", return_value="en"):
            menu.draw_output(screen, out, "setup", running=False)
        rows = ANSI.sub("", write.call_args.args[1]).split("\r\n")
        self.assertIn("line 24", rows[-4])
        self.assertIn("Enter  Back to menu", rows[-3])
        self.assertIn("q  Quit", rows[-3])
        self.assertIn("╰", rows[-2])

    def test_cursor_stands_right_after_the_prompt(self):
        out = menu.Output()
        out.feed("Path: ")
        screen = menu.Screen()
        with patch.object(menu, "screen_size", return_value=(14, 60)), patch.object(menu, "write_all") as write:
            menu.draw_output(screen, out, "t", running=True)
        frame = write.call_args.args[1]
        self.assertIn("\x1b[3;11H", frame)  # «  │ Path: » занимает 10 колонок
        out.feed("x" * 80)
        with patch.object(menu, "screen_size", return_value=(14, 60)), patch.object(menu, "write_all") as write:
            menu.draw_output(screen, out, "t", running=True)
        col = int(re.findall(r"\x1b\[\d+;(\d+)H", write.call_args.args[1])[-1])
        self.assertLessEqual(col, 57)  # правая линия рамки в 58-й колонке

    def test_output_scroll_keys_in_one_read(self):
        out = menu.Output()
        out.feed("\n".join(f"line {i}" for i in range(100)) + "\n")
        screen = menu.Screen()
        seen = []

        def draw(screen, out, title, running, code=0, back=0, elapsed=None):
            seen.append(back)
        with patch.object(menu, "screen_size", return_value=(14, 60)), patch.object(menu, "draw_output", draw), \
                patch.object(menu.select, "select", return_value=([1], [], [])), \
                patch.object(menu, "read_keys", side_effect=["bb", "qq"]):
            self.assertFalse(menu.show_output(screen, out, "t", 0))
        self.assertEqual(seen, [0, 16])

    def test_output_keeps_colors_and_handles_carriage_return(self):
        out = menu.Output()
        out.feed("one\n\x1b[32mtwo\x1b[0m\nprogress 10%\rprogress 100%\n")
        self.assertEqual(out.lines[:3], ["one", "\x1b[32mtwo\x1b[0m", "progress 100%"])

    def test_output_drops_cursor_moves_and_sees_redraw_mark(self):
        out = menu.Output()
        out.feed("a\x1b[2Ab" + menu.REDRAW + "\x1b[2Kc")
        self.assertEqual(out.lines, ["c"])
        self.assertTrue(out.redraw)

    def test_split_escape_waits_for_the_rest(self):
        out = menu.Output()
        out.feed("x\x1b[3")
        out.feed("1my")
        self.assertEqual(out.lines, ["x\x1b[31my"])

    def test_fold_carries_color(self):
        self.assertEqual(menu.fold("\x1b[32mabcdef", 3), ["\x1b[32mabc\x1b[0m", "\x1b[32mdef"])

    def test_run_framed_captures_output_and_code(self):
        master, slave = os.openpty()
        tty.setcbreak(slave)
        reader = threading.Thread(target=Ask.drain, args=(master,), daemon=True)
        reader.start()
        screen = menu.Screen()
        screen.fd, screen.saved = slave, termios.tcgetattr(slave)
        try:
            child = ("import os, time; os.write(1, bytes([0xd0])); time.sleep(0.3); "
                     "os.write(1, bytes([0xaf, 10, 0xd0])); raise SystemExit(3)")
            code, out = menu.run_framed(screen, [sys.executable, "-c", child], "t")
        finally:
            screen.fd = None
            os.close(slave)
            reader.join(2)
            os.close(master)
        self.assertEqual(code, 3)
        self.assertEqual(out.plain(), "Я\n�")

    def test_questions_go_to_the_frame(self):
        # в рамке вопрос choice пишется в stdout, иначе его сотрет перерисовка рамки
        saved, isatty = menu.IN_FRAME, os.isatty
        try:
            menu.IN_FRAME, os.isatty = True, lambda fd: fd == 1
            self.assertEqual(menu.frame_fd(7), 1)
            menu.IN_FRAME = False
            self.assertEqual(menu.frame_fd(7), 7)
        finally:
            menu.IN_FRAME, os.isatty = saved, isatty

    def test_choice_processes_batched_arrow_and_enter(self):
        master, slave = os.openpty()
        try:
            with open(os.devnull, "wb") as output, patch.object(menu, "frame_fd", return_value=output.fileno()), \
                    patch.object(menu.os, "open", return_value=os.dup(slave)), \
                    patch.object(menu, "read_keys", return_value="\x1b[C\r"):
                self.assertEqual(menu.choice("test", [("a", "A"), ("b", "B")]), "b")
        finally:
            os.close(slave)
            os.close(master)

    def test_choice_prompt_shows_as_last_line(self):
        out = menu.Output()
        out.feed("list\n\n\r\x1b[K\x1b[1;34mУдалить?\x1b[0m  a\r\x1b[K\x1b[1;34mУдалить?\x1b[0m  b")
        self.assertEqual(ANSI.sub("", out.lines[-1]), "Удалить?  b")


class Icons(unittest.TestCase):
    def tearDown(self):
        os.environ["MNRH_ICONS"] = "emoji"
        menu._ICONS = None

    def test_images_replace_known_emoji_only_when_enabled(self):
        menu._ICONS = None
        self.assertEqual(menu.with_icons("📂 x"), "📂 x")
        os.environ["MNRH_ICONS"] = "images"
        menu._ICONS = None
        out = menu.with_icons("📂 x 🦄")
        self.assertIn("\x1b]1337;File=inline=1;width=2;height=1", out)
        self.assertNotIn("📂", out)
        self.assertIn("🦄", out)

    def test_every_menu_emoji_has_a_picture(self):
        import json
        folder = os.path.join(menu.ROOT, "share", "agentmeister", "icons")
        with open(os.path.join(folder, "icons.json"), encoding="utf-8") as f:
            have = json.load(f)
        used = {item[1] for item in m.ITEMS if item[0]}
        self.assertEqual(used - set(have), set())
        for name in have.values():
            self.assertTrue(os.path.isfile(os.path.join(folder, name + ".png")), name)


if __name__ == "__main__":
    unittest.main()
