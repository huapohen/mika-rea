import concurrent.futures
import json
import http.client
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from server import Relay, Handler

class RelayTests(unittest.TestCase):
    def setUp(self):
        self.relay=Relay({'one':{'agent_token':'agent-one','client_token':'client-one'},'two':{'agent_token':'agent-two','client_token':'client-two'}})
        self.server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
        self.server.relay=self.relay
        self.server.daemon_threads=True
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True)
        self.thread.start()
        self.base='http://127.0.0.1:'+str(self.server.server_port)
    def tearDown(self):
        self.server.shutdown();self.server.server_close();self.thread.join()
    def post(self,path,token,body):
        req=urllib.request.Request(self.base+path,data=json.dumps(body).encode(),headers={'Authorization':'Bearer '+token})
        try:
            with urllib.request.urlopen(req,timeout=3) as r:return r.status,json.load(r)
        except urllib.error.HTTPError as e:return e.code,json.load(e)
    def test_auth_and_roles(self):
        for token in ('','incorrect','agent-one'):
            self.assertEqual(401,self.post('/v1/one/status',token,{})[0])
        self.assertEqual(401,self.post('/v1/one/next','client-one',{})[0])
        self.assertEqual(401,self.post('/v1/two/status','client-one',{})[0])
    def test_real_http_round_trip_and_device_isolation(self):
        rpc={'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':'mika_run_task','arguments':{'goal':'test'}}}
        with concurrent.futures.ThreadPoolExecutor() as pool:
            future=pool.submit(self.post,'/v1/one/rpc','client-one',rpc)
            code,command=self.post('/v1/one/next','agent-one',{})
            self.assertEqual(200,code);self.assertEqual(rpc,command['rpc'])
            _,wrong=self.post('/v1/two/result','agent-two',{'id':command['id'],'response':{}})
            self.assertFalse(wrong['accepted'])
            reply={'jsonrpc':'2.0','id':1,'result':{'structuredContent':{'task_id':'t1'}}}
            self.assertTrue(self.post('/v1/one/result','agent-one',{'id':command['id'],'response':reply})[1]['accepted'])
            self.assertEqual((200,reply),future.result())
    def test_rejects_unknown_tools_and_oversize_bodies(self):
        rpc={'method':'tools/call','params':{'name':'shell_execute'}}
        self.assertEqual(400,self.post('/v1/one/rpc','client-one',rpc)[0])
        connection=http.client.HTTPConnection('127.0.0.1',self.server.server_port,timeout=3)
        connection.request('POST','/v1/one/rpc',body=b'{}',headers={'Authorization':'Bearer client-one','Content-Length':'2097153'})
        self.assertEqual(413,connection.getresponse().status)
        connection.close()
    def test_expired_request_is_removed(self):
        with self.assertRaises(TimeoutError):self.relay.request('one',{'method':'initialize'},timeout=0.01)
        self.assertEqual({},self.relay.pending)
if __name__=='__main__':unittest.main()
