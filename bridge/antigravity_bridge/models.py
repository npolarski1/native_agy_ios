"""Data models and frozen v1 JSON wire serializers."""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any

from . import API_VERSION


def utc_now() -> datetime:
    """Return the current UTC datetime."""
    return datetime.now(timezone.utc)


def format_iso_utc(value: datetime | float | int | None = None) -> str:
    """Format a datetime or UNIX timestamp as an ISO-8601 UTC string ending in 'Z'."""
    if value is None:
        dt = utc_now()
    elif isinstance(value, (int, float)):
        dt = datetime.fromtimestamp(value, tz=timezone.utc)
    else:
        dt = value if value.tzinfo is not None else value.replace(tzinfo=timezone.utc)
        dt = dt.astimezone(timezone.utc)
    return dt.replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso_utc(value: str | None) -> datetime | None:
    """Parse an ISO-8601 timestamp string into a timezone-aware UTC datetime."""
    if not value or not isinstance(value, str):
        return None
    raw = value.strip()
    if not raw:
        return None
    if raw.endswith("Z") or raw.endswith("z"):
        raw = raw[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(raw)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def normalize_iso_utc(value: str | None, fallback: datetime | float | None = None) -> str:
    """Normalize an ISO-8601 string into canonical UTC 'Z' format, using fallback if invalid."""
    parsed = parse_iso_utc(value)
    if parsed is not None:
        return format_iso_utc(parsed)
    return format_iso_utc(fallback)


@dataclass(slots=True)
class HostHealth:
    hostname: str
    platform: str
    uptime_seconds: int
    brain_dir: str
    brain_dir_exists: bool
    session_count: int
    active_session_count: int
    pending_approval_count: int
    total_input_tokens: int
    total_cache_read_tokens: int
    total_output_tokens: int
    server_time: str
    status: str = "ok"
    api_version: str = API_VERSION

    def to_dict(self) -> dict[str, Any]:
        return {
            "status": self.status,
            "api_version": self.api_version,
            "hostname": self.hostname,
            "platform": self.platform,
            "uptime_seconds": self.uptime_seconds,
            "brain_dir": self.brain_dir,
            "brain_dir_exists": self.brain_dir_exists,
            "session_count": self.session_count,
            "active_session_count": self.active_session_count,
            "pending_approval_count": self.pending_approval_count,
            "total_input_tokens": self.total_input_tokens,
            "total_cache_read_tokens": self.total_cache_read_tokens,
            "total_output_tokens": self.total_output_tokens,
            "server_time": self.server_time,
        }


@dataclass(slots=True)
class SessionSummary:
    id: str
    title: str
    status: str
    created_at: str
    updated_at: str
    step_count: int
    model: str | None
    input_tokens: int
    cache_read_tokens: int
    output_tokens: int
    artifact_count: int
    task_count: int
    subagent_count: int
    has_swarm: bool
    last_step_preview: str | None

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "title": self.title,
            "status": self.status,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
            "step_count": self.step_count,
            "model": self.model,
            "input_tokens": self.input_tokens,
            "cache_read_tokens": self.cache_read_tokens,
            "output_tokens": self.output_tokens,
            "artifact_count": self.artifact_count,
            "task_count": self.task_count,
            "subagent_count": self.subagent_count,
            "has_swarm": self.has_swarm,
            "last_step_preview": self.last_step_preview,
        }


@dataclass(slots=True)
class ToolCallItem:
    name: str
    args_json: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "args_json": self.args_json,
        }


@dataclass(slots=True)
class MediaAttachment:
    mime_type: str
    filename: str
    url_path: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "mime_type": self.mime_type,
            "filename": self.filename,
            "url_path": self.url_path,
        }


@dataclass(slots=True)
class TranscriptStep:
    step_index: int
    source: str
    type: str
    status: str
    created_at: str
    model: str | None = None
    input_tokens: int | None = None
    cache_read_tokens: int | None = None
    output_tokens: int | None = None
    content: str | None = None
    thinking: str | None = None
    tool_calls: list[ToolCallItem] = field(default_factory=list)
    media: list[MediaAttachment] = field(default_factory=list)
    truncated_fields: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "step_index": self.step_index,
            "source": self.source,
            "type": self.type,
            "status": self.status,
            "created_at": self.created_at,
            "model": self.model,
            "input_tokens": self.input_tokens,
            "cache_read_tokens": self.cache_read_tokens,
            "output_tokens": self.output_tokens,
            "content": self.content,
            "thinking": self.thinking,
            "tool_calls": [tc.to_dict() for tc in self.tool_calls],
            "media": [m.to_dict() for m in self.media],
            "truncated_fields": list(self.truncated_fields),
        }


@dataclass(slots=True)
class ArtifactItem:
    name: str
    relative_path: str
    mime_type: str
    size_bytes: int
    updated_at: str
    is_image: bool

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "relative_path": self.relative_path,
            "mime_type": self.mime_type,
            "size_bytes": self.size_bytes,
            "updated_at": self.updated_at,
            "is_image": self.is_image,
        }


@dataclass(slots=True)
class TaskLogItem:
    task_id: str
    filename: str
    size_bytes: int
    updated_at: str
    tail: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "task_id": self.task_id,
            "filename": self.filename,
            "size_bytes": self.size_bytes,
            "updated_at": self.updated_at,
            "tail": self.tail,
        }


@dataclass(slots=True)
class SubagentInvocation:
    step_index: int
    role: str
    type_name: str
    prompt_preview: str
    created_at: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "step_index": self.step_index,
            "role": self.role,
            "type_name": self.type_name,
            "prompt_preview": self.prompt_preview,
            "created_at": self.created_at,
        }


@dataclass(slots=True)
class SwarmEventItem:
    step_index: int
    action: str
    target: str | None
    summary: str
    created_at: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "step_index": self.step_index,
            "action": self.action,
            "target": self.target,
            "summary": self.summary,
            "created_at": self.created_at,
        }


@dataclass(slots=True)
class ApprovalRequest:
    id: str
    session_id: str | None
    hook_event: str
    tool_name: str
    args_json: str
    summary: str
    status: str
    created_at: str
    expires_at: str
    decision: str | None = None
    decision_reason: str | None = None
    decided_at: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "session_id": self.session_id,
            "hook_event": self.hook_event,
            "tool_name": self.tool_name,
            "args_json": self.args_json,
            "summary": self.summary,
            "status": self.status,
            "created_at": self.created_at,
            "expires_at": self.expires_at,
            "decision": self.decision,
            "decision_reason": self.decision_reason,
            "decided_at": self.decided_at,
        }


@dataclass(slots=True)
class BridgeEvent:
    type: str
    timestamp: str
    session_id: str | None = None
    session: SessionSummary | None = None
    step: TranscriptStep | None = None
    approval: ApprovalRequest | None = None
    hook_event_name: str | None = None
    message: str | None = None
    health: HostHealth | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "type": self.type,
            "timestamp": self.timestamp,
            "session_id": self.session_id,
            "session": self.session.to_dict() if self.session is not None else None,
            "step": self.step.to_dict() if self.step is not None else None,
            "approval": self.approval.to_dict() if self.approval is not None else None,
            "hook_event_name": self.hook_event_name,
            "message": self.message,
            "health": self.health.to_dict() if self.health is not None else None,
        }
