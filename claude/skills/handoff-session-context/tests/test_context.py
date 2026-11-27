#!/usr/bin/env python3
"""Tests of scripts/context.py (skill handoff-session-context). Standard library only.

    python3 -m unittest discover -s claude/skills/handoff-session-context/tests -v
"""
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "scripts" / "context.py"
sys.path.insert(0, str(SCRIPT.parent))
import context  # noqa: E402

M = 1_000_000


def usage_line(ts, model, inp, cw, cr, out=10):
    return json.dumps({"type": "assistant", "timestamp": ts,
                       "message": {"id": "msg_" + ts, "model": model,
                                   "usage": {"input_tokens": inp, "cache_creation_input_tokens": cw,
                                             "cache_read_input_tokens": cr, "output_tokens": out}}})


class Tmp(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.tmp = Path(self._td.name).resolve()  # macOS: /var -> /private/var
        self.projects = self.tmp / "projects"
        self.cache = self.tmp / "cache"
        self.env = {}

    def tearDown(self):
        self._td.cleanup()

    def transcript(self, session, lines, cwd="/home/u/Developer/_work/proj"):
        d = self.projects / context.project_slug(cwd)
        d.mkdir(parents=True, exist_ok=True)
        p = d / f"{session}.jsonl"
        p.write_text("\n".join(lines) + "\n")
        return p


class TestSlug(unittest.TestCase):
    def test_slug_matches_claude_code(self):
        self.assertEqual(context.project_slug("/home/u/Developer/_work/example-app"),
                         "-home-u-Developer--work-example-app")


class TestContextSize(Tmp):
    def test_newest_main_usage_wins(self):
        p = self.transcript("s1", [
            usage_line("2026-11-24T10:00:00Z", "claude-opus-5-5", 1, 100, 1000),
            '{"type":"user","message":{"content":"hi"}}',
            usage_line("2026-11-24T10:05:00Z", "claude-opus-5-5", 2, 200, 5000),
        ])
        self.assertEqual(context.read_context(p), (5202, "claude-opus-5-5"))

    def test_bad_json_and_synthetic_lines_are_skipped(self):
        p = self.transcript("s1", [
            usage_line("2026-11-24T10:00:00Z", "claude-opus-5-5", 1, 2, 3),
            '{"usage": broken',
            usage_line("2026-11-24T10:09:00Z", "<synthetic>", 0, 0, 0),
        ])
        self.assertEqual(context.read_context(p), (6, "claude-opus-5-5"))

    def test_no_usage_gives_zero(self):
        p = self.transcript("s1", ['{"type":"user","message":{"content":"hi"}}'])
        self.assertEqual(context.read_context(p), (0, None))

    def test_tail_read_of_a_big_file(self):
        filler = '{"type":"user","message":{"content":"' + "x" * 1000 + '"}}'
        lines = [usage_line("2026-11-24T09:00:00Z", "claude-opus-5-5", 1, 1, 1)] + [filler] * 3000
        lines.append(usage_line("2026-11-24T10:00:00Z", "claude-opus-5-5", 7, 0, 0))
        p = self.transcript("s1", lines)
        self.assertEqual(context.read_context(p, tail_bytes=100_000), (7, "claude-opus-5-5"))

    def test_usage_only_before_the_tail_is_still_found(self):
        filler = '{"type":"user","message":{"content":"' + "x" * 1000 + '"}}'
        lines = [usage_line("2026-11-24T09:00:00Z", "claude-opus-5-5", 9, 0, 0)] + [filler] * 300
        p = self.transcript("s1", lines)
        self.assertEqual(context.read_context(p, tail_bytes=10_000), (9, "claude-opus-5-5"))

    def test_find_transcript_by_cwd_then_by_search(self):
        p = self.transcript("abc", [usage_line("t", "m", 1, 0, 0)], cwd="/a/b")
        self.assertEqual(context.find_transcript("abc", "/a/b", self.projects), p)
        self.assertEqual(context.find_transcript("abc", "/other", self.projects), p)
        self.assertIsNone(context.find_transcript("nope", "/a/b", self.projects))

    def test_subagent_files_are_not_the_main_transcript(self):
        main = self.transcript("abc", [usage_line("t1", "claude-opus-5-5", 5, 0, 0)])
        sub = main.parent / "abc" / "subagents"
        sub.mkdir(parents=True)
        (sub / "abc.jsonl").write_text(usage_line("t9", "claude-haiku-5-5", 999, 0, 0) + "\n")
        self.assertEqual(context.find_transcript("abc", "/zzz", self.projects), main)


class TestWindow(Tmp):
    def test_table(self):
        for model, want in [("claude-opus-5-5", M), ("claude-fable-5-1", M), ("claude-sonnet-5-5", M),
                            ("claude-haiku-5-5", M), ("something-else", 200_000), (None, 200_000)]:
            self.assertEqual(context.window_for("s", model, {}, self.cache), (want, "table"), model)

    def test_order_env_cache_maxctx_table(self):
        self.cache.mkdir()
        (self.cache / "s.json").write_text(json.dumps({"window": 500_000}))
        env = {"HANDOFF_WINDOW_TOKENS": "300000", "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "400000"}
        self.assertEqual(context.window_for("s", "claude-opus-5-5", env, self.cache), (300_000, "env"))
        del env["HANDOFF_WINDOW_TOKENS"]
        self.assertEqual(context.window_for("s", "claude-opus-5-5", env, self.cache), (500_000, "cache"))
        (self.cache / "s.json").unlink()
        self.assertEqual(context.window_for("s", "claude-opus-5-5", env, self.cache), (400_000, "maxctx"))

    def test_bad_cache_file_falls_through(self):
        self.cache.mkdir()
        (self.cache / "s.json").write_text("not json")
        self.assertEqual(context.window_for("s", "claude-haiku-5-5", {}, self.cache), (M, "table"))


class TestLevel(unittest.TestCase):
    def test_levels_1m_and_200k(self):
        for window in (M, 200_000):
            for pct, want in [(39.9, "ok"), (40, "handoff"), (49.9, "handoff"), (50, "over"), (80, "over")]:
                tokens = int(window * pct / 100)
                self.assertEqual(context.level(tokens, window, {})[0], want, (window, pct))

    def test_env_overrides_limits(self):
        self.assertEqual(context.level(300_000, M, {"HANDOFF_AT_PCT": "30", "HANDOFF_MAX_PCT": "35"})[0], "handoff")
        self.assertEqual(context.level(360_000, M, {"HANDOFF_AT_PCT": "30", "HANDOFF_MAX_PCT": "35"})[0], "over")

    def test_pct(self):
        self.assertAlmostEqual(context.level(450_000, M, {})[1], 45.0)


class TestHook(Tmp):
    def run_hook(self, session, tokens, active=False, model="claude-opus-5-5"):
        p = self.transcript(session, [usage_line("2026-11-24T10:00:00Z", model, tokens, 0, 0)])
        stdin = json.dumps({"session_id": session, "transcript_path": str(p), "cwd": "/x",
                            "hook_event_name": "Stop", "stop_hook_active": active})
        return context.hook(stdin, self.env, self.cache)

    def test_silent_below_the_limit(self):
        self.assertEqual(self.run_hook("s", 399_999), "")

    def test_silent_when_stop_hook_active(self):
        self.assertEqual(self.run_hook("s", 600_000, active=True), "")

    def test_silent_on_missing_transcript_or_bad_input(self):
        stdin = json.dumps({"session_id": "s", "transcript_path": str(self.tmp / "none.jsonl")})
        self.assertEqual(context.hook(stdin, self.env, self.cache), "")
        self.assertEqual(context.hook("not json", self.env, self.cache), "")

    def test_blocks_once_per_5_pct_step(self):
        out = json.loads(self.run_hook("s", 410_000))
        self.assertEqual(out["decision"], "block")
        self.assertIn("handoff-session-context", out["reason"])
        self.assertIn("410,000", out["reason"])
        self.assertEqual(self.run_hook("s", 440_000), "")          # same step 40
        self.assertEqual(json.loads(self.run_hook("s", 450_000))["decision"], "block")  # step 45
        self.assertEqual(self.run_hook("s", 470_000), "")          # same step 45

    def test_blocks_every_time_at_50_pct(self):
        for _ in range(3):
            out = json.loads(self.run_hook("s", 520_000))
            self.assertEqual(out["decision"], "block")
            self.assertTrue(out["reason"].startswith("LAST LIMIT"))

    def test_silent_after_mark_done(self):
        context.mark_done("s", "/p/HANDOFF.md", self.cache)
        self.assertEqual(self.run_hook("s", 900_000), "")

    def test_200k_model(self):  # an unknown model: the safe 200 k window
        out = json.loads(self.run_hook("h", 85_000, model="some-new-model"))
        self.assertEqual(out["decision"], "block")

    def test_haiku_has_a_1m_window(self):  # 2026-11-26 probe: Haiku 5.5 statusline 8 % at about 79 k tokens
        self.assertEqual(self.run_hook("h", 85_000, model="claude-haiku-5-5"), "")

    def test_cli_hook_exits_0_on_garbage(self):
        r = subprocess.run([sys.executable, str(SCRIPT), "hook"], input="garbage", text=True,
                           capture_output=True, env={**os.environ, "HANDOFF_CACHE_DIR": str(self.cache)})
        self.assertEqual((r.returncode, r.stdout), (0, ""))


class TestRecord(Tmp):
    def test_writes_cache(self):
        context.record(json.dumps({"session_id": "s", "model": {"id": "claude-opus-5-5"},
                                   "context_window": {"context_window_size": 1_000_000}}), self.cache)
        d = json.loads((self.cache / "s.json").read_text())
        self.assertEqual(d["window"], M)
        self.assertEqual(context.window_for("s", None, {}, self.cache), (M, "cache"))

    def test_bad_input_writes_nothing(self):
        context.record("garbage", self.cache)
        context.record(json.dumps({"session_id": "s"}), self.cache)
        context.record(json.dumps({"session_id": "../evil", "context_window": {"context_window_size": 5}}), self.cache)
        self.assertFalse(self.cache.exists() and any(self.cache.iterdir()))

    def test_cli_record_prints_nothing(self):
        r = subprocess.run([sys.executable, str(SCRIPT), "record"], input="garbage", text=True,
                           capture_output=True, env={**os.environ, "HANDOFF_CACHE_DIR": str(self.cache)})
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, "", ""))


