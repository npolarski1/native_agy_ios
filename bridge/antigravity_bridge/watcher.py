"""Async polling filesystem watcher for Antigravity 2.0 brain directories."""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Awaitable, Callable
from dataclasses import dataclass

from .models import BridgeEvent, HostHealth, format_iso_utc, utc_now
from .transcript_store import BridgeStoreError, TranscriptStore


LOGGER = logging.getLogger("antigravity_bridge.watcher")

BroadcastFn = Callable[[BridgeEvent], Awaitable[None]]
HealthProviderFn = Callable[[], HostHealth]
PendingSessionIdsFn = Callable[[], set[str]]
HookHintsFn = Callable[[], dict[str, str]]


@dataclass(slots=True)
class _SessionSnapshot:
    step_count: int
    last_step_index: int
    updated_at: str
    status: str
    artifact_count: int
    task_count: int
    subagent_count: int
    has_swarm: bool


class BrainWatcher:
    """Polls the Antigravity brain directory and emits live WebSocket events."""

    def __init__(
        self,
        store: TranscriptStore,
        broadcast: BroadcastFn,
        health_provider: HealthProviderFn,
        *,
        pending_session_ids_provider: PendingSessionIdsFn | None = None,
        hook_hints_provider: HookHintsFn | None = None,
        poll_interval: float = 1.0,
        health_tick_interval: float = 15.0,
    ) -> None:
        self._store = store
        self._broadcast = broadcast
        self._health_provider = health_provider
        self._pending_session_ids_provider = pending_session_ids_provider or (lambda: set())
        self._hook_hints_provider = hook_hints_provider or (lambda: {})
        self._poll_interval = max(0.05, float(poll_interval))
        self._health_tick_interval = max(0.5, float(health_tick_interval))

        self._snapshots: dict[str, _SessionSnapshot] = {}
        self._initialized = False
        self._poll_task: asyncio.Task[None] | None = None
        self._health_task: asyncio.Task[None] | None = None
        self._stop_event = asyncio.Event()

    async def start(self) -> None:
        """Start background polling and health tick loops."""
        if self._poll_task is not None:
            return
        self._stop_event.clear()
        # Capture initial baseline without flooding clients with historical steps.
        await self.scan_once(emit=False)
        self._initialized = True
        self._poll_task = asyncio.create_task(self._poll_loop(), name="brain-watcher-poll")
        self._health_task = asyncio.create_task(self._health_loop(), name="brain-watcher-health")

    async def stop(self) -> None:
        """Stop all watcher background tasks cleanly."""
        self._stop_event.set()
        tasks = [t for t in (self._poll_task, self._health_task) if t is not None]
        self._poll_task = None
        self._health_task = None
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)

    async def _poll_loop(self) -> None:
        while not self._stop_event.is_set():
            try:
                await asyncio.sleep(self._poll_interval)
                if self._stop_event.is_set():
                    break
                await self.scan_once(emit=True)
            except asyncio.CancelledError:
                break
            except Exception:
                LOGGER.exception("Error while polling Antigravity brain directory.")

    async def _health_loop(self) -> None:
        while not self._stop_event.is_set():
            try:
                await asyncio.sleep(self._health_tick_interval)
                if self._stop_event.is_set():
                    break
                health = await asyncio.to_thread(self._health_provider)
                event = BridgeEvent(
                    type="health_tick",
                    timestamp=format_iso_utc(utc_now()),
                    health=health,
                )
                await self._broadcast(event)
            except asyncio.CancelledError:
                break
            except Exception:
                LOGGER.exception("Error while broadcasting health_tick.")

    async def scan_once(self, *, emit: bool = True) -> None:
        """Scan sessions once and emit step_added / session_updated events for changes."""
        pending_ids = self._pending_session_ids_provider()
        hints = self._hook_hints_provider()
        sessions = await asyncio.to_thread(
            self._store.list_sessions,
            limit=0,
            pending_session_ids=pending_ids,
            hook_status_hints=hints,
        )

        seen_ids: set[str] = set()
        for session in sessions:
            seen_ids.add(session.id)
            prev = self._snapshots.get(session.id)

            new_steps = []
            last_step_index = prev.last_step_index if prev is not None else -1

            if prev is None or session.step_count > prev.step_count or session.updated_at != prev.updated_at:
                since = (prev.last_step_index + 1) if prev is not None else 0
                try:
                    _, fetched = await asyncio.to_thread(
                        self._store.get_transcript,
                        session.id,
                        since_step=since,
                        limit=500,
                        full=False,
                    )
                except BridgeStoreError:
                    fetched = []
                if fetched:
                    last_step_index = max(last_step_index, fetched[-1].step_index)
                    if emit:
                        new_steps = fetched

            current = _SessionSnapshot(
                step_count=session.step_count,
                last_step_index=last_step_index,
                updated_at=session.updated_at,
                status=session.status,
                artifact_count=session.artifact_count,
                task_count=session.task_count,
                subagent_count=session.subagent_count,
                has_swarm=session.has_swarm,
            )
            self._snapshots[session.id] = current

            if not emit:
                continue

            changed = prev is None or prev != current
            now_str = format_iso_utc(utc_now())

            # Cap burst on a brand-new large session to recent 25 steps to keep WS responsive.
            if prev is None and len(new_steps) > 25:
                new_steps = new_steps[-25:]

            for step in new_steps:
                await self._broadcast(
                    BridgeEvent(
                        type="step_added",
                        timestamp=now_str,
                        session_id=session.id,
                        step=step,
                    )
                )

            if changed:
                await self._broadcast(
                    BridgeEvent(
                        type="session_updated",
                        timestamp=now_str,
                        session_id=session.id,
                        session=session,
                    )
                )

        # Clean up snapshots for removed session directories.
        for removed_id in list(self._snapshots.keys()):
            if removed_id not in seen_ids:
                self._snapshots.pop(removed_id, None)
