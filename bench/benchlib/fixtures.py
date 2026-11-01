"""Fixture files and the local page server (127.0.0.1 only).

Everything a task needs is written under a per-run temp directory; nothing outside it is created.
"""
import http.server
import json
import os
import threading
import urllib.parse

FORM_HTML = """<!doctype html>
<html><head><meta charset="utf-8"><title>Bench form</title></head>
<body>
<h1>Bench form</h1>
<form method="post" action="/submit">
  <label for="name">Name</label> <input id="name" name="name" type="text"><br>
  <label for="email">Email</label> <input id="email" name="email" type="text"><br>
  <button type="submit">Send</button>
</form>
</body></html>
"""

DONE_HTML = "<!doctype html><html><head><meta charset=\"utf-8\"><title>Sent</title></head><body><h1>Sent</h1></body></html>"


def pdf_bytes(pages, title="bench", text=None):
    """A small valid PDF with one line of text per page; `text` replaces the first page's line."""
    objs = []
    objs.append("<< /Type /Catalog /Pages 2 0 R >>")
    kids = " ".join(f"{3 + i * 2} 0 R" for i in range(pages))
    objs.append(f"<< /Type /Pages /Kids [{kids}] /Count {pages} >>")
    font_id = 3 + pages * 2
    for i in range(pages):
        content_id = 4 + i * 2
        objs.append(f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents {content_id} 0 R "
                    f"/Resources << /Font << /F1 {font_id} 0 R >> >> >>")
        line = text if (text and i == 0) else f"{title} page {i + 1}"
        line = line.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")
        stream = f"BT /F1 24 Tf 72 700 Td ({line}) Tj ET"
        objs.append(f"<< /Length {len(stream)} >>\nstream\n{stream}\nendstream")
    objs.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for n, body in enumerate(objs, start=1):
        offsets.append(len(out))
        out += f"{n} 0 obj\n{body}\nendobj\n".encode("latin-1")
    xref = len(out)
    out += f"xref\n0 {len(objs) + 1}\n0000000000 65535 f \n".encode()
    for off in offsets:
        out += f"{off:010d} 00000 n \n".encode()
    out += f"trailer\n<< /Size {len(objs) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    return bytes(out)


RTF_BODY = r"{\rtf1\ansi\ansicpg1252\cocoartf2700{\fonttbl\f0\fswiss Helvetica;}\f0\fs24 plain words to make bold\par}"


def write_files(root, spec):
    """spec maps relative paths to a string, {"lines": n}, {"pdf_pages": n}, {"rtf": true} or {"dir": true}."""
    for rel, content in spec.items():
        path = os.path.join(root, rel)
        if isinstance(content, dict) and content.get("dir"):
            os.makedirs(path, exist_ok=True)
            continue
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if isinstance(content, str):
            data = content.encode("utf-8")
        elif "lines" in content:
            data = "".join(f"line {i:04d} of the bench scroll fixture\n" for i in range(1, content["lines"] + 1)).encode()
        elif "pdf_pages" in content:
            data = pdf_bytes(content["pdf_pages"], title=os.path.splitext(os.path.basename(rel))[0], text=content.get("text"))
        elif content.get("rtf"):
            data = RTF_BODY.encode()
        else:
            raise ValueError(f"unknown fixture spec for {rel}: {content!r}")
        with open(path, "wb") as fh:
            fh.write(data)


class _Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):  # silence
        pass

    def _send(self, body, ctype="text/html; charset=utf-8", code=200):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.startswith("/form"):
            self._send(FORM_HTML)
        elif self.path == "/submissions":
            self._send(json.dumps(self.server.submissions), "application/json")
        else:
            self._send("not found", code=404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode("utf-8", "replace")
        form = {k: v[-1] for k, v in urllib.parse.parse_qs(body, keep_blank_values=True).items()}
        self.server.submissions.append(form)
        self._send(DONE_HTML)


class FixtureServer:
    """Serves /form and records each POST /submit. Bound to 127.0.0.1 on a free port."""

    def __init__(self):
        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
        self.httpd.submissions = []
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    @property
    def port(self):
        return self.httpd.server_address[1]

    @property
    def base(self):
        return f"http://127.0.0.1:{self.port}"

    @property
    def submissions(self):
        return list(self.httpd.submissions)

    def reset(self):
        self.httpd.submissions.clear()

    def start(self):
        self.thread.start()
        return self

    def stop(self):
        self.httpd.shutdown()
        self.httpd.server_close()