class TestStatusline(Tmp):
    def line(self, pct, size=M, model="Opus 5.5", session="abcdef1234567890"):
        d = {"session_id": session, "model": {"id": "claude-opus-5-5", "display_name": model},
             "context_window": {"context_window_size": size, "used_percentage": pct}}
        return context.statusline(json.dumps(d), self.env, self.cache)

    def test_minimal_line(self):
        self.assertEqual(self.line(12), "Opus 5.5 #abcdef12 ctx 12%")

    def test_records_the_window(self):
        self.line(12)
        self.assertEqual(context.window_for("abcdef1234567890", None, {}, self.cache), (M, "cache"))

    def test_marks_handoff_and_over(self):
        self.assertEqual(self.line(41), "Opus 5.5 #abcdef12 ctx 41% HAND OFF")
        self.assertEqual(self.line(50), "Opus 5.5 #abcdef12 ctx 50% OVER")

    def test_limits_from_env(self):
        self.env = {"HANDOFF_AT_PCT": "30"}
        self.assertEqual(self.line(31), "Opus 5.5 #abcdef12 ctx 31% HAND OFF")

    def test_no_percentage_yet(self):  # before the first reply Claude Code sends no used_percentage
        self.assertEqual(self.line(None), "Opus 5.5 #abcdef12 ctx -")

    def test_garbage_gives_an_empty_line(self):
        self.assertEqual(context.statusline("garbage", self.env, self.cache), "")

    def test_cli_statusline(self):
        d = {"session_id": "s1", "model": {"display_name": "Haiku 5.5"},
             "context_window": {"context_window_size": M, "used_percentage": 8.4}}
        r = subprocess.run([sys.executable, str(SCRIPT), "statusline"], input=json.dumps(d), text=True,
                           capture_output=True, env={**os.environ, "HANDOFF_CACHE_DIR": str(self.cache)})
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, "Haiku 5.5 #s1 ctx 8%\n", ""))
        self.assertTrue((self.cache / "s1.json").exists())


