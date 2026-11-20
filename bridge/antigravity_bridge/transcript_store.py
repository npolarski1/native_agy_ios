"""Read-only parser and cached store for Google Antigravity 2.0 brain directories."""

from __future__ import annotations

import json
import mimetypes
import os
import re
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any
from urllib.parse import quote, unquote

from .models import (
    ArtifactItem,
    MediaAttachment,
    SessionSummary,
    SubagentInvocation,
    SwarmEventItem,
    TaskLogItem,
    ToolCallItem,
    TranscriptStep,
    format_iso_utc,
    normalize_iso_utc,
    parse_iso_utc,
    utc_now,
)


class BridgeStoreError(Exception):
    """Base error for transcript store failures."""


class PathTraversalError(BridgeStoreError):
    """Raised when an untrusted path attempts directory escape or forbidden access."""


class SessionNotFoundError(BridgeStoreError):
    """Raised when a requested conversation session does not exist."""


class ResourceNotFoundError(BridgeStoreError):
    """Raised when a requested artifact or media file does not exist."""


_EXCLUDED_ARTIFACT_DIRS = frozenset({".system_generated", "scratch"})
_SWARM_TOOL_NAMES = frozenset({"swarm", "post_message", "read_board", "swarm_wait"})
_SUBAGENT_TOOL_NAMES = frozenset({"invoke_subagent", "subagent"})
_MENTION_RE = re.compile(r"@([a-zA-Z0-9_-]+)")
_MAX_TITLE_LEN = 88
_MAX_PREVIEW_LEN = 160
_TASK_TAIL_READ_BYTES = 8192
_TASK_TAIL_MAX_LINES = 60
_TASK_TAIL_MAX_CHARS = 4000

_MIME_OVERRIDES: dict[str, str] = {
    ".md": "text/markdown",
    ".markdown": "text/markdown",
    ".txt": "text/plain",
    ".log": "text/plain",
    ".json": "application/json",
    ".jsonl": "application/x-ndjson",
    ".yaml": "text/yaml",
    ".yml": "text/yaml",
    ".csv": "text/csv",
    ".html": "text/html",
    ".htm": "text/html",
    ".xml": "application/xml",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".gif": "image/gif",
    ".webp": "image/webp",
    ".heic": "image/heic",
    ".pdf": "application/pdf",
    ".py": "text/x-python",
    ".swift": "text/x-swift",
    ".ts": "text/typescript",
    ".js": "text/javascript",
    ".sh": "text/x-shellscript",
}


def guess_mime_type(path: Path) -> str:
    """Return a deterministic MIME type for a file path."""
    suffix = path.suffix.lower()
    if suffix in _MIME_OVERRIDES:
        return _MIME_OVERRIDES[suffix]
    guessed, _ = mimetypes.guess_type(str(path))
    return guessed or "application/octet-stream"


def _unwrap_value(value: Any) -> Any:
    """Unwrap JSON-encoded strings found in protojson-serialized Antigravity tool args."""
    if isinstance(value, str) and len(value) >= 2:
        if value[0] == '"' and value[-1] == '"':
            try:
                decoded = json.loads(value)
                if isinstance(decoded, str):
                    return decoded
            except json.JSONDecodeError:
                pass
    return value


def _normalize_tool_args(raw_args: Any) -> dict[str, Any]:
    """Normalize raw tool call arguments into a clean JSON-serializable dict."""
    if isinstance(raw_args, dict):
        return {str(k): _unwrap_value(v) for k, v in raw_args.items()}
    if isinstance(raw_args, str):
        raw_str = raw_args.strip()
        if raw_str:
            try:
                parsed = json.loads(raw_str)
                if isinstance(parsed, dict):
                    return {str(k): _unwrap_value(v) for k, v in parsed.items()}
                return {"value": parsed}
            except json.JSONDecodeError:
                return {"raw": raw_args}
        return {}
    if raw_args is None:
        return {}
    return {"value": raw_args}


