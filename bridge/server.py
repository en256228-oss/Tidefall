import json
import os
from typing import Annotated

import httpx
from mcp.server.fastmcp import FastMCP
from pydantic import Field

SUPABASE_URL = os.environ["SUPABASE_URL"].rstrip("/")
SUPABASE_SERVICE_ROLE_KEY = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
ASSISTANT_ID = os.environ["TIDEFALL_ASSISTANT_ID"]
HOST = os.getenv("TIDEFALL_MCP_HOST", "127.0.0.1")
PORT = int(os.getenv("TIDEFALL_MCP_PORT", "8765"))

mcp = FastMCP(
    "tidefall",
    host=HOST,
    port=PORT,
    stateless_http=True,
    instructions=(
        "Tidefall is persistent body/emotion state. Call get_state before a response when "
        "body state is relevant. Record the counterpart's message once per relevant user turn. "
        "Use settle_interaction only after a meaningful interaction outcome. Never invent state."
    ),
)


async def rpc(name: str, payload: dict) -> dict:
    headers = {
        "apikey": SUPABASE_SERVICE_ROLE_KEY,
        "authorization": f"Bearer {SUPABASE_SERVICE_ROLE_KEY}",
        "content-type": "application/json",
    }
    async with httpx.AsyncClient(timeout=15.0) as client:
        response = await client.post(
            f"{SUPABASE_URL}/rest/v1/rpc/{name}", headers=headers, json=payload
        )
    if response.is_error:
        raise RuntimeError(f"Supabase RPC {name} failed ({response.status_code}): {response.text[:500]}")
    return response.json()


@mcp.tool()
async def get_state() -> dict:
    """Read the current Tidefall state after advancing elapsed-time effects."""
    return await rpc("eventide_bridge_state", {"p_assistant_id": ASSISTANT_ID})


@mcp.tool()
async def record_counterpart_message(
    text: Annotated[str, Field(min_length=1, max_length=8000)]
) -> dict:
    """Record the counterpart's latest message time and apply configured trigger-word effects."""
    return await rpc(
        "eventide_bridge_message",
        {"p_assistant_id": ASSISTANT_ID, "p_content": text},
    )


@mcp.tool()
async def trigger_event(
    event_key: Annotated[str, Field(min_length=1, max_length=80)],
    reason: Annotated[str, Field(max_length=200)] = "mcp",
) -> dict:
    """Start one configured Tidefall event by its exact event key."""
    return await rpc(
        "eventide_bridge_trigger_event",
        {
            "p_assistant_id": ASSISTANT_ID,
            "p_event_key": event_key,
            "p_reason": reason,
        },
    )


@mcp.tool()
async def settle_interaction(
    deltas_json: Annotated[
        str,
        Field(
            description=(
                "JSON object of signed deltas for heat, pressure, control, sensitivity, "
                "reserve, possessiveness, fatigue. Each delta must be between -25 and 25."
            )
        ),
    ],
    note: Annotated[str, Field(max_length=500)] = "",
) -> dict:
    """Apply a bounded settlement after a meaningful interaction and snapshot the result."""
    try:
        deltas = json.loads(deltas_json)
    except json.JSONDecodeError as exc:
        raise ValueError("deltas_json must be valid JSON") from exc
    if not isinstance(deltas, dict):
        raise ValueError("deltas_json must decode to an object")
    allowed = {"heat","pressure","control","sensitivity","reserve","possessiveness","fatigue"}
    if not set(deltas).issubset(allowed):
        raise ValueError("deltas_json contains unsupported fields")
    for key, value in deltas.items():
        if isinstance(value, bool) or not isinstance(value, (int, float)) or value < -25 or value > 25:
            raise ValueError(f"{key} delta must be a number between -25 and 25")
    return await rpc(
        "eventide_bridge_settle",
        {"p_assistant_id": ASSISTANT_ID, "p_deltas": deltas, "p_note": note},
    )


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
