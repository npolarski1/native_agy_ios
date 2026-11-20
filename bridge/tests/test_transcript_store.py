"""Unit tests for TranscriptStore, path-traversal protection, tasks, subagents, and swarms."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

_BRIDGE_ROOT = str(Path(__file__).resolve().parent.parent)
if _BRIDGE_ROOT not in sys.path:
    sys.path.insert(0, _BRIDGE_ROOT)

from antigravity_bridge.transcript_store import (
    PathTraversalError,
    ResourceNotFoundError,
    SessionNotFoundError,
    TranscriptStore,
)


def _write_jsonl(path: Path, rows: list[dict[str, object]], *, trailing_garbage: str = "") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as fh:
        for row in rows:
            fh.write(json.dumps(row) + "\n")
        if trailing_garbage:
            fh.write(trailing_garbage)


class TranscriptStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.brain_dir = Path(self._tmp.name) / "brain"
        self.brain_dir.mkdir(parents=True, exist_ok=True)
        self.store = TranscriptStore(self.brain_dir)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _create_rich_session(self, session_id: str = "conv-1234") -> Path:
        sdir = self.brain_dir / session_id
        logs = sdir / ".system_generated" / "logs"
        tasks = sdir / ".system_generated" / "tasks"
        media_dir = sdir / ".system_generated" / "media"
        logs.mkdir(parents=True, exist_ok=True)
        tasks.mkdir(parents=True, exist_ok=True)
        media_dir.mkdir(parents=True, exist_ok=True)

        screenshot_path = media_dir / "ui_snap.png"
        screenshot_path.write_bytes(b"\x89PNG\r\n\x1a\nFAKEPNGDATA")

        compact_rows = [
            {
                "step_index": 0,
                "source": "USER_EXPLICIT",
                "type": "USER_INPUT",
                "status": "DONE",
                "created_at": "2026-11-20T20:00:00Z",
                "content": "Build the iOS Antigravity Monitor companion app",
            },
            {
                "step_index": 1,
                "source": "MODEL",
                "type": "PLANNER_RESPONSE",
                "status": "DONE",
                "created_at": "2026-11-20T20:00:05Z",
                "model": "gemini-3-pro",
                "input_tokens": 1200,
                "cache_read_tokens": 400,
                "output_tokens": 250,
                "thinking": "Truncated thinking...",
                "content": "Truncated content...",
                "truncated_fields": ["content", "thinking"],
                "tool_calls": [
                    {
                        "name": "invoke_subagent",
                        "args": {
                            "name": '"ios-core"',
                            "type": '"coder"',
                            "prompt": '"Implement Swift package models and client"',
                        },
                    },
                    {
                        "name": "swarm",
                        "args": {
                            "action": "add",
                            "name": "bridge-dev",
                            "brief": "Build stdlib Python bridge server",
                        },
                    },
                ],
                "media": [
                    {
                        "mime_type": "image/png",
                        "uri": str(screenshot_path),
                    }
                ],
            },
            {
                "step_index": 2,
                "source": "MODEL",
                "type": "PLANNER_RESPONSE",
                "status": "DONE",
                "created_at": "2026-11-20T20:01:00Z",
                "model": "gemini-3-pro",
                "input_tokens": 800,
                "cache_read_tokens": 1000,
                "output_tokens": 150,
                "content": "All components completed successfully.",
                "tool_calls": [
                    {
                        "name": "post_message",
                        "args": {"text": "@coordinator [done] Finished bridge"},
                    }
                ],
            },
        ]

        full_rows = [
            compact_rows[0],
            {
                **compact_rows[1],
                "thinking": "Full deep reasoning about architecture and wire contract.",
                "content": "Full untruncated response content with all details.",
                "truncated_fields": [],
            },
            compact_rows[2],
        ]

        _write_jsonl(logs / "transcript.jsonl", compact_rows, trailing_garbage='{"step_index": 99, "broken')
        _write_jsonl(logs / "transcript_full.jsonl", full_rows)

        # Artifacts & excluded directories
        (sdir / "implementation_plan.md").write_text("# Plan\n\nBuild bridge.\n", encoding="utf-8")
        (sdir / "diagrams").mkdir()
        (sdir / "diagrams" / "arch.png").write_bytes(b"\x89PNG\r\n\x1a\nARCH")
        (sdir / "scratch").mkdir()
        (sdir / "scratch" / "temp.py").write_text("print('scratch')\n", encoding="utf-8")
        (sdir / ".hidden.txt").write_text("hidden", encoding="utf-8")

        # Background task log
        lines = [f"log line {i}" for i in range(100)]
        (tasks / "task-build-01.log").write_text("\n".join(lines) + "\n", encoding="utf-8")

        return sdir

    def test_empty_and_missing_brain_dir(self) -> None:
        missing = TranscriptStore(Path(self._tmp.name) / "does-not-exist")
        self.assertFalse(missing.brain_dir_exists())
        self.assertEqual(missing.list_sessions(), [])
        with self.assertRaises(SessionNotFoundError):
            missing.get_session("abc")

    def test_session_summary_tokens_status_and_counts(self) -> None:
        self._create_rich_session("conv-1234")
        sessions = self.store.list_sessions()
        self.assertEqual(len(sessions), 1)
        s = sessions[0]
        self.assertEqual(s.id, "conv-1234")
        self.assertEqual(s.title, "Build the iOS Antigravity Monitor companion app")
        self.assertEqual(s.step_count, 3)
        self.assertEqual(s.model, "gemini-3-pro")
        self.assertEqual(s.input_tokens, 2000)
        self.assertEqual(s.cache_read_tokens, 1400)
        self.assertEqual(s.output_tokens, 400)
        self.assertEqual(s.artifact_count, 2)  # implementation_plan.md + diagrams/arch.png (excludes scratch & hidden)
        self.assertEqual(s.task_count, 1)
        self.assertEqual(s.subagent_count, 1)
        self.assertTrue(s.has_swarm)
        # Last step had a tool_call without subsequent result => running
        self.assertEqual(s.status, "running")

        # Pending approval overrides status to waiting
        waiting = self.store.get_session("conv-1234", has_pending_approval=True)
        self.assertEqual(waiting.status, "waiting")

        # Stop hook hint marks completed
        completed = self.store.get_session("conv-1234", hook_status_hint="completed")
        self.assertEqual(completed.status, "completed")

    def test_transcript_pagination_and_full_hydration(self) -> None:
        self._create_rich_session("conv-1234")

        total, compact_steps = self.store.get_transcript("conv-1234", since_step=0, limit=200, full=False)
        self.assertEqual(total, 3)
        self.assertEqual(len(compact_steps), 3)
        self.assertEqual(compact_steps[1].content, "Truncated content...")
        self.assertEqual(compact_steps[1].truncated_fields, ["content", "thinking"])
        self.assertEqual(compact_steps[1].media[0].filename, "ui_snap.png")
        self.assertEqual(compact_steps[1].media[0].url_path, "/api/v1/sessions/conv-1234/media/ui_snap.png")

        # Full hydration replaces truncated fields from transcript_full.jsonl
        total_full, full_steps = self.store.get_transcript("conv-1234", since_step=1, limit=1, full=True)
        self.assertEqual(total_full, 3)
        self.assertEqual(len(full_steps), 1)
        self.assertEqual(full_steps[0].step_index, 1)
        self.assertEqual(full_steps[0].content, "Full untruncated response content with all details.")
        self.assertEqual(full_steps[0].thinking, "Full deep reasoning about architecture and wire contract.")
        self.assertEqual(full_steps[0].truncated_fields, [])

    def test_artifacts_and_media_serving_with_path_traversal_protection(self) -> None:
        sdir = self._create_rich_session("conv-1234")
        outside_secret = self.brain_dir.parent / "secret.txt"
        outside_secret.write_text("TOP SECRET", encoding="utf-8")

        artifacts = self.store.list_artifacts("conv-1234")
        rel_paths = {a.relative_path for a in artifacts}
        self.assertEqual(rel_paths, {"implementation_plan.md", "diagrams/arch.png"})
        img = next(a for a in artifacts if a.relative_path == "diagrams/arch.png")
        self.assertTrue(img.is_image)
        self.assertEqual(img.mime_type, "image/png")

        name, rel, mime, data = self.store.read_artifact("conv-1234", "implementation_plan.md")
        self.assertEqual(name, "implementation_plan.md")
        self.assertEqual(rel, "implementation_plan.md")
        self.assertEqual(mime, "text/markdown")
        self.assertIn(b"Build bridge.", data)

        # Media read from .system_generated/media
        m_mime, m_bytes = self.store.read_media("conv-1234", "ui_snap.png")
        self.assertEqual(m_mime, "image/png")
        self.assertTrue(m_bytes.startswith(b"\x89PNG"))

        # Path traversal attacks MUST raise PathTraversalError
        for bad_path in (
            "../secret.txt",
            "../../secret.txt",
            "..\\secret.txt",
            "/etc/passwd",
            "C:\\Windows\\win.ini",
            ".system_generated/logs/transcript.jsonl",
            "scratch/temp.py",
            ".hidden.txt",
            "diagrams/../../secret.txt",
        ):
            with self.subTest(bad_path=bad_path):
                with self.assertRaises(PathTraversalError):
                    self.store.read_artifact("conv-1234", bad_path)

        for bad_media in ("../secret.txt", "sub/ui_snap.png", "..\\secret.txt", "C:foo.png"):
            with self.subTest(bad_media=bad_media):
                with self.assertRaises(PathTraversalError):
                    self.store.read_media("conv-1234", bad_media)

        with self.assertRaises(ResourceNotFoundError):
            self.store.read_artifact("conv-1234", "missing.md")

        # Symlink escape check (skip gracefully if Windows denies symlink creation without privilege)
        link_path = sdir / "escape_link.txt"
        try:
            os.symlink(outside_secret, link_path)
        except OSError:
            return
        with self.assertRaises(PathTraversalError):
            self.store.read_artifact("conv-1234", "escape_link.txt")

    def test_tasks_subagents_and_swarm_events(self) -> None:
        self._create_rich_session("conv-1234")
        tasks, subagents, swarm_events = self.store.get_session_tasks("conv-1234")

        self.assertEqual(len(tasks), 1)
        self.assertEqual(tasks[0].task_id, "task-build-01")
        self.assertEqual(tasks[0].filename, "task-build-01.log")
        self.assertIn("log line 99", tasks[0].tail)
        self.assertNotIn("log line 0\n", tasks[0].tail)

        self.assertEqual(len(subagents), 1)
        self.assertEqual(subagents[0].role, "ios-core")
        self.assertEqual(subagents[0].type_name, "coder")
        self.assertIn("Swift package", subagents[0].prompt_preview)

        self.assertEqual(len(swarm_events), 2)
        self.assertEqual(swarm_events[0].action, "add")
        self.assertEqual(swarm_events[0].target, "bridge-dev")
        self.assertEqual(swarm_events[1].action, "post_message")
        self.assertEqual(swarm_events[1].target, "@coordinator")


if __name__ == "__main__":
    unittest.main()
