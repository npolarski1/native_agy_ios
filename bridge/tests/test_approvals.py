"""Async unit tests for ApprovalManager remote approval lifecycle and timeouts."""

from __future__ import annotations

import asyncio
import sys
import unittest
from pathlib import Path

_BRIDGE_ROOT = str(Path(__file__).resolve().parent.parent)
if _BRIDGE_ROOT not in sys.path:
    sys.path.insert(0, _BRIDGE_ROOT)

from antigravity_bridge.approvals import (
    ApprovalAlreadyResolvedError,
    ApprovalManager,
    ApprovalNotFoundError,
    InvalidApprovalDecisionError,
)
from antigravity_bridge.models import ApprovalRequest


class ApprovalManagerTests(unittest.IsolatedAsyncioTestCase):
    async def test_request_and_remote_allow(self) -> None:
        requested: list[ApprovalRequest] = []
        resolved: list[ApprovalRequest] = []

        async def on_req(item: ApprovalRequest) -> None:
            requested.append(item)

        async def on_res(item: ApprovalRequest) -> None:
            resolved.append(item)

        mgr = ApprovalManager(on_requested=on_req, on_resolved=on_res)

        task = asyncio.create_task(
            mgr.request_approval(
                tool_name="run_command",
                args={"CommandLine": "npm test"},
                session_id="sess-1",
                timeout_seconds=5.0,
            )
        )
        await asyncio.sleep(0.05)

        self.assertEqual(len(requested), 1)
        self.assertEqual(mgr.pending_count(), 1)
        self.assertEqual(mgr.pending_session_ids(), {"sess-1"})
        aid = requested[0].id
        self.assertIn("npm test", requested[0].summary)

        updated = await mgr.decide(aid, decision="allow", reason="Looks safe")
        self.assertEqual(updated.status, "approved")
        self.assertEqual(updated.decision, "allow")
        self.assertEqual(updated.decision_reason, "Looks safe")
        self.assertIsNotNone(updated.decided_at)

        final = await task
        self.assertEqual(final.id, aid)
        self.assertEqual(final.status, "approved")
        self.assertEqual(mgr.pending_count(), 0)
        self.assertEqual(len(resolved), 1)

        # Deciding again must raise conflict
        with self.assertRaises(ApprovalAlreadyResolvedError):
            await mgr.decide(aid, decision="deny")

    async def test_request_and_remote_deny(self) -> None:
        mgr = ApprovalManager()
        task = asyncio.create_task(
            mgr.request_approval(
                tool_name="run_command",
                args={"CommandLine": "rm -rf /tmp/test"},
                session_id="sess-2",
                timeout_seconds=5.0,
            )
        )
        await asyncio.sleep(0.05)
        aid = mgr.list_approvals()[0].id
        await mgr.decide(aid, decision="deny", reason="Too destructive")
        result = await task
        self.assertEqual(result.status, "denied")
        self.assertEqual(result.decision, "deny")
        self.assertEqual(result.decision_reason, "Too destructive")

    async def test_timeout_expiration_applies_default_decision(self) -> None:
        resolved: list[ApprovalRequest] = []

        async def on_res(item: ApprovalRequest) -> None:
            resolved.append(item)

        mgr = ApprovalManager(on_resolved=on_res)
        result = await mgr.request_approval(
            tool_name="edit_file",
            args={"Path": "main.py"},
            timeout_seconds=0.1,
            default_decision="deny",
        )
        self.assertEqual(result.status, "expired")
        self.assertEqual(result.decision, "deny")
        self.assertIn("timed out", (result.decision_reason or "").lower())
        self.assertEqual(len(resolved), 1)

        # Deciding after expiration fails with conflict
        with self.assertRaises(ApprovalAlreadyResolvedError):
            await mgr.decide(result.id, decision="allow")

    async def test_unknown_and_invalid_decisions(self) -> None:
        mgr = ApprovalManager()
        with self.assertRaises(ApprovalNotFoundError):
            await mgr.decide("apr_nonexistent", decision="allow")
        with self.assertRaises(InvalidApprovalDecisionError):
            await mgr.decide("apr_nonexistent", decision="maybe")


if __name__ == "__main__":
    unittest.main()