class TestInstallStatusline(Tmp):
    CMD = 'sh "/x/claude/statusline.sh"'

    def test_creates_the_file_when_missing(self):
        s = self.tmp / "settings.json"
        self.assertEqual(context.install_statusline(s, self.CMD), "added")
        self.assertEqual(json.loads(s.read_text())["statusLine"], {"type": "command", "command": self.CMD})

    def test_keeps_other_content_backs_up_and_is_idempotent(self):
        s = self.tmp / "settings.json"
        s.write_text(json.dumps({"model": "opus"}, indent=2))
        self.assertEqual(context.install_statusline(s, self.CMD, today="20261126"), "added")
        self.assertEqual(json.loads((self.tmp / "settings.json.bak-20261126").read_text()), {"model": "opus"})
        self.assertEqual(json.loads(s.read_text())["model"], "opus")
        text = s.read_text()
        self.assertEqual(context.install_statusline(s, self.CMD), "present")
        self.assertEqual(s.read_text(), text)

    def test_a_new_clone_path_updates_our_line(self):
        s = self.tmp / "settings.json"
        context.install_statusline(s, 'sh "/old/clone/claude/statusline.sh"')
        self.assertEqual(context.install_statusline(s, self.CMD), "updated")
        self.assertEqual(json.loads(s.read_text())["statusLine"]["command"], self.CMD)

    def test_leaves_a_foreign_statusline_alone(self):
        s = self.tmp / "settings.json"
        s.write_text(json.dumps({"statusLine": {"type": "command", "command": "sh ~/.claude/statusline-command.sh"}}))
        text = s.read_text()
        self.assertEqual(context.install_statusline(s, self.CMD), "foreign")
        self.assertEqual(s.read_text(), text)

    def test_refuses_a_broken_settings_file(self):
        s = self.tmp / "settings.json"
        s.write_text("{broken")
        with self.assertRaises(ValueError):
            context.install_statusline(s, self.CMD)
        self.assertEqual(s.read_text(), "{broken")

    def test_cli_prints_the_result(self):
        s = self.tmp / "settings.json"
        r = subprocess.run([sys.executable, str(SCRIPT), "install-statusline", "--settings", str(s),
                            "--command", self.CMD], text=True, capture_output=True)
        self.assertEqual((r.returncode, r.stdout), (0, "added\n"))


