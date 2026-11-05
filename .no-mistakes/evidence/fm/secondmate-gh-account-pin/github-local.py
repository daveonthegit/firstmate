import http.server,socketserver,ssl,json,sys
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain(sys.argv[1],sys.argv[2])
log=open(sys.argv[3],'a',buffering=1)
class H(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a): pass
 def do_CONNECT(self):
  if self.path not in ('api.github.com:443','github.com:443'): self.send_error(403);return
  self.send_response(200);self.end_headers()
  self.connection=ctx.wrap_socket(self.connection,server_side=True)
  self.rfile=self.connection.makefile('rb');self.wfile=self.connection.makefile('wb')
  self.close_connection=False
  self.handle_one_request()
 def do_POST(self):
  self.rfile.read(int(self.headers.get('Content-Length','0')))
  auth=self.headers.get('Authorization','')
  who='fixture-target' if auth.endswith('synthetic-secco') else 'fixture-source' if auth.endswith('synthetic-dave') else 'unknown'
  body=json.dumps({'data':{'viewer':{'login':who,'id':'MDQ6VXNlcjE='}}}).encode()
  log.write(json.dumps({'path':self.path,'account':who,'status':200})+'\n')
  self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.send_header('X-OAuth-Scopes','repo, read:org');self.end_headers();self.wfile.write(body)
 def do_GET(self):
  auth=self.headers.get('Authorization','')
  who='fixture-target' if auth.endswith('synthetic-secco') else 'fixture-source' if auth.endswith('synthetic-dave') else 'unknown'
  code=200
  if self.path=='/': body={'current_user_url':'https://api.github.com/user'}
  elif self.path=='/user': body={'login':who,'id':1 if who=='fixture-source' else 2}
  elif self.path.startswith('/repos/BG-Media-LLC/'):
   if who!='fixture-target':code=404;body={'message':'Not Found'}
   else:body={'full_name':'BG-Media-LLC/validation','private':True,'permissions':{'admin':True,'push':True,'pull':True}}
  else:code=404;body={'message':'Not Found'}
  log.write(json.dumps({'path':self.path,'account':who,'status':code})+'\n')
  b=json.dumps(body).encode();self.send_response(code);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(b)));self.send_header('X-OAuth-Scopes','repo, read:org');self.end_headers();self.wfile.write(b)
class S(socketserver.ThreadingMixIn,http.server.HTTPServer): daemon_threads=True
S(('127.0.0.1',19348),H).serve_forever()
