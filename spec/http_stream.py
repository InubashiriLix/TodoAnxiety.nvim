"""Exercise curl streaming against a local HTTP server; no external requests."""
import http.server
import json
import os
import subprocess
import tempfile
import threading
import time


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', 0)))
        assert self.headers.get('Authorization') == 'Bearer private-test-value'
        if self.path == '/auth':
            self.send_response(401)
            self.end_headers()
            self.wfile.write(b'{"error":"private-test-value"}')
            return
        self.send_response(200)
        self.send_header('Content-Type', 'application/json' if self.path == '/json' else 'text/event-stream')
        self.end_headers()
        if self.path == '/json':
            self.wfile.write(b'{}')
            return
        try:
            def send(event):
                frame = 'data: ' + json.dumps(event, ensure_ascii=False) + '\r\n\r\n'
                self.wfile.write(frame.encode())
                self.wfile.flush()
            send({'choices': [{'delta': {'content': '{"message":"你好'}}]})
            time.sleep(.35)
            if self.path in ('/cancel', '/truncated'):
                return
            send({'choices': [{'delta': {'content': '","action":"draft","changes":[]}'}, 'finish_reason': 'stop'}],
                  'usage': {'prompt_tokens': 12, 'completion_tokens': 4}})
            self.wfile.write(b'data: [DONE]\r\n\r\n')
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
script = r'''
package.path='./lua/?.lua;./lua/?/init.lua;'..package.path
local http=require('todo.http')
local system=vim.system
vim.system=function(argv, ...)
 for _,arg in ipairs(argv)do assert(not arg:find('private-test-value',1,true),'secret in argv')end
 return system(argv,...)
end
local function run(path)
 local finished,err,response,first=false,nil,nil,false
 local handle=http.stream({url='http://127.0.0.1:PORT'..path,headers={Authorization='Bearer private-test-value'},body={stream=true}},function(value)
  assert(not finished,'delta must arrive before completion')
  first=true;assert(value=='你好')
 end,function(e,r)finished=true;err=e;response=r end)
 if path=='/cancel' then
  assert(vim.wait(3000,function()return first end,10),'no partial response')
  handle.cancel()
 end
 assert(vim.wait(5000,function()return finished end,10),'timeout')
 assert(not handle.running)
 if path=='/ok' then
  assert(not err,err);assert(first);assert(response.usage.prompt_tokens==12)
  assert(vim.json.decode(response.choices[1].message.content).action=='draft')
 else
  assert(err,'expected error: '..path)
  assert(not err:find('private-test-value',1,true))
  if path=='/cancel' then assert(err=='cancelled') end
  if path=='/truncated' then assert(err:find('interrupted',1,true)) end
  if path=='/auth' then assert(err:find('401',1,true)) end
 end
end
for _,path in ipairs({'/ok','/truncated','/cancel','/auth','/json'})do run(path)end
print('ok - real async HTTP SSE, incremental delivery, usage, truncation, cancellation, 401 and unsupported streaming')
vim.cmd('qa!')
'''.replace('PORT', str(server.server_address[1]))
try:
    with tempfile.TemporaryDirectory(prefix='todo-http-test-') as d:
        filename = os.path.join(d, 'stream.lua')
        with open(filename, 'w') as f:
            f.write(script)
        subprocess.run(['nvim', '--clean', '--headless', '-l', filename], check=True, timeout=25,
                       env=dict(os.environ, XDG_STATE_HOME=d))
finally:
    server.shutdown()
