import http.server, ssl, json, pathlib, sys
root=pathlib.Path(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
 def do_POST(self):
  request=self.rfile.read(int(self.headers.get('content-length',0))).decode()
  with (root/'api-requests.log').open('a') as f: f.write(self.path+' '+request+'\n')
  state=json.loads((root/'api-state.json').read_text())
  if state.get('unavailable'):
   self.send_response(503); self.end_headers(); self.wfile.write(b'forge unavailable'); return
  body=json.dumps({'data':{'repository':{'pullRequest':state}}}).encode()
  self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
 def log_message(self,*args): pass
server=http.server.HTTPServer(('127.0.0.1',0),Handler)
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(root/'cert.pem',root/'key.pem')
server.socket=ctx.wrap_socket(server.socket,server_side=True)
(root/'api-port').write_text(str(server.server_port))
server.serve_forever()
