"""Local deterministic SSE service for isolated Anx AI integration tests only."""
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class AIService:
    def __init__(self):
        self.requests = []
        self.cancelled = 0
        owner = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                assert self.headers.get("Authorization") == "Bearer anx-fixture-key"
                assert self.path.endswith("/v1/chat/completions")
                assert body["model"] in ("fixture-model", "fixture-model-2") and body["stream"] is True
                prompt = body["messages"][-1]["content"]
                owner.requests.append({"messages": body["messages"], "model": body["model"]})
                if "__fail__" in prompt:
                    payload = b'{"error":{"message":"fixture private error"}}'
                    self.send_response(429)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Connection", "close")
                self.end_headers()
                try:
                    tool_results = [m for m in body["messages"] if m["role"] == "tool"]
                    last_question = next((m["content"] for m in reversed(body["messages"]) if m["role"] == "user"), "")
                    use_tools = "__tools__" in last_question
                    if use_tools and len(tool_results) < 2:
                        assert body.get("tools"), "tools require explicit opt-in"
                        name = "current_book_toc" if not tool_results else "read_chapter"
                        args = "{}" if not tool_results else '{"chapter":2}'
                        parts = [{"index": 0, "id": f"fixture-{len(tool_results)}", "type": "function", "function": {"name": name, "arguments": ""}},
                                 {"index": 0, "function": {"arguments": args}}]
                        for part in parts:
                            frame = "data: " + json.dumps({"choices": [{"delta": {"tool_calls": [part]}}]}) + "\n\n"
                            self.wfile.write(frame.encode()); self.wfile.flush()
                        self.wfile.write(b'data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}\n\ndata: [DONE]\n\n')
                        self.wfile.flush()
                        return
                    words = ["你好，", "这是流式回答。", "\n已收到问题：", prompt]
                    if use_tools:
                        assert "Reading sample 2.1" in tool_results[-1]["content"]
                        words = ["# 第二章\n\n", "工具读到了第二章，来源 [S1]。"]
                    if "思维导图" in prompt:
                        words = ["- 阅读主题\n  - 核心观点 [S1]\n    - 示例\n  - 思考问题\n"]
                    elif "只输出译文" in prompt:
                        words = ["这是原文片段的中文译文。\n\n", "保留段落结构与来源 [S1]。"]
                    elif "阅读报告" in prompt:
                        words = ["# 阅读报告\n\n", "## 材料范围\n提供的章节片段。\n\n## 核心观点\n见原文 [S1]。"]
                    if "__markdown__" in prompt:
                        words = ["# 阅读总结\n\n", "**重点**\n\n- 第一项\n- 第二项\n\n", "    print('hello')\n"]
                    if "__slow__" in prompt:
                        words = ["正在逐步回答。"] * 200
                    for word in words:
                        frame = "data: " + json.dumps({"choices": [{"delta": {"content": word}}]}, ensure_ascii=False) + "\r\n\r\n"
                        payload = frame.encode()
                        # Deliberately split UTF-8 and CRLF across socket writes.
                        for index in range(0, len(payload), 7):
                            self.wfile.write(payload[index:index + 7])
                            self.wfile.flush()
                        time.sleep(.18)
                    if "__cut__" not in prompt:
                        self.wfile.write(b'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n')
                        self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    owner.cancelled += 1
                finally:
                    self.close_connection = True

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_port}/v1"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()
