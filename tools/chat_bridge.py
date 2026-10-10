#!/usr/bin/env python3
"""Local bridge between the LeapFrog app's travel assistant and Claude Code.

For demos: the app POSTs the conversation plus a live-conditions snapshot,
and this server answers by running the Claude Code CLI on this Mac
(`claude -p`) with a light model. It uses your existing Claude Code login,
so no API key is needed in the app.

    python3 tools/chat_bridge.py                 # listens on 127.0.0.1:8787 (simulator)
    python3 tools/chat_bridge.py --host 0.0.0.0  # also reachable from a phone on your Wi-Fi

The assistant's instructions live in tools/chat_assistant_prompt.md.

API: POST /chat
  {"messages": [{"role": "user" | "assistant", "content": "..."}], "context": "<live snapshot>"}
  -> 200 {"reply": "..."}   or   502 {"error": "..."}
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROMPT_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "chat_assistant_prompt.md")
MAX_MESSAGES = 30          # keep the most recent turns
MAX_FIELD_CHARS = 4000     # per message / snapshot
TIMEOUT_SECONDS = 90


def build_prompt(messages, context):
    """Turns the conversation into a single prompt for a stateless `claude -p` call."""
    lines = [f"Live snapshot:\n{context.strip() or '(no live data available)'}", "", "Conversation so far:"]
    for message in messages[-MAX_MESSAGES:]:
        speaker = "Rider" if message.get("role") == "user" else "Assistant"
        lines.append(f"{speaker}: {str(message.get('content', ''))[:MAX_FIELD_CHARS]}")
    lines += ["", "Write the assistant's next reply to the rider. Reply with the message text only."]
    return "\n".join(lines)


def ask_claude(system_prompt, prompt, model, workdir):
    command = [
        "claude", "-p", prompt,
        "--model", model,
        "--system-prompt", system_prompt,
        "--tools", "",                # a chatbot: no file, shell or web tools
        "--strict-mcp-config",        # don't load MCP servers
        "--disable-slash-commands",
        "--no-session-persistence",
        "--output-format", "json",
    ]
    # Run in an empty directory so no project files or CLAUDE.md leak into the chat.
    result = subprocess.run(command, cwd=workdir, capture_output=True, text=True, timeout=TIMEOUT_SECONDS)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"claude exited with {result.returncode}")
    payload = json.loads(result.stdout)
    if payload.get("is_error"):
        raise RuntimeError(str(payload.get("result") or "Claude returned an error"))
    return payload.get("result", "").strip()


class Handler(BaseHTTPRequestHandler):
    model = "haiku"
    workdir = None

    def do_GET(self):
        if self.path == "/health":
            self._send(200, {"ok": True, "model": self.model})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/chat":
            self._send(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(min(length, 200_000)) or b"{}")
            messages = body.get("messages") or []
            context = str(body.get("context") or "")[:MAX_FIELD_CHARS]
            if not messages:
                raise ValueError("no messages")
            with open(PROMPT_FILE, encoding="utf-8") as f:
                system_prompt = f.read()
            started = time.time()
            reply = ask_claude(system_prompt, build_prompt(messages, context), self.model, self.workdir)
            print(f"[chat] {len(messages)} msg(s) → {len(reply)} chars in {time.time() - started:.1f}s", file=sys.stderr)
            self._send(200, {"reply": reply})
        except subprocess.TimeoutExpired:
            self._send(502, {"error": "The assistant took too long to answer."})
        except Exception as error:  # noqa: BLE001 — report any failure to the app
            print(f"[chat] error: {error}", file=sys.stderr)
            self._send(502, {"error": str(error)[:300]})

    def _send(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass  # quiet; requests are logged in do_POST


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--model", default="haiku", help="Claude Code model alias (default: haiku)")
    args = parser.parse_args()

    Handler.model = args.model
    Handler.workdir = tempfile.mkdtemp(prefix="leapfrog-chat-")
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"LeapFrog chat bridge on http://{args.host}:{args.port} using Claude Code ({args.model})", file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