class TestHandoffPath(Tmp):
    def test_docs_local_of_the_git_root(self):
        root = self.tmp / "repo"
        (root / ".git").mkdir(parents=True)
        (root / "docs" / "local").mkdir(parents=True)
        (root / "sub").mkdir()
        p = context.handoff_path(root / "sub", "example-app (watchdog-master)", "20261124")
        self.assertEqual(p, root / "docs/local/example-app-watchdog-master-handoff-20261124.md")

    def test_fallback_to_cwd_and_suffix(self):
        cwd = self.tmp / "plain"
        cwd.mkdir()
        p = context.handoff_path(cwd, "My Title", "20261124")
        self.assertEqual(p, cwd / "my-title-handoff-20261124.md")
        p.write_text("x")
        self.assertEqual(context.handoff_path(cwd, "My Title", "20261124"), cwd / "my-title-handoff-20261124-2.md")


class TestInstallHook(Tmp):
    def stop_commands(self, settings):
        d = json.loads(settings.read_text())
        return [h["command"] for g in d.get("hooks", {}).get("Stop", []) for h in g.get("hooks", [])]

    def test_creates_the_file_when_missing(self):
        s = self.tmp / "settings.json"
        self.assertEqual(context.install_hook(s), "added")
        self.assertEqual(self.stop_commands(s), [context.HOOK_COMMAND])

    def test_keeps_other_content_backs_up_and_is_idempotent(self):
        s = self.tmp / "settings.json"
        before = {"model": "opus", "statusLine": {"type": "command", "command": "sh x.sh"},
                  "hooks": {"Stop": [{"matcher": "*", "hooks": [{"type": "command", "command": "other"}]}],
                            "PostToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": "p"}]}]}}
        s.write_text(json.dumps(before, indent=2))
        self.assertEqual(context.install_hook(s, today="20261124"), "added")
        self.assertEqual(json.loads((self.tmp / "settings.json.bak-20261124").read_text()), before)
        after = json.loads(s.read_text())
        self.assertEqual(after["model"], "opus")
        self.assertEqual(after["statusLine"], before["statusLine"])
        self.assertEqual(after["hooks"]["PostToolUse"], before["hooks"]["PostToolUse"])
        self.assertEqual(self.stop_commands(s), ["other", context.HOOK_COMMAND])
        text = s.read_text()
        self.assertEqual(context.install_hook(s, today="20261124"), "present")
        self.assertEqual(s.read_text(), text)

    def test_refuses_a_broken_settings_file(self):
        s = self.tmp / "settings.json"
        s.write_text("{broken")
        with self.assertRaises(ValueError):
            context.install_hook(s)
        self.assertEqual(s.read_text(), "{broken")


class TestSizeCli(Tmp):
    def test_size_line_and_json(self):
        self.transcript("s", [usage_line("t", "claude-opus-5-5", 100, 200_000, 250_000)], cwd="/w/p")
        env = {**os.environ, "HANDOFF_PROJECTS_DIR": str(self.projects), "HANDOFF_CACHE_DIR": str(self.cache)}
        env.pop("HANDOFF_WINDOW_TOKENS", None)
        env.pop("CLAUDE_CODE_MAX_CONTEXT_TOKENS", None)
        r = subprocess.run([sys.executable, str(SCRIPT), "size", "--session", "s", "--cwd", "/w/p"],
                           text=True, capture_output=True, env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(),
                         "tokens=450100 window=1000000 pct=45.0 level=handoff model=claude-opus-5-5 source=table")
        r = subprocess.run([sys.executable, str(SCRIPT), "size", "--session", "s", "--cwd", "/w/p", "--json"],
                           text=True, capture_output=True, env=env)
        self.assertEqual(json.loads(r.stdout)["level"], "handoff")

    def test_size_unknown_session_exits_1(self):
        env = {**os.environ, "HANDOFF_PROJECTS_DIR": str(self.projects)}
        r = subprocess.run([sys.executable, str(SCRIPT), "size", "--session", "nope"], text=True,
                           capture_output=True, env=env)
        self.assertEqual(r.returncode, 1)


if __name__ == "__main__":
    unittest.main()