def _extract_media_filename(uri: str) -> str:
    """Extract a clean basename from a file URI or OS path (POSIX or Windows)."""
    cleaned = uri.strip()
    if cleaned.startswith("file:///"):
        cleaned = unquote(cleaned[8:])
    elif cleaned.startswith("file://"):
        cleaned = unquote(cleaned[7:])
    # Split on both POSIX and Windows separators so cross-platform logs parse cleanly.
    parts = [p for p in re.split(r"[\\/]+", cleaned) if p]
    return parts[-1] if parts else "attachment"


def _uri_to_path(uri: str) -> Path | None:
    """Convert a local file path or file:// URI into a Path if possible."""
    cleaned = uri.strip()
    if not cleaned:
        return None
    if cleaned.startswith("file:///"):
        remainder = unquote(cleaned[8:])
        # On POSIX file:///path/to/file needs leading slash unless Windows drive (e.g. C:/...)
        if os.name != "nt" and not remainder.startswith("/"):
            remainder = "/" + remainder
        return Path(remainder)
    if cleaned.startswith("file://"):
        return Path(unquote(cleaned[7:]))
    if "://" in cleaned:
        return None
    return Path(cleaned)


def _collapse_line(text: str, max_len: int) -> str:
    """Collapse whitespace to a single readable line truncated cleanly."""
    cleaned = re.sub(r"\s+", " ", text).strip()
    if len(cleaned) <= max_len:
        return cleaned
    return cleaned[: max_len - 1].rstrip() + "…"


def _clean_system_title(content: str) -> str:
    """Extract a clean readable title when a session starts with a system/swarm message."""
    if "<SYSTEM_MESSAGE>" in content:
        # Try to extract the swarm brief or meaningful content after "content="
        match = re.search(r"content=(.+?)(?:</SYSTEM_MESSAGE>|$)", content, re.DOTALL)
        if match:
            inner = match.group(1).strip()
            for line in inner.splitlines():
                stripped = line.strip()
                if stripped and not stripped.startswith("[Message]"):
                    return _collapse_line(stripped, _MAX_TITLE_LEN)
    for line in content.splitlines():
        stripped = line.strip()
        if stripped:
            return _collapse_line(stripped, _MAX_TITLE_LEN)
    return _collapse_line(content, _MAX_TITLE_LEN)


def validate_session_id(session_id: str) -> str:
    """Validate that a session_id is a single safe directory name."""
    if not session_id or session_id in (".", ".."):
        raise PathTraversalError("Invalid session identifier.")
    if "\x00" in session_id or "/" in session_id or "\\" in session_id or ":" in session_id:
        raise PathTraversalError("Invalid characters in session identifier.")
    if ".." in session_id:
        raise PathTraversalError("Path traversal sequence rejected in session identifier.")
    return session_id


def safe_resolve_under(
    base_dir: Path,
    untrusted_rel: str,
    *,
    forbid_top_dirs: frozenset[str] = frozenset(),
    forbid_hidden: bool = False,
) -> Path:
    """Resolve an untrusted relative path strictly beneath base_dir, defeating traversal & symlinks."""
    if not untrusted_rel or "\x00" in untrusted_rel:
        raise PathTraversalError("Empty or invalid path.")
    if untrusted_rel.startswith(("/", "\\")):
        raise PathTraversalError("Absolute paths are forbidden.")

    # Reject Windows drive letters or UNC prefixes regardless of host OS.
    if re.match(r"^[a-zA-Z]:", untrusted_rel):
        raise PathTraversalError("Drive-qualified paths are forbidden.")

    raw_parts = re.split(r"[\\/]+", untrusted_rel)
    parts: list[str] = []
    for part in raw_parts:
        if part == "":
            continue
        if part in (".", "..") or ":" in part or "\x00" in part:
            raise PathTraversalError("Path traversal segment rejected.")
        if forbid_hidden and part.startswith("."):
            raise PathTraversalError("Hidden paths are forbidden.")
        parts.append(part)

    if not parts:
        raise PathTraversalError("Empty path after normalization.")
    if parts[0] in forbid_top_dirs:
        raise PathTraversalError(f"Access to restricted directory '{parts[0]}' is forbidden.")

    base_resolved = base_dir.resolve()
    candidate = (base_resolved.joinpath(*parts)).resolve()

    try:
        is_inside = candidate.is_relative_to(base_resolved)
    except ValueError:
        is_inside = False

    if not is_inside or candidate == base_resolved:
        raise PathTraversalError("Resolved path escapes session directory.")

    return candidate


