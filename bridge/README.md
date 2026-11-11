# Tidefall MCP bridge

Private MCP adapter between ChatGPT/Sol and Tidefall's Supabase state engine.

## Design

Tidefall remains the state engine. The bridge does not reimplement cycle progression,
event rolling, or time-based changes. It exposes four focused MCP tools:

- `get_state` — advances elapsed-time effects and reads current state.
- `record_counterpart_message` — records the latest counterpart message and applies configured trigger words.
- `trigger_event` — starts an existing configured Tidefall event.
- `settle_interaction` — applies bounded post-interaction deltas and snapshots the result.

The assistant id is fixed server-side with `TIDEFALL_ASSISTANT_ID`; the model cannot select another identity.

## Supabase

Run the existing Tidefall SQL first, then run:

`sql/06_mcp_bridge.sql`

The bridge RPCs are revoked from `anon` and `authenticated` and granted only to
`service_role`. Never put the service-role key in the browser UI or commit it to Git.

## Run locally/private

```bash
cd bridge
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
# load the variables from .env using your preferred service manager
python server.py
```

The default endpoint is bound to `127.0.0.1:8765` and uses MCP Streamable HTTP.
Connect it to ChatGPT through Secure MCP Tunnel rather than exposing this endpoint publicly.

## Security notes

- Keep `SUPABASE_SERVICE_ROLE_KEY` server-side only.
- Keep the MCP listener on loopback when using Secure MCP Tunnel.
- `settle_interaction` allowlists seven Tidefall fields and limits each delta to [-25, 25].
- The bridge SQL is intentionally separate from the upstream 01–05 scripts for easier upstream syncing.
