"""PC stand-in for the iPhone in browser mode (TV Mirror v2.0).

Serves Broadcast/player.html and speaks the phone's side of its WebSocket protocol (see
docs/superpowers/specs/2026-11-12-browser-mirroring-design.md), with ffmpeg playing the screen:
a moving test pattern with the PC clock, and a beep every second. Use it to test the page in desktop
Chrome or on the LG TV without building the app.

    py tools/browser_test.py --local                     # then open http://localhost:8092/ in Chrome
    py tools/browser_test.py --tv 192.168.1.122          # opens the page on the TV, clicks for full screen
    py tools/browser_test.py --tv 192.168.1.122 --minutes 10 --hiccup-every 60 --hiccup-seconds 2
    py tools/browser_test.py --tv 192.168.1.122 --sample DIR   # replay a stream written by the CI test

The first --tv run shows "allow this device?" on the TV; the key is saved in ~/.tvmirror-lgtv-key.
Needs ffmpeg in PATH (and Windows for the clock font path). tools/lgtv_register.json is the
registration payload of LG's remote app, as used by PyWebOSTV (MIT License).
"""
import argparse
import base64
import collections
import hashlib
import json
import os
import queue
import socket
import statistics
import struct
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
PAGE = os.path.join(HERE, "..", "Broadcast", "player.html")
KEY_FILE = os.path.expanduser("~/.tvmirror-lgtv-key")
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
TIMESCALE = {0: 90000, 1: 48000}
FILLER_SECONDS = 4.0
START_LEAD, MAX_LEAD, LEAD_STEP = 1.0, 2.0, 0.5

CLOCK = (r"drawtext=fontfile='C\:/Windows/Fonts/arial.ttf':text='%{localtime\:%H\\\:%M\\\:%S}'"
         r":fontsize=160:fontcolor=white:box=1:boxcolor=black:x=(w-tw)/2:y=(h-th)/2")
FILLER_TEXT = (r"drawtext=fontfile='C\:/Windows/Fonts/arial.ttf':text='connecting':fontsize=90"
               r":fontcolor=white:x=(w-tw)/2:y=(h-th)/2")
BEEP = "aevalsrc=exprs=0.4*sin(2*PI*880*t)*lt(mod(t\\,1)\\,0.2):c=stereo:s=48000"
FRAG = ["-movflags", "frag_keyframe+empty_moov+default_base_moof"]


def x264(bitrate):
    # A keyframe every 5 frames stands in for the app's short first GOP after a splice (ffmpeg cannot
    # force a keyframe on demand); every fragment starts with a keyframe, as the TV requires.
    return ["-c:v", "libx264", "-preset", "veryfast", "-tune", "zerolatency", "-profile:v", "main",
            "-level", "4.0", "-b:v", bitrate, "-maxrate", bitrate, "-bufsize", bitrate, "-g", "5",
            "-keyint_min", "5", "-sc_threshold", "0", "-video_track_timescale", "90000", "-an", "-f", "mp4"] + FRAG


def ffmpeg_live(track, bitrate):
    if track == 0:
        return (["-re", "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30", "-vf", CLOCK + ",format=yuv420p"]
                + x264(bitrate) + ["pipe:1"])
    return (["-re", "-f", "lavfi", "-i", BEEP, "-c:a", "aac", "-b:a", "128k", "-vn", "-f", "mp4"] + FRAG
            + ["-frag_duration", "100000", "pipe:1"])


def ffmpeg_filler(track, bitrate):
    if track == 0:
        return (["-f", "lavfi", "-i", "color=c=0x203050:s=1920x1080:r=30", "-t", str(FILLER_SECONDS),
                 "-vf", FILLER_TEXT + ",format=yuv420p"] + x264(bitrate) + ["pipe:1"])
    return (["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo", "-t", str(FILLER_SECONDS), "-c:a", "aac",
             "-b:a", "128k", "-vn", "-f", "mp4"] + FRAG + ["-frag_duration", "100000", "pipe:1"])


