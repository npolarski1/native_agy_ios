"""Async remote tool approval queue and timeout coordinator."""

from __future__ import annotations

import asyncio
import json
import secrets
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import timedelta
from typing import Any

from .models import ApprovalRequest, format_iso_utc, utc_now


class ApprovalError(Exception):
    """Base approval error."""


class ApprovalNotFoundError(ApprovalError):
    """Raised when an approval ID does not exist."""


class ApprovalAlreadyResolvedError(ApprovalError):
    """Raised when attempting to decide an approval that is no longer pending."""


class InvalidApprovalDecisionError(ApprovalError):
    """Raised when an invalid approval decision value is supplied."""


ApprovalCallback = Callable[[ApprovalRequest], Awaitable[None]]


def summarize_tool_call(tool_name: str, args: dict[str, Any]) -> str:
    """Create a concise human-readable summary for an approval card."""
    for key in ("CommandLine", "command", "cmd"):
        val = args.get(key)
        if isinstance(val, str) and val.strip():
            preview = val.strip().replace("\n", " ")
            if len(preview) > 120:
                preview = preview[:119] + "…"
            return f"Run command: {preview}"

    for key in ("Path", "path", "TargetFile", "file_path"):
        val = args.get(key)
        if isinstance(val, str) and val.strip():
            return f"{tool_name}: {val.strip()}"

    if args:
        first_key = next(iter(args))
        first_val = str(args[first_key]).replace("\n", " ")
        if len(first_val) > 80:
            first_val = first_val[:79] + "…"
        return f"{tool_name} ({first_key}={first_val})"

    return f"Tool invocation: {tool_name}"


@dataclass(slots=True)
class _PendingEntry:
    request: ApprovalRequest
    future: asyncio.Future[ApprovalRequest]
    default_decision: str


