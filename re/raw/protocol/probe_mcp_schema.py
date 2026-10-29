#!/usr/bin/env python3
"""Discover tool schemas in a separate runtime; never invokes tools or JS.
Disable JS banner and trusted services to avoid starting computer/browser clients.
Only initialize + notifications/initialized + tools/list; close stdin normally.
No signals and no kill.
"""
import json, os, subprocess, select, time
exe='/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl'
env=dict(os.environ)
env.update(NODE_REPL_JS_BANNER='', NODE_REPL_TRUSTED_SERVICES='{}', NODE_REPL_NODE_PATH='/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node')
for key in ['NODE_REPL_WORKER_WRAPPER','NODE_REPL_TOOL_OVERRIDES']:
    env.pop(key,None)
with open('re/raw/protocol/mcp-schema-stderr.log','w') as err:
    p=subprocess.Popen([exe],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=err,env=env,text=True,bufsize=1)
    def send(msg):
        print('SEND',json.dumps(msg),flush=True)
        p.stdin.write(json.dumps(msg)+'\n');p.stdin.flush()
    def receive(wanted):
        deadline=time.monotonic()+10
        while time.monotonic()<deadline:
            if not select.select([p.stdout],[],[],max(0,deadline-time.monotonic()))[0]:break
            line=p.stdout.readline()
            if not line:raise EOFError('runtime closed')
            print('RECV',line.rstrip(),flush=True)
            msg=json.loads(line)
            if msg.get('id')==wanted:return msg
        raise TimeoutError('MCP response timeout')
    try:
        send({'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2024-11-05','capabilities':{},'clientInfo':{'name':'read-only-schema-probe','version':'1'}}})
        receive(1)
        send({'jsonrpc':'2.0','method':'notifications/initialized'})
        send({'jsonrpc':'2.0','id':2,'method':'tools/list','params':{}})
        result=receive(2)
        with open('re/raw/protocol/mcp-tools-list.json','w') as out:json.dump(result,out,ensure_ascii=False,indent=2)
    finally:
        p.stdin.close()
        print('CHILD_EXIT',p.wait(timeout=10),flush=True)
