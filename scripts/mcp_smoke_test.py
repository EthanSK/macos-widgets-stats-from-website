#!/usr/bin/env python3
"""Smoke-test the local MCP server without touching real user config.

Build the CLI first, then run this script. It uses a temporary
MACOS_WIDGETS_STATS_TEST_CONTAINER so trackers/readings are disposable.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_CLI = REPO_ROOT / "build/mcp-verify-derived/Build/Products/Debug/macos-widgets-stats-from-website"


class SmokeServer(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        body = b"""
        <!doctype html>
        <html><body>
          <main>
            <span id="value">123.45</span>
            <span class="extra">ignore me</span>
          </main>
        </body></html>
        """
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002 - inherited name
        return


@contextlib.contextmanager
def local_http_server():
    server = ThreadingHTTPServer(("127.0.0.1", 0), SmokeServer)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}/"
    finally:
        server.shutdown()
        thread.join(timeout=2)


class MCPProcess:
    def __init__(self, cli: pathlib.Path, *, stdio_arg: str, framed: bool, container: pathlib.Path):
        self.framed = framed
        env = os.environ.copy()
        env["MACOS_WIDGETS_STATS_TEST_CONTAINER"] = str(container)
        self.proc = subprocess.Popen(
            [str(cli), stdio_arg],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
        )
        assert self.proc.stdin is not None
        assert self.proc.stdout is not None
        self._next_id = 1

    def close(self) -> None:
        if self.proc.stdin:
            with contextlib.suppress(Exception):
                self.proc.stdin.close()
        with contextlib.suppress(subprocess.TimeoutExpired):
            self.proc.wait(timeout=5)
        if self.proc.poll() is None:
            self.proc.terminate()
            with contextlib.suppress(subprocess.TimeoutExpired):
                self.proc.wait(timeout=5)
        if self.proc.poll() is None:
            self.proc.kill()

    def rpc(self, method: str, params: dict[str, Any] | None = None, *, expect_error: bool = False) -> dict[str, Any]:
        request = {
            "jsonrpc": "2.0",
            "id": self._next_id,
            "method": method,
            "params": params or {},
        }
        self._next_id += 1
        payload = json.dumps(request, separators=(",", ":")).encode()
        if self.framed:
            self.proc.stdin.write(f"Content-Length: {len(payload)}\r\n\r\n".encode() + payload)
        else:
            self.proc.stdin.write(payload + b"\n")
        self.proc.stdin.flush()

        response = self._read_response()
        if expect_error:
            if "error" not in response:
                raise AssertionError(f"Expected JSON-RPC error for {method}, got {response}")
        elif "error" in response:
            raise AssertionError(f"Unexpected JSON-RPC error for {method}: {response['error']}")
        return response

    def tool(self, name: str, arguments: dict[str, Any] | None = None, *, expect_error: bool = False) -> Any:
        response = self.rpc(
            "tools/call",
            {"name": name, "arguments": arguments or {}},
            expect_error=expect_error,
        )
        if expect_error:
            return response["error"]
        content = response["result"]["content"][0]["text"]
        return json.loads(content)

    def _read_response(self) -> dict[str, Any]:
        if not self.framed:
            line = self.proc.stdout.readline()
            if not line:
                stderr = self.proc.stderr.read().decode(errors="replace")
                raise AssertionError(f"MCP process exited before response. stderr={stderr}")
            return json.loads(line)

        headers: dict[str, str] = {}
        while True:
            line = self.proc.stdout.readline()
            if not line:
                stderr = self.proc.stderr.read().decode(errors="replace")
                raise AssertionError(f"MCP process exited before framed response. stderr={stderr}")
            stripped = line.strip()
            if not stripped:
                break
            name, value = stripped.decode().split(":", 1)
            headers[name.lower()] = value.strip()
        length = int(headers["content-length"])
        body = self.proc.stdout.read(length)
        return json.loads(body)


def assert_true(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def run_line_smoke(cli: pathlib.Path, *, stdio_arg: str) -> None:
    with tempfile.TemporaryDirectory(prefix="mcp-line-smoke-") as tmp:
        client = MCPProcess(cli, stdio_arg=stdio_arg, framed=False, container=pathlib.Path(tmp))
        try:
            init = client.rpc("initialize")
            assert_true(init["result"]["capabilities"]["tools"] == {}, "initialize should advertise tools capability")
            listed = client.rpc("tools/list")["result"]["tools"]
            names = {tool["name"] for tool in listed}
            assert_true("get_status" in names and "reset_tracker_failure_state" in names, "tool catalog missing expected tools")
            error = client.tool("identify_element", {"url": "https://example.com"}, expect_error=True)
            assert_true("requires the running app socket" in error["message"], "stdio identify_element error should explain socket requirement")
        finally:
            client.close()


def run_framed_control_smoke(cli: pathlib.Path, *, stdio_arg: str, include_scrape: bool) -> None:
    with tempfile.TemporaryDirectory(prefix="mcp-framed-smoke-") as tmp, local_http_server() as url:
        client = MCPProcess(cli, stdio_arg=stdio_arg, framed=True, container=pathlib.Path(tmp))
        try:
            client.rpc("initialize")
            status = client.tool("get_status")
            tool_names = set(status["tools"])
            required = {
                "get_status",
                "list_trackers",
                "get_tracker",
                "add_tracker",
                "update_tracker",
                "delete_tracker",
                "trigger_scrape",
                "reset_tracker_failure_state",
                "identify_element",
                "list_widget_configurations",
                "get_widget_configuration",
                "update_widget_configuration",
                "delete_widget_configuration",
                "export_selector_pack",
                "import_selector_pack",
                "attach_webhook",
            }
            assert_true(required.issubset(tool_names), f"Missing tools: {sorted(required - tool_names)}")
            assert_true("health" in status, "get_status should include tracker health")

            added = client.tool(
                "add_tracker",
                {
                    "name": "Smoke Value",
                    "url": url,
                    "renderMode": "text",
                    "selector": "#value",
                    "label": "Smoke",
                    "refreshIntervalSec": 60,
                },
            )
            tracker_id = added["id"]
            assert_true(client.tool("get_tracker", {"id": tracker_id})["id"] == tracker_id, "get_tracker failed")
            assert_true(any(t["id"] == tracker_id for t in client.tool("list_trackers")), "list_trackers missing tracker")

            if include_scrape:
                reading = client.tool("trigger_scrape", {"id": tracker_id})
                assert_true(reading["status"] == "ok", f"trigger_scrape did not succeed: {reading}")
                assert_true(reading["currentValue"] == "123.45", f"unexpected scraped value: {reading}")

            updated = client.tool("update_tracker", {"id": tracker_id, "selector": "main #value", "hideElements": [".extra"]})
            assert_true(updated["selector"] == "main #value", "update_tracker did not update selector")
            assert_true(updated["reading"]["status"] == "stale", "selector update should mark reading stale pending verification")

            reset = client.tool("reset_tracker_failure_state", {"id": tracker_id, "reason": "smoke reset"})
            assert_true(reset["reading"]["status"] == "stale", "reset should leave tracker stale, not ok")

            widget = client.tool(
                "update_widget_configuration",
                {
                    "name": "Smoke Widget",
                    "templateID": "single-big-number",
                    "size": "small",
                    "layout": "single",
                    "trackerIDs": [tracker_id],
                },
            )
            widget_id = widget["id"]
            assert_true(client.tool("get_widget_configuration", {"id": widget_id})["id"] == widget_id, "get widget failed")
            assert_true(any(w["id"] == widget_id for w in client.tool("list_widget_configurations")), "list widgets missing widget")

            pack = client.tool("export_selector_pack", {"trackerId": tracker_id})
            imported = client.tool("import_selector_pack", {"json": pack})
            imported_id = imported["trackerId"]
            assert_true(imported_id != tracker_id, "import should create a separate tracker")

            client.tool("attach_webhook", {"url": "http://127.0.0.1:9/hook"})
            client.tool("attach_webhook", {"url": None})

            client.tool("delete_widget_configuration", {"id": widget_id})
            client.tool("delete_tracker", {"id": imported_id})
            client.tool("delete_tracker", {"id": tracker_id})
            assert_true(client.tool("get_status")["counts"]["trackers"] == 0, "cleanup left trackers behind")
        finally:
            client.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", type=pathlib.Path, default=pathlib.Path(os.environ.get("MCP_CLI", DEFAULT_CLI)))
    parser.add_argument("--stdio-arg", help="Override the stdio argument; defaults to --mcp-stdio for the app executable, mcp-stdio otherwise")
    parser.add_argument("--skip-scrape", action="store_true", help="Skip live WebKit trigger_scrape check")
    args = parser.parse_args()

    cli = args.cli.resolve()
    if not cli.exists():
        print(f"CLI not found: {cli}", file=sys.stderr)
        print("Build it first with: xcodebuild -project MacosWidgetsStatsFromWebsite.xcodeproj -scheme MacosWidgetsStatsFromWebsiteCLI -configuration Debug -derivedDataPath build/mcp-verify-derived CODE_SIGNING_ALLOWED=NO build", file=sys.stderr)
        return 2

    stdio_arg = args.stdio_arg or ("--mcp-stdio" if cli.name == "MacosWidgetsStatsFromWebsite" else "mcp-stdio")
    run_line_smoke(cli, stdio_arg=stdio_arg)
    run_framed_control_smoke(cli, stdio_arg=stdio_arg, include_scrape=not args.skip_scrape)
    print("MCP smoke test passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