# ---------------------------------------------------------------- MP4 boxes

def iter_boxes(read):
    buf = b""
    while True:
        while len(buf) >= 8:
            size, kind = struct.unpack(">I4s", buf[:8])
            if size == 1:
                if len(buf) < 16:
                    break
                size = struct.unpack(">Q", buf[8:16])[0]
            if len(buf) < size:
                break
            yield kind, buf[:size]
            buf = buf[size:]
        chunk = read(65536)
        if not chunk:
            return
        buf += chunk


def split_stream(blob):
    """(init segment, [moof+mdat, ...]) of a fragmented MP4 byte string."""
    init, frags, moof = b"", [], None
    for kind, box in iter_boxes(_reader(blob)):
        if kind in (b"ftyp", b"moov"):
            init += box
        elif kind == b"moof":
            moof = box
        elif kind == b"mdat" and moof is not None:
            frags.append(moof + box)
            moof = None
    return init, frags


def _reader(blob):
    chunks = [blob]
    return lambda n: chunks.pop() if chunks else b""


def children(payload):
    out, i = [], 0
    while i + 8 <= len(payload):
        size, kind = struct.unpack(">I4s", payload[i:i + 8])
        if size < 8:
            break
        out.append((kind, i, payload[i + 8:i + size]))
        i += size
    return out


def tfdt_pos(frag):
    i = frag.find(b"tfdt")
    return i, frag[i + 4]


def get_tfdt(frag):
    i, version = tfdt_pos(frag)
    return struct.unpack(">Q", frag[i + 8:i + 16])[0] if version == 1 else struct.unpack(">I", frag[i + 8:i + 12])[0]


def set_tfdt(frag, value):
    i, version = tfdt_pos(frag)
    if version == 1:
        return frag[:i + 8] + struct.pack(">Q", value) + frag[i + 16:]
    return frag[:i + 8] + struct.pack(">I", value) + frag[i + 12:]


def frag_duration(frag):
    """Sum of sample durations in a moof (track timescale)."""
    moof = children(frag)[0][2]
    traf = next(p for k, _, p in children(moof) if k == b"traf")
    default = 0
    total = 0
    for kind, _, p in children(traf):
        flags = struct.unpack(">I", p[:4])[0] & 0xFFFFFF
        if kind == b"tfhd":
            i = 8 + (8 if flags & 0x01 else 0) + (4 if flags & 0x02 else 0)
            if flags & 0x08:
                default = struct.unpack(">I", p[i:i + 4])[0]
        elif kind == b"trun":
            count = struct.unpack(">I", p[4:8])[0]
            i = 8 + (4 if flags & 0x01 else 0) + (4 if flags & 0x04 else 0)
            per = sum(4 for bit in (0x100, 0x200, 0x400, 0x800) if flags & bit)
            for n in range(count):
                if flags & 0x100:
                    total += struct.unpack(">I", p[i + n * per:i + n * per + 4])[0]
                else:
                    total += default
    return total


# ---------------------------------------------------------------- media sources

