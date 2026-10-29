#!/usr/bin/env python3
"""Read-only protocol probe. One ping/version request, no list/apps/screenshots/input.
Risk: connects to live service and may create its ordinary connection/audit logs.
No service startup, retry, identity spoofing, auth bypass, or process signaling.
"""
import json, os, socket, struct, time
PATH = os.path.expanduser('~/Library/Group Containers/2DC432GLL2.com.openai.sky.CUAService/IPC/computeruse.sock')
MAX_FRAME = 8 * 1024 * 1024

def exact(sock, count):
    result = b''
    while len(result) < count:
        part = sock.recv(count - len(result))
        if not part:
            raise EOFError(f'EOF after {len(result)}/{count} bytes')
        result += part
    return result

def main():
    print(json.dumps({'time':time.strftime('%Y-%m-%dT%H:%M:%S%z'), 'pid':os.getpid(), 'socket':PATH}))
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(0.25)
        sock.connect(PATH)
        print('CONNECT_OK')
        try:
            greeting = sock.recv(4096)
            print('UNSOLICITED_BYTES', greeting.hex())
            if not greeting:
                print('PEER_CLOSED_BEFORE_REQUEST'); return
            print('Unexpected greeting; conservatively stop.'); return
        except socket.timeout:
            print('NO_UNSOLICITED_GREETING_WITHIN_250MS')
        request = {'id':1,'jsonrpc':'2.0','method':'ping','params':{'clientApiVersion':'CodexComputerUseIPC-5'}}
        body = json.dumps(request, separators=(',',':')).encode('utf8')
        frame = struct.pack('<I',len(body)) + body
        print('SEND_JSON',body.decode()); print('SEND_HEX',frame.hex())
        sock.settimeout(3)
        sock.sendall(frame)
        header = exact(sock,4); length = struct.unpack('<I',header)[0]
        print('RECV_HEADER_HEX',header.hex(),'LENGTH',length)
        if length > MAX_FRAME: raise ValueError('oversized frame')
        response = exact(sock,length)
        print('RECV_HEX',response.hex()); print('RECV_JSON',response.decode('utf8'))
        json.loads(response)

if __name__ == '__main__':
    try: main()
    except Exception as error:
        print('PROBE_ERROR',type(error).__name__,str(error))
        raise
