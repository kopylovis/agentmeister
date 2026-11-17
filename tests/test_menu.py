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

    def tearDown(self):
        mnrhlib.lang, m.mode_on = self.saved

    def plain(self, lang, on=()):
        mnrhlib.lang = lambda: lang
        m.mode_on = lambda name: name in on
        return [(k, ANSI.sub("", t)) for k, t in m.rows()]

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

    def test_description_names_next_command(self):
        mnrhlib.lang = lambda: "en"
        d = m.Describe.__new__(m.Describe)
        d.state, d.proxy, d.claude, d.codex = {"guard": True}, "?", "2.0", "0.169.0"
        i = next(n for n, item in enumerate(m.ITEMS) if item[0] == "mode guard")
        text = [ANSI.sub("", line) for line in d(i, 40)]
        self.assertIn("$ agentmeister guard off", text)
        self.assertTrue(all(len(line) <= 40 for line in text[:6]))

    def test_codex_setup_shows_detected_versions_and_hooks(self):
        mnrhlib.lang = lambda: "en"
        d = m.Describe.__new__(m.Describe)
        d.state, d.proxy, d.claude, d.fresh = {}, "?", "2.0", threading.Event()
        with patch.object(m.codex_harness, "executable", return_value="codex"), \
                patch.object(m, "promptsill_path", return_value="promptsill"), \
                patch.object(m, "capture", side_effect=["codex-cli 0.169.0\n", "0.9.0\n"]), \
                patch.object(m.codex_harness, "configured_humanize_hooks", return_value=2):
            d.ask_codex()
        self.assertTrue(d.dirty())
        i = next(n for n, item in enumerate(m.ITEMS) if item[0] == "--harness codex setup")
        facts = [" ".join(ANSI.sub("", line).split()) for line in d(i, 60)]
        self.assertIn("Codex 0.169.0", facts)
        self.assertIn("promptsill 0.9.0", facts)
        self.assertIn("Humanize hooks 2/3 configured", facts)


class Layout(unittest.TestCase):
    def test_width_counts_emoji_and_ansi(self):
        self.assertEqual(menu.width("\x1b[1m📂 ab\x1b[0m"), 5)
        self.assertEqual(menu.width(menu.fit("📂 abcdef", 4)), 4)
        self.assertEqual(menu.width(menu.cut("📂📂", 3)), 2)

    def test_split_keys(self):
        self.assertEqual(menu.split_keys("\x1b[B\x1b[B"), ["\x1b[B", "\x1b[B"])
        self.assertEqual(menu.split_keys("ssh\r"), ["ssh", "\r"])
        self.assertEqual(menu.split_keys("\x1b"), ["\x1b"])

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

    def test_note_markup(self):
        self.assertEqual([ANSI.sub("", x) for x in menu.render_note(r"Name\npath\n# commits\nfix")],
                         ["Name", "path", "COMMITS", "fix"])
        self.assertEqual(menu.render_note(""), [])

    def test_wrap_keeps_indent(self):
        self.assertEqual(menu.wrap(["  one two three"], 9), ["  one two", "  three"])


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
            code, out = menu.run_framed(screen, [sys.executable, "-c", "print('hi'); raise SystemExit(3)"], "t")
        finally:
            screen.fd = None
            os.close(slave)
            reader.join(2)
            os.close(master)
        self.assertEqual(code, 3)
        self.assertIn("hi", out.plain())

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
        folder = os.path.join(menu.ROOT, "share", "claudemeister", "icons")
        with open(os.path.join(folder, "icons.json"), encoding="utf-8") as f:
            have = json.load(f)
        used = {item[1] for item in m.ITEMS if item[0]}
        self.assertEqual(used - set(have), set())
        for name in have.values():
            self.assertTrue(os.path.isfile(os.path.join(folder, name + ".png")), name)


if __name__ == "__main__":
    unittest.main()