class Source:
    """Filler + live fragments for both tracks (ffmpeg), or a recorded sample stream."""

    def __init__(self, bitrate, sample_dir=None):
        self.sample = sample_dir is not None
        self.init, self.filler, self.live = {}, {}, {}
        if self.sample:
            for t, name in ((0, "video"), (1, "audio")):
                init = open(os.path.join(sample_dir, name + ".init"), "rb").read()
                _, frags = split_stream(open(os.path.join(sample_dir, name + ".frags"), "rb").read())
                end = FILLER_SECONDS * TIMESCALE[t]
                self.init[t] = init
                self.filler[t] = [f for f in frags if get_tfdt(f) < end - 1]
                self.live[t] = [f for f in frags if get_tfdt(f) >= end - 1]
            return
        for t in (0, 1):
            blob = subprocess.run(["ffmpeg", "-loglevel", "error", *ffmpeg_filler(t, bitrate)],
                                  stdout=subprocess.PIPE, check=True).stdout
            self.init[t], self.filler[t] = split_stream(blob)
        self.queues = {0: queue.Queue(), 1: queue.Queue()}
        self.procs = []
        for t in (0, 1):
            p = subprocess.Popen(["ffmpeg", "-loglevel", "error", *ffmpeg_live(t, bitrate)], stdout=subprocess.PIPE)
            self.procs.append(p)
            threading.Thread(target=self._read_live, args=(t, p), daemon=True).start()

    def _read_live(self, t, proc):
        moof = None
        for kind, box in iter_boxes(proc.stdout.read1):
            if kind == b"moof":
                moof = box
            elif kind == b"mdat" and moof is not None:
                frag = moof + box
                dur = frag_duration(frag) / TIMESCALE[t]
                # captured: when its first frame was "on screen" (ffmpeg -re emits a fragment after its last frame)
                self.queues[t].put((frag, time.time() - dur))
                moof = None

    def flush(self):
        if not self.sample:
            for q in self.queues.values():
                while not q.empty():
                    q.get_nowait()

    def stop(self):
        for p in getattr(self, "procs", []):
            p.kill()


# ---------------------------------------------------------------- WebSocket + LG remote

def ws_frame(opcode, data, mask=False):
    head = bytearray([0x80 | opcode])
    n = len(data)
    bit = 0x80 if mask else 0
    if n < 126:
        head.append(bit | n)
    elif n < 65536:
        head += bytes([bit | 126]) + struct.pack(">H", n)
    else:
        head += bytes([bit | 127]) + struct.pack(">Q", n)
    if not mask:
        return bytes(head) + data
    key = os.urandom(4)
    return bytes(head) + key + bytes(b ^ key[i % 4] for i, b in enumerate(data))


def ws_read(read):
    b0, b1 = read(2)
    n = b1 & 0x7F
    if n == 126:
        n = struct.unpack(">H", read(2))[0]
    elif n == 127:
        n = struct.unpack(">Q", read(8))[0]
    key = read(4) if b1 & 0x80 else None
    data = read(n)
    if key:
        data = bytes(b ^ key[i % 4] for i, b in enumerate(data))
    return b0 & 0x0F, data