class ApprovalManager:
    """Manages pending and historical remote PreToolUse approval requests."""

    def __init__(
        self,
        *,
        on_requested: ApprovalCallback | None = None,
        on_resolved: ApprovalCallback | None = None,
        max_history: int = 200,
    ) -> None:
        self._on_requested = on_requested
        self._on_resolved = on_resolved
        self._max_history = max_history
        self._entries: dict[str, _PendingEntry] = {}
        self._order: list[str] = []
        self._lock = asyncio.Lock()

    def set_callbacks(
        self,
        *,
        on_requested: ApprovalCallback | None = None,
        on_resolved: ApprovalCallback | None = None,
    ) -> None:
        self._on_requested = on_requested
        self._on_resolved = on_resolved

    def _prune_history(self) -> None:
        if len(self._order) <= self._max_history:
            return
        pruned: list[str] = []
        removed = 0
        to_remove = len(self._order) - self._max_history
        for aid in self._order:
            entry = self._entries.get(aid)
            if removed < to_remove and entry is not None and entry.request.status != "pending":
                self._entries.pop(aid, None)
                removed += 1
            else:
                pruned.append(aid)
        self._order = pruned

    def list_approvals(self) -> list[ApprovalRequest]:
        """Return approvals with pending items first, then newest resolved items."""
        pending: list[ApprovalRequest] = []
        resolved: list[ApprovalRequest] = []
        for aid in reversed(self._order):
            entry = self._entries.get(aid)
            if entry is None:
                continue
            if entry.request.status == "pending":
                pending.append(entry.request)
            else:
                resolved.append(entry.request)
        return pending + resolved

    def get(self, approval_id: str) -> ApprovalRequest | None:
        entry = self._entries.get(approval_id)
        return entry.request if entry is not None else None

    def pending_count(self) -> int:
        return sum(1 for e in self._entries.values() if e.request.status == "pending")

    def pending_session_ids(self) -> set[str]:
        return {
            e.request.session_id
            for e in self._entries.values()
            if e.request.status == "pending" and e.request.session_id
        }

    async def request_approval(
        self,
        *,
        tool_name: str,
        args: dict[str, Any] | None = None,
        session_id: str | None = None,
        hook_event: str = "PreToolUse",
        summary: str | None = None,
        timeout_seconds: float = 55.0,
        default_decision: str = "deny",
    ) -> ApprovalRequest:
        """Create a pending approval request and await decision or timeout."""
        if default_decision not in ("allow", "deny"):
            raise InvalidApprovalDecisionError("default_decision must be 'allow' or 'deny'.")

        safe_timeout = max(0.05, float(timeout_seconds))
        norm_args = args if isinstance(args, dict) else {}
        args_json = json.dumps(norm_args, ensure_ascii=False, sort_keys=True)
        resolved_summary = summary.strip() if isinstance(summary, str) and summary.strip() else summarize_tool_call(tool_name, norm_args)

        now = utc_now()
        expires = now + timedelta(seconds=safe_timeout)
        approval_id = f"apr_{secrets.token_hex(8)}"

        req = ApprovalRequest(
            id=approval_id,
            session_id=session_id,
            hook_event=hook_event or "PreToolUse",
            tool_name=tool_name,
            args_json=args_json,
            summary=resolved_summary,
            status="pending",
            created_at=format_iso_utc(now),
            expires_at=format_iso_utc(expires),
        )

        loop = asyncio.get_running_loop()
        fut: asyncio.Future[ApprovalRequest] = loop.create_future()

        async with self._lock:
            self._entries[approval_id] = _PendingEntry(
                request=req,
                future=fut,
                default_decision=default_decision,
            )
            self._order.append(approval_id)
            self._prune_history()

        if self._on_requested is not None:
            await self._on_requested(req)

        try:
            return await asyncio.wait_for(asyncio.shield(fut), timeout=safe_timeout)
        except asyncio.TimeoutError:
            resolved_now = False
            async with self._lock:
                entry = self._entries.get(approval_id)
                if entry is not None and entry.request.status == "pending":
                    entry.request.status = "expired"
                    entry.request.decision = entry.default_decision
                    entry.request.decision_reason = (
                        f"Approval timed out after {int(round(safe_timeout))}s; "
                        f"applied default decision ({entry.default_decision})."
                    )
                    entry.request.decided_at = format_iso_utc(utc_now())
                    if not entry.future.done():
                        entry.future.set_result(entry.request)
                    resolved_now = True
                result = entry.request if entry is not None else req

            if resolved_now and self._on_resolved is not None:
                await self._on_resolved(result)
            return result

    async def decide(
        self,
        approval_id: str,
        *,
        decision: str,
        reason: str | None = None,
    ) -> ApprovalRequest:
        """Resolve a pending approval request with 'allow' or 'deny'."""
        if decision not in ("allow", "deny"):
            raise InvalidApprovalDecisionError("decision must be 'allow' or 'deny'.")

        async with self._lock:
            entry = self._entries.get(approval_id)
            if entry is None:
                raise ApprovalNotFoundError(f"Approval '{approval_id}' not found.")
            if entry.request.status != "pending":
                raise ApprovalAlreadyResolvedError(
                    f"Approval '{approval_id}' is already {entry.request.status}."
                )

            entry.request.status = "approved" if decision == "allow" else "denied"
            entry.request.decision = decision
            entry.request.decision_reason = reason.strip() if isinstance(reason, str) and reason.strip() else None
            entry.request.decided_at = format_iso_utc(utc_now())
            if not entry.future.done():
                entry.future.set_result(entry.request)
            result = entry.request

        if self._on_resolved is not None:
            await self._on_resolved(result)
        return result

    async def cancel_all(self) -> None:
        """Resolve all remaining pending approvals cleanly during server shutdown."""
        resolved_items: list[ApprovalRequest] = []
        async with self._lock:
            now_str = format_iso_utc(utc_now())
            for entry in self._entries.values():
                if entry.request.status == "pending":
                    entry.request.status = "expired"
                    entry.request.decision = entry.default_decision
                    entry.request.decision_reason = "Bridge server shutting down."
                    entry.request.decided_at = now_str
                    if not entry.future.done():
                        entry.future.set_result(entry.request)
                    resolved_items.append(entry.request)
        if self._on_resolved is not None:
            for item in resolved_items:
                try:
                    await self._on_resolved(item)
                except Exception:
                    pass
