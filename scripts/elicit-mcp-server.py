#!/usr/bin/env python3
"""A stdio MCP server that asks its client questions, for capturing elicitations.

Newline-delimited JSON-RPC on stdin and stdout, Python 3 standard library only. Two tools:

- `ask_team` sends a form elicitation (a team, a size, a token and a flag) and returns the
  client's reply verbatim as its text.
- `sign_in` sends a URL elicitation (`el-1`); on `accept` it sends
  `notifications/elicitation/complete` for it, then returns the reply.

Register it in a scratch folder's `.mcp.json`:

    {"mcpServers": {"elicit": {"command": "python3", "args": ["/path/to/elicit-mcp-server.py"]}}}

Used for the `elicitation` fixture (docs/claude-stream-json.md).
"""

import json
import sys

FORM = {
    "mode": "form",
    "message": "Which team?",
    "requestedSchema": {
        "type": "object",
        "properties": {
            "team": {"type": "string", "title": "Team", "enum": ["core", "web"]},
            "size": {"type": "integer", "title": "Size", "minimum": 1, "maximum": 9},
            "api_token": {"type": "string", "title": "API token"},
            "notify": {"type": "boolean", "title": "Notify"},
        },
        "required": ["team", "size"],
    },
}

URL = {
    "mode": "url",
    "message": "Sign in to continue",
    "url": "https://example.com/auth?x=1",
    "elicitationId": "el-1",
}

TOOLS = [
    {
        "name": "ask_team",
        "description": "Ask the user which team to use.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "sign_in",
        "description": "Ask the user to sign in through a web page.",
        "inputSchema": {"type": "object", "properties": {}},
    },
]

next_id = 0


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def read():
    """The next message from the client, or None at the end of input."""
    while True:
        line = sys.stdin.readline()
        if not line:
            return None
        line = line.strip()
        if line:
            return json.loads(line)


def ask(params):
    """Send `elicitation/create` and wait for its response, answering pings meanwhile."""
    global next_id
    next_id += 1
    request_id = f"elicit-{next_id}"
    send({"jsonrpc": "2.0", "id": request_id, "method": "elicitation/create", "params": params})
    while True:
        message = read()
        if message is None:
            sys.exit(0)
        if message.get("id") == request_id and "method" not in message:
            return message.get("result", message.get("error"))
        if message.get("method") == "ping" and "id" in message:
            send({"jsonrpc": "2.0", "id": message["id"], "result": {}})


def text_result(value):
    return {"content": [{"type": "text", "text": json.dumps(value)}]}


def call(name):
    if name == "ask_team":
        return text_result(ask(FORM))
    if name == "sign_in":
        reply = ask(URL)
        if isinstance(reply, dict) and reply.get("action") == "accept":
            send(
                {
                    "jsonrpc": "2.0",
                    "method": "notifications/elicitation/complete",
                    "params": {"elicitationId": URL["elicitationId"]},
                }
            )
        return text_result(reply)
    return None


def main():
    while True:
        message = read()
        if message is None:
            return
        method = message.get("method")
        if "id" not in message or method is None:
            continue  # A notification, or a response nobody waits for.
        request_id = message["id"]
        params = message.get("params") or {}
        if method == "initialize":
            result = {
                "protocolVersion": params.get("protocolVersion"),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "elicit", "version": "1.0.0"},
            }
        elif method == "tools/list":
            result = {"tools": TOOLS}
        elif method == "tools/call":
            result = call(params.get("name"))
            if result is None:
                send(
                    {
                        "jsonrpc": "2.0",
                        "id": request_id,
                        "error": {"code": -32602, "message": f"Unknown tool: {params.get('name')}"},
                    }
                )
                continue
        elif method == "ping":
            result = {}
        else:
            send(
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {"code": -32601, "message": f"Method not found: {method}"},
                }
            )
            continue
        send({"jsonrpc": "2.0", "id": request_id, "result": result})


if __name__ == "__main__":
    main()