class TVSocket:
    """Client of the TV's control WebSocket (no Origin header: the TV refuses web origins)."""

    def __init__(self, host, path="/"):
        self.sock = socket.create_connection((host, 3000), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((f"GET {path} HTTP/1.1\r\nHost: {host}:3000\r\nUpgrade: websocket\r\n"
                           f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        resp = b""
        while b"\r\n\r\n" not in resp:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise IOError("TV closed the control connection during the handshake")
            resp += chunk
        head, self.buf = resp.split(b"\r\n\r\n", 1)
        if b" 101 " not in head.split(b"\r\n")[0]:
            raise IOError("TV refused the control connection: " + head.decode(errors="replace"))

    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise IOError("TV closed the control connection")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def send_text(self, text):
        self.sock.sendall(ws_frame(0x1, text.encode(), mask=True))

    def recv(self, timeout):
        self.sock.settimeout(timeout)
        while True:
            op, data = ws_read(self._read)
            if op == 0x1:
                return json.loads(data.decode("utf-8", "replace"))
            if op == 0x8:
                raise IOError("TV closed the control connection")
            if op == 0x9:
                self.sock.sendall(ws_frame(0xA, data, mask=True))

    def request(self, rid, uri, payload):
        self.send_text(json.dumps({"type": "request", "id": rid, "uri": uri, "payload": payload}))
        while True:
            msg = self.recv(15)
            if msg.get("id") == rid:
                return msg


class TVRemote:
    def __init__(self, host):
        self.host = host
        self.tv = TVSocket(host)
        register = json.load(open(os.path.join(HERE, "lgtv_register.json"), encoding="utf-8"))
        if os.path.exists(KEY_FILE):
            register["client-key"] = open(KEY_FILE).read().strip()
        self.tv.send_text(json.dumps({"type": "register", "id": "register_0", "payload": register}))
        deadline = time.time() + 60
        while True:
            msg = self.tv.recv(max(1, deadline - time.time()))
            if msg.get("payload", {}).get("pairingType") == "PROMPT":
                print(">>> Accept 'allow this device?' on the TV with the remote")
            elif msg.get("type") == "registered":
                open(KEY_FILE, "w").write(msg["payload"]["client-key"])
                break
            else:
                raise IOError(f"pairing failed: {msg}")

    def open(self, url):
        print("open page ->", self.tv.request("open_1", "ssap://system.launcher/open", {"target": url}).get("type"))

    def click(self):
        msg = self.tv.request("pointer_1", "ssap://com.webos.service.networkinput/getPointerInputSocket", {})
        path = msg.get("payload", {}).get("socketPath", "")
        pointer = TVSocket(self.host, path.split(":3000", 1)[1])
        # The pointer may rest on the browser's own toolbar (a click there reloaded the page once):
        # move to the top-left corner, then to the middle of the screen, then click.
        pointer.send_text("type:move\ndx:-3000\ndy:-3000\ndown:0\n\n")
        time.sleep(0.2)
        pointer.send_text("type:move\ndx:960\ndy:540\ndown:0\n\n")
        time.sleep(0.3)
        pointer.send_text("type:click\n\n")
        print("sent a click for full screen")
        time.sleep(1.5)  # closing the pointer socket at once can drop the click
        pointer.sock.close()


# ---------------------------------------------------------------- one page connection (the phone's job)

class Stats:
    def __init__(self):
        self.delays, self.events = [], collections.Counter()
        self.fullscreen = None


class Session:
    def __init__(self, handler, source, args, stats, remote):
        self.h, self.src, self.args, self.stats, self.remote = handler, source, args, stats, remote
        self.lock = threading.Lock()
        self.lead = START_LEAD
        self.mode = "idle"          # idle / filler / live
        self.next = {0: 0, 1: 0}    # where the next fragment goes on the TV timeline (track units)
        self.splice = {}            # track -> (source tfdt, TV tfdt) of the first live fragment
        self.sent_live = []         # (TV start s, captured wall time) of sent video fragments
        self.closed = False
        self.hold_until = 0.0       # simulated Wi-Fi hiccup: nothing gets through until then

    # --- sending
    def _hold(self):
        wait = self.hold_until - time.time()
        if wait > 0:
            time.sleep(wait)

    def send(self, track, data):
        self._hold()
        with self.lock:
            self.h.wfile.write(ws_frame(0x2, bytes([track]) + data))

    def text(self, obj):
        self._hold()
        with self.lock:
            self.h.wfile.write(ws_frame(0x1, json.dumps(obj).encode()))

    def send_filler(self, at_units):
        """Filler re-timed to start at `at_units` (per track). Returns nothing; updates self.next."""
        for t in (0, 1):
            base = at_units[t]
            first = get_tfdt(self.src.filler[t][0])
            for f in self.src.filler[t]:
                g = set_tfdt(f, get_tfdt(f) - first + base)
                self.send(t, g)
                self.next[t] = get_tfdt(g) + frag_duration(g)

    def start_timeline(self):
        self.text({"type": "config", "lead": self.lead, "video": "avc1.4d4028", "audio": "mp4a.40.2"})
        for t in (0, 1):
            self.send(t, self.src.init[t])
        self.mode = "filler"
        self.splice = {}
        self.sent_live = []
        self.send_filler({0: 0, 1: 0})

    # --- page messages
    def on_message(self, m):
        kind = m.get("type")
        self.stats.events[kind] += 1
        if kind == "hello":
            print(f"[page] hello mse={m.get('mse')} ua={m.get('ua', '')[:60]}")
            if not m.get("mse"):
                print("!!! page says no MSE support")
            self.start_timeline()
            if self.remote:
                threading.Thread(target=self.fullscreen_clicks, daemon=True).start()
        elif kind == "golive":
            print(f"[page] golive v={m.get('v'):.3f} a={m.get('a'):.3f} (phone: v={self.next[0] / 90000:.3f} "
                  f"a={self.next[1] / 48000:.3f})")
            self.src.flush()
            self.splice = {}
            self.mode = "live"
        elif kind == "underrun":
            self.lead = min(MAX_LEAD, self.lead + LEAD_STEP)
            print(f"[page] UNDERRUN at {m.get('pos'):.2f} -> refill, lead {self.lead}")
            self.mode = "filler"
            self.text({"type": "config", "lead": self.lead})
            self.send_filler(dict(self.next))
        elif kind == "stuck":
            print(f"[page] STUCK ({m.get('why')}) -> new timeline")
            self.start_timeline()
        elif kind == "stats":
            self.on_stats(m)
        elif kind == "fullscreen":
            self.stats.fullscreen = m.get("on")
            print(f"[page] fullscreen {m.get('on')}")
        elif kind == "key":
            print(f"[page] key {m.get('code')}")
        elif kind == "error":
            print(f"[page] ERROR {m.get('what')}")

    def fullscreen_clicks(self):
        # Not right away: while the TV browser's own bar still has focus, a click can hit it and reload
        # the page (seen in the first soak run). The spike's click 12 s after opening worked.
        for _ in range(2):
            time.sleep(8)
            if self.stats.fullscreen or self.closed:
                return
            try:
                self.remote.click()
            except Exception as e:  # noqa: BLE001
                print("click failed:", e)

    def on_stats(self, m):
        pos = m.get("pos", 0)
        if self.mode != "live" or not self.sent_live or pos < self.sent_live[0][0]:
            return
        start, captured = max((s for s in self.sent_live if s[0] <= pos), key=lambda s: s[0])
        delay = time.time() - (captured + (pos - start))
        self.stats.delays.append((time.time(), delay))

    # --- live data
    def pump_live(self):
        hiccup_next = time.time() + self.args.hiccup_every if self.args.hiccup_every else None
        while not self.closed:
            if hiccup_next and time.time() >= hiccup_next:
                print(f"--- simulated Wi-Fi hiccup: sending nothing for {self.args.hiccup_seconds}s")
                self.stats.events["hiccup"] += 1
                self.hold_until = time.time() + self.args.hiccup_seconds
                hiccup_next = time.time() + self.args.hiccup_every
            if self.src.sample:
                time.sleep(0.05)
                continue
            sent = False
            for t in (0, 1):
                try:
                    frag, captured = self.src.queues[t].get_nowait()
                except queue.Empty:
                    continue
                if self.mode != "live":
                    continue
                src_t = get_tfdt(frag)
                if t not in self.splice:
                    self.splice[t] = (src_t, self.next[t])
                s0, d0 = self.splice[t]
                out = set_tfdt(frag, src_t - s0 + d0)
                self.send(t, out)
                self.next[t] = get_tfdt(out) + frag_duration(out)
                if t == 0:
                    self.sent_live.append((get_tfdt(out) / 90000, captured))
                    del self.sent_live[:-200]
                sent = True
            if not sent:
                time.sleep(0.005)

    def pump_sample(self):
        """Replay a recorded stream: live fragments paced in real time from the go-live moment."""
        while not self.closed and self.mode != "live":
            time.sleep(0.02)
        if self.closed:
            return
        t0 = time.time()
        frags = sorted([(get_tfdt(f) / TIMESCALE[t], t, f) for t in (0, 1) for f in self.src.live[t]])
        for start, t, f in frags:
            end = start + frag_duration(f) / TIMESCALE[t]
            wait = t0 + (end - FILLER_SECONDS) - time.time()
            if wait > 0:
                time.sleep(wait)
            self.send(t, f)
            if t == 0:
                self.sent_live.append((start, time.time() - (end - start)))
        print("[sample] all fragments sent")


# ---------------------------------------------------------------- HTTP server

def make_handler(source, args, stats, remote):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self):
            if self.path.split("?")[0] == "/ws":
                return self.websocket()
            if self.path.split("?")[0] not in ("/", "/index.html"):
                self.send_error(404)
                return
            body = open(PAGE, "rb").read()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def websocket(self):
            accept = base64.b64encode(hashlib.sha1((self.headers["Sec-WebSocket-Key"] + WS_GUID).encode()).digest())
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", accept.decode())
            self.end_headers()
            self.wfile.flush()
            print(f"[ws] page connected from {self.client_address[0]}")
            session = Session(self, source, args, stats, remote)

            def read_exact(n):
                data = self.rfile.read(n)
                if len(data) < n:
                    raise IOError("closed")
                return data

            def reader():
                try:
                    while True:
                        op, data = ws_read(read_exact)
                        if op == 0x8:
                            break
                        if op == 0x1:
                            session.on_message(json.loads(data))
                except Exception as e:  # noqa: BLE001
                    if not isinstance(e, IOError):
                        print("[ws] reader error:", repr(e))
                finally:
                    session.closed = True

            threading.Thread(target=reader, daemon=True).start()
            try:
                (session.pump_sample if source.sample else session.pump_live)()
                while not session.closed:
                    time.sleep(0.1)
            except OSError:
                pass
            finally:
                session.closed = True
                self.close_connection = True
                print("[ws] page disconnected")

        def log_message(self, fmt, *a):
            pass

    return Handler


def local_ip(towards):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect((towards, 9))
    ip = s.getsockname()[0]
    s.close()
    return ip


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tv", help="TV IP: open the page there over SSAP and click for full screen")
    ap.add_argument("--local", action="store_true", help="just serve; open the page yourself")
    ap.add_argument("--port", type=int, default=8092)
    ap.add_argument("--minutes", type=float, default=1.0)
    ap.add_argument("--bitrate", default="4M")
    ap.add_argument("--hiccup-every", type=float, default=0)
    ap.add_argument("--hiccup-seconds", type=float, default=2)
    ap.add_argument("--sample", help="directory with video.init/.frags and audio.init/.frags from CI")
    args = ap.parse_args()

    print("preparing filler and live sources ...")
    source = Source(args.bitrate, args.sample)
    stats = Stats()
    remote = TVRemote(args.tv) if args.tv else None
    server = ThreadingHTTPServer(("0.0.0.0", args.port), make_handler(source, args, stats, remote))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://{local_ip(args.tv or '8.8.8.8')}:{args.port}/"
    print("page:", url if args.tv else f"http://localhost:{args.port}/")
    if remote:
        remote.open(url)

    end = time.time() + args.minutes * 60
    next_report = time.time() + 10
    try:
        while time.time() < end:
            time.sleep(0.5)
            if time.time() >= next_report:
                recent = [d for t, d in stats.delays if t > time.time() - 10]
                if recent:
                    print(f"=== last 10 s: delay median {statistics.median(recent):.2f}s "
                          f"min {min(recent):.2f} max {max(recent):.2f}")
                next_report += 10
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()
        source.stop()

    delays = sorted(d for _, d in stats.delays)
    print("\n=== summary")
    print("events:", dict(stats.events))
    print("fullscreen:", stats.fullscreen)
    if delays:
        p90 = delays[int(len(delays) * 0.9) - 1] if len(delays) >= 10 else delays[-1]
        print(f"live delay: median {statistics.median(delays):.2f}s, 90% under {p90:.2f}s, "
              f"min {delays[0]:.2f}s, max {delays[-1]:.2f}s ({len(delays)} samples)")
    else:
        print("no live delay samples")
    return 0


if __name__ == "__main__":
    sys.exit(main())
