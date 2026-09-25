# Minimal Zipkin v2 collector: stores every POSTed span array, merged into one
# JSON array file on each request so the file is always complete.
import gzip,json,sys
from http.server import BaseHTTPRequestHandler, HTTPServer
out=sys.argv[2]; spans=[]
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body=self.rfile.read(int(self.headers.get("Content-Length",0)))
        if self.headers.get("Content-Encoding")=="gzip": body=gzip.decompress(body)
        spans.extend(json.loads(body))
        json.dump(spans, open(out,"w"))
        self.send_response(202); self.end_headers()
    def log_message(self,*a): pass
HTTPServer(("127.0.0.1",int(sys.argv[1])),H).serve_forever()
