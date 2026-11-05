#!/usr/bin/env python3
"""Stalled-viewer test: open N camera stream connections that never read, and watch the
bridge's memory for `secs` seconds. Before the 2026-11-04 relay fix the bridge grew by the
camera's bit-rate per stalled client, without limit."""
import os, socket, subprocess, sys, time, json, urllib.request

base = sys.argv[1] if len(sys.argv) > 1 else 'http://localhost:8088'
n = int(sys.argv[2]) if len(sys.argv) > 2 else 3
secs = int(sys.argv[3]) if len(sys.argv) > 3 else 60
host, port = base.split('//')[1].split(':')[0], int(base.rsplit(':', 1)[1])

pid = [p for p in subprocess.check_output(['pgrep', '-f', 'bin/pibridge.dart']).split() if 'dartvm' in open(f'/proc/{p.decode()}/cmdline').read()][0].decode()
def rss():
    for l in open(f'/proc/{pid}/status'):
        if l.startswith('VmRSS'):
            return int(l.split()[1]) // 1024
st = json.load(urllib.request.urlopen(base + '/api/status'))
pr = st['printers'][0]['id']

socks = []
for i in range(n):
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 2048)  # tiny window, set BEFORE connect: stalls fast
    s.connect((host, 7125))
    s.sendall('GET /webcam/?action=stream HTTP/1.1\r\nHost: x\r\n\r\n'.encode())
    socks.append(s)
# one healthy reader so the upstream stays busy at full rate
good = socket.create_connection((host, port))
good.sendall(f'GET /api/printers/{pr}/camera HTTP/1.1\r\nHost: x\r\n\r\n'.encode())
good.settimeout(0.2)
t0 = time.time(); r0 = rss(); got = 0
print(f'start rss={r0} MB, {n} stalled clients + 1 reader')
while time.time() - t0 < secs:
    try:
        got += len(good.recv(65536))
    except socket.timeout:
        pass
    if int(time.time() - t0) % 10 == 0:
        print(f'  t={int(time.time()-t0):3d}s rss={rss()} MB reader got {got//1024} KB'); time.sleep(1)
r1 = rss()
print(f'end rss={r1} MB (grew {r1 - r0} MB); reader received {got//1024} KB')
sys.exit(1 if r1 - r0 > 60 else 0)
