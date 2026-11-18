import http.server, ssl, json, pathlib, threading, urllib.parse, sys
root=pathlib.Path(__file__).resolve().parent
lock=threading.Lock()
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_CONNECT(self):
        self.send_response(200); self.end_headers()
        ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(root/'cert.pem',root/'key.pem')
        self.connection=ctx.wrap_socket(self.connection,server_side=True)
        self.rfile=self.connection.makefile('rb'); self.wfile=self.connection.makefile('wb')
        self.close_connection=False
        self.handle_one_request()
    def reply(self,status,obj):
        data=json.dumps(obj).encode()
        self.send_response(status); self.send_header('Content-Type','application/json')
        self.send_header('Content-Length',str(len(data)))
        self.send_header('X-OAuth-Scopes','repo, read:org')
        self.send_header('Connection','close'); self.end_headers(); self.wfile.write(data)
        self.close_connection=True
    def do_GET(self): self.api()
    def do_POST(self): self.api()
    def api(self):
        p=urllib.parse.urlsplit(self.path)
        with lock:
            state=json.loads((root/'state.json').read_text())
            body=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0')))) if self.command=='POST' else None
            record={'method':self.command,'path':self.path,'synthetic_token':self.headers.get('Authorization','').endswith('fm_synthetic_board_token')}
            if body is not None: record['body']=body
            with (root/'requests.jsonl').open('a') as f: f.write(json.dumps(record)+'\n')
            if p.path=='/user': return self.reply(200,{'login':'fm-board-lab','id':42})
            if p.path=='/': return self.reply(200,{'current_user_url':'https://api.github.com/user'})
            if state.get('fail'): return self.reply(404,{'message':'Not Found'})
            base='/repos/BG-Media-LLC/agent-board/issues/1'
            if p.path==base: return self.reply(200,{'number':1,'updated_at':'2026-11-01T10:00:00Z'})
            if p.path==base+'/comments':
                if self.command=='POST':
                    idx=900+len(state.get('posts',[]))
                    state.setdefault('posts',[]).append(body)
                    (root/'state.json').write_text(json.dumps(state))
                    return self.reply(201,{'id':idx,'html_url':f'https://github.com/BG-Media-LLC/agent-board/issues/1#issuecomment-{idx}'})
                q=urllib.parse.parse_qs(p.query); since=q.get('since',[''])[0]
                page=int(q.get('page',['1'])[0]); size=int(q.get('per_page',['100'])[0])
                comments=[c for c in state['comments'] if c['updated_at']>=since]
                return self.reply(200,comments[(page-1)*size:page*size])
            return self.reply(404,{'message':'unexpected emulator endpoint: '+p.path})
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
(root/'port').write_text(str(server.server_port))
server.serve_forever()