@dataclass(slots=True)
class _ParsedTranscriptCache:
    mtime_ns: int
    size: int
    full_mtime_ns: int | None
    full_size: int | None
    steps: list[TranscriptStep]
    subagents: list[SubagentInvocation]
    swarm_events: list[SwarmEventItem]
    media_uris: dict[str, Path]


class TranscriptStore:
    """Filesystem-backed store reading Antigravity 2.0 sessions, transcripts, artifacts, and tasks."""

    def __init__(self, brain_dir: Path | str, *, active_threshold_seconds: int = 120) -> None:
        self.brain_dir = Path(brain_dir).expanduser()
        self.active_threshold_seconds = active_threshold_seconds
        self._cache: dict[tuple[str, bool], _ParsedTranscriptCache] = {}

    def brain_dir_exists(self) -> bool:
        return self.brain_dir.is_dir()

    def _session_dir(self, session_id: str) -> Path:
        safe_id = validate_session_id(session_id)
        if not self.brain_dir.is_dir():
            raise SessionNotFoundError(f"Session '{safe_id}' not found.")
        base_resolved = self.brain_dir.resolve()
        candidate = (base_resolved / safe_id).resolve()
        if not candidate.is_relative_to(base_resolved) or candidate == base_resolved:
            raise PathTraversalError("Session path escapes brain directory.")
        if not candidate.is_dir():
            raise SessionNotFoundError(f"Session '{safe_id}' not found.")
        return candidate

    def _iter_session_dirs(self) -> list[Path]:
        if not self.brain_dir.is_dir():
            return []
        result: list[Path] = []
        try:
            entries = list(self.brain_dir.iterdir())
        except OSError:
            return []
        for entry in entries:
            if entry.name.startswith("."):
                continue
            try:
                if not entry.is_dir():
                    continue
                # Accept any non-hidden directory containing Antigravity logs/system dir or files.
                if (entry / ".system_generated").is_dir() or any(entry.iterdir()):
                    result.append(entry)
            except OSError:
                continue
        return result

    def _parse_jsonl_file(self, path: Path) -> list[dict[str, Any]]:
        records: list[dict[str, Any]] = []
        try:
            with path.open("r", encoding="utf-8", errors="replace") as fh:
                for raw_line in fh:
                    line = raw_line.strip()
                    if not line:
                        continue
                    try:
                        obj = json.loads(line)
                    except json.JSONDecodeError:
                        # Tolerate partially written trailing lines while Antigravity is streaming.
                        continue
                    if isinstance(obj, dict):
                        records.append(obj)
        except OSError:
            return []
        return records

    def _load_parsed_transcript(self, session_id: str, session_dir: Path, *, full: bool = False) -> _ParsedTranscriptCache:
        logs_dir = session_dir / ".system_generated" / "logs"
        compact_path = logs_dir / "transcript.jsonl"
        full_path = logs_dir / "transcript_full.jsonl"

        try:
            st = compact_path.stat()
            mtime_ns, size = st.st_mtime_ns, st.st_size
        except OSError:
            mtime_ns, size = -1, -1

        full_mtime_ns: int | None = None
        full_size: int | None = None
        if full and full_path.is_file():
            try:
                fst = full_path.stat()
                full_mtime_ns, full_size = fst.st_mtime_ns, fst.st_size
            except OSError:
                pass

        cache_key = (session_id, full)
        cached = self._cache.get(cache_key)
        if (
            cached is not None
            and cached.mtime_ns == mtime_ns
            and cached.size == size
            and cached.full_mtime_ns == full_mtime_ns
            and cached.full_size == full_size
        ):
            return cached

        compact_records = self._parse_jsonl_file(compact_path) if mtime_ns >= 0 else []

        full_by_step: dict[int, dict[str, Any]] = {}
        full_records: list[dict[str, Any]] = []
        if full and full_mtime_ns is not None:
            full_records = self._parse_jsonl_file(full_path)
            for idx, rec in enumerate(full_records):
                sidx = rec.get("step_index")
                key = int(sidx) if isinstance(sidx, int) else idx
                full_by_step[key] = rec

        if compact_records:
            raw_records = compact_records
        elif full_records:
            raw_records = full_records
        else:
            raw_records = []

        fallback_ts = (
            datetime.fromtimestamp(mtime_ns / 1e9).astimezone()
            if mtime_ns > 0
            else None
        )

        steps: list[TranscriptStep] = []
        subagents: list[SubagentInvocation] = []
        swarm_events: list[SwarmEventItem] = []
        media_uris: dict[str, Path] = {}

        for seq_idx, rec in enumerate(raw_records):
            step_index = rec.get("step_index")
            if not isinstance(step_index, int):
                step_index = seq_idx

            merged = rec
            if full and step_index in full_by_step:
                # Merge full fields when available (especially truncated_fields).
                merged = {**rec, **full_by_step[step_index]}

            source = str(merged.get("source") or "SYSTEM")
            step_type = str(merged.get("type") or "GENERIC")
            status = str(merged.get("status") or "DONE")
            created_at = normalize_iso_utc(
                merged.get("created_at") if isinstance(merged.get("created_at"), str) else None,
                fallback=fallback_ts,
            )

            model_raw = merged.get("model")
            model = str(model_raw) if isinstance(model_raw, str) and model_raw.strip() else None

            input_tokens = merged.get("input_tokens") if isinstance(merged.get("input_tokens"), int) else None
            cache_read_tokens = (
                merged.get("cache_read_tokens") if isinstance(merged.get("cache_read_tokens"), int) else None
            )
            output_tokens = merged.get("output_tokens") if isinstance(merged.get("output_tokens"), int) else None

            content_raw = merged.get("content")
            content = str(content_raw) if content_raw is not None else None

            thinking_raw = merged.get("thinking")
            thinking = str(thinking_raw) if thinking_raw is not None else None

            tool_calls: list[ToolCallItem] = []
            raw_tool_calls = merged.get("tool_calls")
            if isinstance(raw_tool_calls, list):
                for tc in raw_tool_calls:
                    if not isinstance(tc, dict):
                        continue
                    tc_name = str(tc.get("name") or "unknown_tool")
                    norm_args = _normalize_tool_args(tc.get("args"))
                    args_json = json.dumps(norm_args, ensure_ascii=False, sort_keys=True)
                    tool_calls.append(ToolCallItem(name=tc_name, args_json=args_json))

                    if tc_name in _SUBAGENT_TOOL_NAMES:
                        role = str(
                            norm_args.get("name")
                            or norm_args.get("role")
                            or norm_args.get("subagent_name")
                            or norm_args.get("agent")
                            or "subagent"
                        )
                        type_name = str(
                            norm_args.get("type")
                            or norm_args.get("type_name")
                            or norm_args.get("subagent_type")
                            or "custom"
                        )
                        prompt_raw = (
                            norm_args.get("prompt")
                            or norm_args.get("task")
                            or norm_args.get("brief")
                            or norm_args.get("message")
                            or ""
                        )
                        subagents.append(
                            SubagentInvocation(
                                step_index=step_index,
                                role=role,
                                type_name=type_name,
                                prompt_preview=_collapse_line(str(prompt_raw), 200),
                                created_at=created_at,
                            )
                        )

                    if tc_name in _SWARM_TOOL_NAMES:
                        swarm_event = self._extract_swarm_event(step_index, tc_name, norm_args, created_at)
                        if swarm_event is not None:
                            swarm_events.append(swarm_event)

            media_items: list[MediaAttachment] = []
            raw_media = merged.get("media")
            if isinstance(raw_media, list):
                for m in raw_media:
                    if not isinstance(m, dict):
                        continue
                    uri = str(m.get("uri") or "")
                    filename = _extract_media_filename(uri)
                    mime_type = str(m.get("mime_type") or guess_mime_type(Path(filename)))
                    url_path = f"/api/v1/sessions/{quote(session_id, safe='')}/media/{quote(filename, safe='')}"
                    media_items.append(
                        MediaAttachment(
                            mime_type=mime_type,
                            filename=filename,
                            url_path=url_path,
                        )
                    )
                    uri_path = _uri_to_path(uri)
                    if uri_path is not None:
                        media_uris[filename] = uri_path

            raw_truncated = merged.get("truncated_fields")
            if isinstance(raw_truncated, list):
                truncated_fields = [str(f) for f in raw_truncated if isinstance(f, str)]
                if full and step_index in full_by_step and not full_by_step[step_index].get("truncated_fields"):
                    truncated_fields = []
            else:
                truncated_fields = []

            steps.append(
                TranscriptStep(
                    step_index=step_index,
                    source=source,
                    type=step_type,
                    status=status,
                    created_at=created_at,
                    model=model,
                    input_tokens=input_tokens,
                    cache_read_tokens=cache_read_tokens,
                    output_tokens=output_tokens,
                    content=content,
                    thinking=thinking,
                    tool_calls=tool_calls,
                    media=media_items,
                    truncated_fields=truncated_fields,
                )
            )

        parsed = _ParsedTranscriptCache(
            mtime_ns=mtime_ns,
            size=size,
            full_mtime_ns=full_mtime_ns,
            full_size=full_size,
            steps=steps,
            subagents=subagents,
            swarm_events=swarm_events,
            media_uris=media_uris,
        )
        self._cache[cache_key] = parsed
        return parsed

    def _extract_swarm_event(
        self,
        step_index: int,
        tool_name: str,
        args: dict[str, Any],
        created_at: str,
    ) -> SwarmEventItem | None:
        if tool_name == "swarm":
            action = str(args.get("action") or "swarm")
            target_raw = args.get("name") or args.get("target")
            target = str(target_raw) if target_raw else None
            summary_src = (
                args.get("brief")
                or args.get("title")
                or args.get("model")
                or (f"{action} {target}" if target else f"swarm {action}")
            )
            return SwarmEventItem(
                step_index=step_index,
                action=action,
                target=target,
                summary=_collapse_line(str(summary_src), 200),
                created_at=created_at,
            )
        if tool_name == "post_message":
            text = str(args.get("text") or "")
            mention_match = _MENTION_RE.search(text)
            target = f"@{mention_match.group(1)}" if mention_match else None
            return SwarmEventItem(
                step_index=step_index,
                action="post_message",
                target=target,
                summary=_collapse_line(text or "Posted board message", 200),
                created_at=created_at,
            )
        if tool_name == "swarm_wait":
            since = args.get("since", 0)
            return SwarmEventItem(
                step_index=step_index,
                action="wait",
                target=None,
                summary=f"Waiting for swarm messages since #{since}",
                created_at=created_at,
            )
        if tool_name == "read_board":
            since = args.get("since")
            seqs = args.get("seqs")
            detail = f"seqs={seqs}" if seqs is not None else f"since #{since or 0}"
            return SwarmEventItem(
                step_index=step_index,
                action="read_board",
                target=None,
                summary=f"Read swarm board ({detail})",
                created_at=created_at,
            )
        return None

    def _derive_title(self, session_id: str, steps: list[TranscriptStep]) -> str:
        for step in steps:
            if step.type == "USER_INPUT" and step.content and step.content.strip():
                return _collapse_line(step.content, _MAX_TITLE_LEN)
        for step in steps:
            if step.source == "USER_EXPLICIT" and step.content and step.content.strip():
                return _collapse_line(step.content, _MAX_TITLE_LEN)
        for step in steps:
            if step.content and step.content.strip():
                return _clean_system_title(step.content)
        return f"Session {session_id[:8]}"

    def _derive_preview(self, steps: list[TranscriptStep]) -> str | None:
        for step in reversed(steps):
            if step.content and step.content.strip():
                return _collapse_line(step.content, _MAX_PREVIEW_LEN)
            if step.tool_calls:
                names = ", ".join(tc.name for tc in step.tool_calls[:4])
                suffix = "…" if len(step.tool_calls) > 4 else ""
                return _collapse_line(f"Called {names}{suffix}", _MAX_PREVIEW_LEN)
            if step.thinking and step.thinking.strip():
                return _collapse_line(step.thinking, _MAX_PREVIEW_LEN)
        return None

    def _derive_status(
        self,
        steps: list[TranscriptStep],
        updated_at: str,
        *,
        has_pending_approval: bool = False,
        hook_status_hint: str | None = None,
    ) -> str:
        if has_pending_approval:
            return "waiting"
        if hook_status_hint == "completed":
            return "completed"
        if not steps:
            return "idle"

        last = steps[-1]
        last_status = last.status.upper()
        if last_status in ("RUNNING", "IN_PROGRESS", "PENDING", "STREAMING"):
            return "running"
        if last_status in ("ERROR", "FAILED"):
            return "error"

        if last.type == "USER_INPUT":
            return "running"
        if last.type == "PLANNER_RESPONSE":
            if last.tool_calls:
                return "running"
            if last_status == "DONE":
                return "completed"

        if hook_status_hint == "running":
            return "running"

        updated_dt = parse_iso_utc(updated_at)
        if updated_dt is not None:
            age = (utc_now() - updated_dt).total_seconds()
            if 0 <= age <= self.active_threshold_seconds and last.type in ("GENERIC", "TOOL_RESULT"):
                return "running"

        return "idle"

    def _count_task_logs(self, session_dir: Path) -> int:
        tasks_dir = session_dir / ".system_generated" / "tasks"
        if not tasks_dir.is_dir():
            return 0
        try:
            return sum(1 for p in tasks_dir.iterdir() if p.is_file() and p.suffix.lower() == ".log")
        except OSError:
            return 0

    def _build_session_summary(
        self,
        session_dir: Path,
        *,
        has_pending_approval: bool = False,
        hook_status_hint: str | None = None,
    ) -> SessionSummary:
        session_id = session_dir.name
        parsed = self._load_parsed_transcript(session_id, session_dir, full=False)
        steps = parsed.steps

        try:
            dir_mtime = session_dir.stat().st_mtime
        except OSError:
            dir_mtime = utc_now().timestamp()

        if steps:
            created_at = steps[0].created_at
            updated_at = steps[-1].created_at
        else:
            created_at = format_iso_utc(dir_mtime)
            updated_at = created_at

        model: str | None = None
        input_tokens = 0
        cache_read_tokens = 0
        output_tokens = 0
        for step in steps:
            if step.model:
                model = step.model
            if step.input_tokens is not None:
                input_tokens += step.input_tokens
            if step.cache_read_tokens is not None:
                cache_read_tokens += step.cache_read_tokens
            if step.output_tokens is not None:
                output_tokens += step.output_tokens

        artifacts = self._scan_artifacts(session_dir)
        task_count = self._count_task_logs(session_dir)
        status = self._derive_status(
            steps,
            updated_at,
            has_pending_approval=has_pending_approval,
            hook_status_hint=hook_status_hint,
        )

        return SessionSummary(
            id=session_id,
            title=self._derive_title(session_id, steps),
            status=status,
            created_at=created_at,
            updated_at=updated_at,
            step_count=len(steps),
            model=model,
            input_tokens=input_tokens,
            cache_read_tokens=cache_read_tokens,
            output_tokens=output_tokens,
            artifact_count=len(artifacts),
            task_count=task_count,
            subagent_count=len(parsed.subagents),
            has_swarm=len(parsed.swarm_events) > 0,
            last_step_preview=self._derive_preview(steps),
        )

    def list_sessions(
        self,
        *,
        limit: int = 50,
        pending_session_ids: set[str] | None = None,
        hook_status_hints: dict[str, str] | None = None,
    ) -> list[SessionSummary]:
        """List discovered Antigravity sessions sorted newest-first."""
        pending_ids = pending_session_ids or set()
        hints = hook_status_hints or {}
        summaries: list[SessionSummary] = []
        for sdir in self._iter_session_dirs():
            sid = sdir.name
            summaries.append(
                self._build_session_summary(
                    sdir,
                    has_pending_approval=(sid in pending_ids),
                    hook_status_hint=hints.get(sid),
                )
            )
        summaries.sort(key=lambda s: (s.updated_at, s.id), reverse=True)
        if limit > 0:
            return summaries[:limit]
        return summaries

    def get_session(
        self,
        session_id: str,
        *,
        has_pending_approval: bool = False,
        hook_status_hint: str | None = None,
    ) -> SessionSummary:
        sdir = self._session_dir(session_id)
        return self._build_session_summary(
            sdir,
            has_pending_approval=has_pending_approval,
            hook_status_hint=hook_status_hint,
        )

    def get_transcript(
        self,
        session_id: str,
        *,
        since_step: int = 0,
        limit: int = 200,
        full: bool = False,
    ) -> tuple[int, list[TranscriptStep]]:
        """Return (total_steps, filtered_steps) for a session transcript."""
        sdir = self._session_dir(session_id)
        parsed = self._load_parsed_transcript(session_id, sdir, full=full)
        all_steps = parsed.steps
        total = len(all_steps)
        filtered = [step for step in all_steps if step.step_index >= since_step]
        if limit > 0:
            filtered = filtered[:limit]
        return total, filtered

    def _scan_artifacts(self, session_dir: Path) -> list[ArtifactItem]:
        base_resolved = session_dir.resolve()
        items: list[ArtifactItem] = []

        def _walk(current: Path) -> None:
            try:
                entries = list(current.iterdir())
            except OSError:
                return
            for entry in entries:
                if entry.name.startswith("."):
                    continue
                if current == session_dir and entry.name in _EXCLUDED_ARTIFACT_DIRS:
                    continue
                try:
                    resolved = entry.resolve()
                    if not resolved.is_relative_to(base_resolved):
                        continue
                    if entry.is_dir():
                        _walk(entry)
                    elif entry.is_file():
                        st = resolved.stat()
                        rel_path = entry.relative_to(session_dir).as_posix()
                        mime = guess_mime_type(entry)
                        items.append(
                            ArtifactItem(
                                name=entry.name,
                                relative_path=rel_path,
                                mime_type=mime,
                                size_bytes=st.st_size,
                                updated_at=format_iso_utc(st.st_mtime),
                                is_image=mime.startswith("image/"),
                            )
                        )
                except OSError:
                    continue

        _walk(session_dir)
        items.sort(key=lambda a: (a.updated_at, a.relative_path), reverse=True)
        return items

    def list_artifacts(self, session_id: str) -> list[ArtifactItem]:
        sdir = self._session_dir(session_id)
        return self._scan_artifacts(sdir)

    def read_artifact(self, session_id: str, relative_path: str) -> tuple[str, str, str, bytes]:
        """Safely read an artifact file. Returns (name, normalized_rel_path, mime_type, raw_bytes)."""
        sdir = self._session_dir(session_id)
        resolved = safe_resolve_under(
            sdir,
            relative_path,
            forbid_top_dirs=_EXCLUDED_ARTIFACT_DIRS,
            forbid_hidden=True,
        )
        if not resolved.is_file():
            raise ResourceNotFoundError(f"Artifact '{relative_path}' not found.")
        try:
            data = resolved.read_bytes()
        except OSError as exc:
            raise ResourceNotFoundError(f"Unable to read artifact '{relative_path}': {exc}") from exc
        rel_posix = resolved.relative_to(sdir.resolve()).as_posix()
        return resolved.name, rel_posix, guess_mime_type(resolved), data

    def read_media(self, session_id: str, filename: str) -> tuple[str, bytes]:
        """Safely read a session media attachment. Returns (mime_type, raw_bytes)."""
        sdir = self._session_dir(session_id)
        if not filename or filename in (".", "..") or "/" in filename or "\\" in filename or ":" in filename or "\x00" in filename:
            raise PathTraversalError("Invalid media filename.")

        base_resolved = sdir.resolve()
        candidates: list[Path] = [
            sdir / filename,
            sdir / ".system_generated" / "media" / filename,
            sdir / "media" / filename,
        ]

        parsed = self._load_parsed_transcript(session_id, sdir, full=False)
        recorded_path = parsed.media_uris.get(filename)
        if recorded_path is not None:
            candidates.append(recorded_path)

        for candidate in candidates:
            try:
                resolved = candidate.resolve()
            except OSError:
                continue
            if not resolved.is_relative_to(base_resolved) or resolved == base_resolved:
                # If an explicit candidate inside session dir was a symlink escaping outside, block it.
                if candidate.is_symlink():
                    raise PathTraversalError("Symlink escapes session directory.")
                continue
            if resolved.is_file():
                try:
                    return guess_mime_type(resolved), resolved.read_bytes()
                except OSError as exc:
                    raise ResourceNotFoundError(f"Unable to read media '{filename}': {exc}") from exc

        raise ResourceNotFoundError(f"Media '{filename}' not found.")

    def _read_log_tail(self, path: Path) -> str:
        try:
            size = path.stat().st_size
            with path.open("rb") as fh:
                if size > _TASK_TAIL_READ_BYTES:
                    fh.seek(size - _TASK_TAIL_READ_BYTES)
                raw = fh.read()
        except OSError:
            return ""
        text = raw.decode("utf-8", errors="replace")
        lines = text.splitlines()
        if len(lines) > _TASK_TAIL_MAX_LINES:
            lines = lines[-_TASK_TAIL_MAX_LINES:]
        joined = "\n".join(lines)
        if len(joined) > _TASK_TAIL_MAX_CHARS:
            return joined[-_TASK_TAIL_MAX_CHARS:]
        return joined

    def get_session_tasks(
        self, session_id: str
    ) -> tuple[list[TaskLogItem], list[SubagentInvocation], list[SwarmEventItem]]:
        """Return (tasks, subagents, swarm_events) for a session."""
        sdir = self._session_dir(session_id)
        parsed = self._load_parsed_transcript(session_id, sdir, full=False)

        tasks_dir = sdir / ".system_generated" / "tasks"
        task_items: list[TaskLogItem] = []
        if tasks_dir.is_dir():
            base_resolved = sdir.resolve()
            try:
                entries = list(tasks_dir.iterdir())
            except OSError:
                entries = []
            for entry in entries:
                if entry.suffix.lower() != ".log":
                    continue
                try:
                    resolved = entry.resolve()
                    if not resolved.is_relative_to(base_resolved) or not resolved.is_file():
                        continue
                    st = resolved.stat()
                    task_items.append(
                        TaskLogItem(
                            task_id=entry.stem,
                            filename=entry.name,
                            size_bytes=st.st_size,
                            updated_at=format_iso_utc(st.st_mtime),
                            tail=self._read_log_tail(resolved),
                        )
                    )
                except OSError:
                    continue
            task_items.sort(key=lambda t: (t.updated_at, t.task_id), reverse=True)

        return task_items, list(parsed.subagents), list(parsed.swarm_events)
