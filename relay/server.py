"""Mika outbound relay. Run behind TLS (Caddy); no API/model keys required."""
import argparse, hmac, json, queue, re, secrets, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

MAX_BODY = 2 * 1024 * 1024
TOOLS = {'mika_run_task','mika_task_status','mika_wait_task','mika_answer','mika_cancel_task','mika_list_tasks'}
class Relay:
    def __init__(self, devices):
        self.devices = devices
        self.queues = {key: queue.Queue(maxsize=16) for key in devices}
        self.pending = {}
        self.lock = threading.Lock()
        self.changed = threading.Condition(self.lock)
        self.poll_generation = {}
        self.last_seen = {}
    def auth(self, device, token, role):
        expected = self.devices.get(device, {}).get(role + '_token', '')
        return bool(expected and hmac.compare_digest(expected, token))
    def request(self, device, rpc, timeout=55):
        method = rpc.get('method')
        if method != 'initialize' and not (method == 'tools/call' and rpc.get('params',{}).get('name') in TOOLS):
            raise ValueError('Unsupported method')
        ident = secrets.token_hex(16)
        event = threading.Event()
        item = {'id':ident,'rpc':rpc,'event':event,'device':device,'deadline':time.monotonic()+timeout}
        with self.changed:
            self.queues[device].put_nowait(item)
            self.pending[ident] = item
            self.changed.notify_all()
        try:
            if not event.wait(timeout): raise TimeoutError('Device offline or request timed out')
            return item['response']
        finally:
            with self.lock: self.pending.pop(ident, None)
    def next(self, device):
        # A reconnect supersedes a long poll whose client may already be gone.
        # Check the generation and dequeue atomically so the old poll cannot
        # consume a command intended for the new phone connection.
        with self.changed:
            generation = self.poll_generation.get(device, 0) + 1
            self.poll_generation[device] = generation
            self.last_seen[device] = time.time()
            self.changed.notify_all()
            end = time.monotonic()+20
            while time.monotonic() < end:
                if self.poll_generation[device] != generation: return {}
                try: item = self.queues[device].get_nowait()
                except queue.Empty:
                    self.changed.wait(max(0.01,end-time.monotonic()))
                    continue
                if item['id'] in self.pending and item['deadline'] > time.monotonic():
                    return {'id':item['id'],'rpc':item['rpc']}
        return {}
    def complete(self, device, ident, response):
        with self.lock:
            item = self.pending.get(ident)
            if not item or item['device'] != device: return False
            item['response'] = response
            item['event'].set()
            return True

class Handler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup()
        self.connection.settimeout(65)
    def do_GET(self):
        if self.path.rstrip('/') in ('', '/health'):
            return self.send_json(200, {'service':'mika-rea','status':'ok','version':1})
        self.send_json(404, {'error':'Not found'})
    def log_message(self, *args): pass # Never log request bodies, auth, or phone contents.
    def send_json(self, status, value):
        data = json.dumps(value,ensure_ascii=False).encode()
        self.send_response(status); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers()
        try: self.wfile.write(data)
        except (BrokenPipeError,ConnectionResetError): pass
    def do_POST(self):
        try:
            parts = self.path.strip('/').split('/')
            if len(parts)!=3 or parts[0]!='v1' or parts[2] not in ('rpc','next','result','status'): return self.send_json(404,{'error':'Not found'})
            _, device, action = parts
            role = 'agent' if action in ('next','result') else 'client'
            authorization = self.headers.get('Authorization','')
            token = authorization[7:] if authorization.startswith('Bearer ') else ''
            if not self.server.relay.auth(device,token,role): return self.send_json(401,{'error':'Unauthorized'})
            length = int(self.headers.get('Content-Length','0'))
            if length<0 or length>MAX_BODY: return self.send_json(413,{'error':'Payload too large'})
            body=json.loads(self.rfile.read(length) or b'{}')
            if not isinstance(body,dict): raise ValueError('JSON object required')
            relay=self.server.relay
            if action=='status': return self.send_json(200,{'online':time.time()-relay.last_seen.get(device,0)<35,'platform':relay.devices[device].get('platform','android')})
            if action=='next': return self.send_json(200,relay.next(device))
            if action=='result': return self.send_json(200,{'accepted':relay.complete(device,body.get('id'),body.get('response'))})
            return self.send_json(200,relay.request(device,body))
        except queue.Full: self.send_json(429,{'error':'Device queue full'})
        except TimeoutError: self.send_json(504,{'error':'Device offline or request timed out'})
        except (ValueError,KeyError,TypeError): self.send_json(400,{'error':'Invalid request'})
        except Exception: self.send_json(500,{'error':'Internal relay error'})

def main():
    p=argparse.ArgumentParser(); p.add_argument('--config',required=True); p.add_argument('--host',default='127.0.0.1'); p.add_argument('--port',type=int,default=8787); p.add_argument('--create-device'); p.add_argument('--platform',choices=('android','ios'),default='android'); a=p.parse_args()
    path=Path(a.config)
    if a.create_device:
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,64}',a.create_device): p.error('Invalid device ID')
        cfg=json.loads(path.read_text()) if path.exists() else {'devices':{}}
        if a.create_device in cfg['devices']: p.error('Device already exists; refusing to replace pairing')
        cfg['devices'][a.create_device]={'platform':a.platform,'client_token':secrets.token_urlsafe(32),'agent_token':secrets.token_urlsafe(32)}
        path.parent.mkdir(parents=True,exist_ok=True)
        import os, tempfile
        fd,temporary=tempfile.mkstemp(prefix='.'+path.name+'-',dir=path.parent)
        try:
            with os.fdopen(fd,'w') as out:
                json.dump(cfg,out);out.flush();os.fsync(out.fileno())
            os.replace(temporary,path)
        finally:
            if os.path.exists(temporary): os.unlink(temporary)
        print('Pairing created; credentials written to configuration file (not printed).'); return
    server=ThreadingHTTPServer((a.host,a.port),Handler); server.relay=Relay(json.loads(path.read_text())['devices']); server.daemon_threads=True
    print('Mika relay listening',flush=True); server.serve_forever()
if __name__=='__main__': main()
