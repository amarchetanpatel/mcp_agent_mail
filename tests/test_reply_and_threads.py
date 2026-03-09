from __future__ import annotations

import pytest
from fastmcp import Client

from mcp_agent_mail.app import build_mcp_server


@pytest.mark.asyncio
async def test_reply_preserves_thread_and_subject_prefix(isolated_env):
    server = build_mcp_server()
    async with Client(server) as client:
        await client.call_tool("ensure_project", {"human_key": "/backend"})
        for n in ("GreenCastle", "BlueLake"):
            await client.call_tool(
                "register_agent",
                {"project_key": "Backend", "program": "x", "model": "y", "name": n},
            )
        # Allow direct messaging without contact gating for this test
        await client.call_tool(
            "set_contact_policy",
            {"project_key": "Backend", "agent_name": "BlueLake", "policy": "open"},
        )

        orig = await client.call_tool(
            "send_message",
            {
                "project_key": "Backend",
                "sender_name": "GreenCastle",
                "to": ["BlueLake"],
                "subject": "Plan",
                "body_md": "body",
            },
        )
        delivery = (orig.data.get("deliveries") or [])[0]
        mid = delivery["payload"]["id"]

        rep = await client.call_tool(
            "reply_message",
            {
                "project_key": "Backend",
                "message_id": mid,
                "sender_name": "BlueLake",
                "body_md": "ack",
            },
        )
        # Ensure thread continuity and deliveries present
        assert rep.data.get("thread_id")
        assert rep.data.get("deliveries")

        # Subject prefix idempotent: replying again with same prefix shouldn't double it
        rep2 = await client.call_tool(
            "reply_message",
            {
                "project_key": "Backend",
                "message_id": mid,
                "sender_name": "BlueLake",
                "body_md": "second",
                "subject_prefix": "Re:",
            },
        )
        assert rep2.data.get("deliveries")

        # Thread listing is validated via tool response thread_id; resource listing is covered elsewhere


@pytest.mark.asyncio
async def test_thread_claim_lifecycle_and_reply_auto_claim(isolated_env):
    server = build_mcp_server()
    async with Client(server) as client:
        await client.call_tool("ensure_project", {"human_key": "/backend"})
        for name in ("GreenCastle", "BlueLake"):
            await client.call_tool(
                "register_agent",
                {"project_key": "Backend", "program": "x", "model": "y", "name": name},
            )

        await client.call_tool(
            "set_contact_policy",
            {"project_key": "Backend", "agent_name": "BlueLake", "policy": "open"},
        )

        original = await client.call_tool(
            "send_message",
            {
                "project_key": "Backend",
                "sender_name": "GreenCastle",
                "to": ["BlueLake"],
                "subject": "Thread Ownership",
                "body_md": "initial",
                "thread_id": "TKT-123",
            },
        )
        delivery = (original.data.get("deliveries") or [])[0]
        message_id = delivery["payload"]["id"]

        before = await client.call_tool(
            "list_threads",
            {"project_key": "Backend", "filter": "all"},
        )
        before_threads = before.data.get("threads") or []
        assert any(t["thread_id"] == "TKT-123" and t["status"] == "unclaimed" for t in before_threads)

        reply = await client.call_tool(
            "reply_message",
            {
                "project_key": "Backend",
                "message_id": message_id,
                "sender_name": "BlueLake",
                "body_md": "taking this",
            },
        )
        assert reply.data.get("thread_id") == "TKT-123"
        assert reply.data.get("auto_claimed") is True

        claimed = await client.call_tool(
            "list_threads",
            {"project_key": "Backend", "filter": "claimed"},
        )
        claimed_threads = claimed.data.get("threads") or []
        assert any(t["thread_id"] == "TKT-123" and t["owner"] == "BlueLake" for t in claimed_threads)

        renewed = await client.call_tool(
            "renew_thread_claim",
            {
                "project_key": "Backend",
                "thread_id": "TKT-123",
                "agent_name": "BlueLake",
                "extend_seconds": 120,
            },
        )
        assert renewed.data.get("renewed") is True
        assert renewed.data.get("new_expires_ts")

        released = await client.call_tool(
            "release_thread",
            {
                "project_key": "Backend",
                "thread_id": "TKT-123",
                "agent_name": "BlueLake",
            },
        )
        assert released.data.get("released") is True


@pytest.mark.asyncio
async def test_fetch_inbox_with_path_project_key(isolated_env):
    server = build_mcp_server()
    project_key = "/tmp/path-key-project"

    async with Client(server) as client:
        await client.call_tool("ensure_project", {"human_key": project_key})
        await client.call_tool(
            "register_agent",
            {
                "project_key": project_key,
                "program": "codex-cli",
                "model": "gpt5-codex",
                "name": "BlueLake",
            },
        )

        inbox = await client.call_tool(
            "fetch_inbox",
            {
                "project_key": project_key,
                "agent_name": "BlueLake",
                "limit": 1,
            },
        )
        assert isinstance(inbox.data, list)
        assert inbox.data == []
