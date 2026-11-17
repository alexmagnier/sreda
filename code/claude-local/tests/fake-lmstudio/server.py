"""Fake LM Studio HTTP server for tests: GET /v1/models lists identifiers from $FAKE_LMS_STATE/loaded."""
import http.server, json, os, sys
S = os.path.join(os.environ["FAKE_LMS_STATE"], "loaded")
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            ids = [m["identifier"] for m in json.load(open(S))]
        except Exception:
            ids = []
        b = json.dumps({"data": [{"id": i} for i in ids]}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
