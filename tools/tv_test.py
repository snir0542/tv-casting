#!/usr/bin/env python3
"""
TV Mirror - DLNA test for the LG TV (stdlib only + ffmpeg in PATH).

  python tv_test.py discover            # find the TV and print its AVTransport control URL
  python tv_test.py play                # stream a live test pattern (with a clock) to the TV
  python tv_test.py play --desktop      # stream the PC screen instead
  python tv_test.py play --tv 192.168.1.50   # if multicast discovery finds nothing
"""
import argparse
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from xml.sax.saxutils import escape

AVT = "urn:schemas-upnp-org:service:AVTransport:1"
DLNA_FEATURES = "DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"
PROTOCOL_INFO = "http-get:*:video/mpeg:" + DLNA_FEATURES
NS = {"d": "urn:schemas-upnp-org:device-1-0"}


# ---------- discovery ----------
def ssdp_search(tv_ip=None, timeout=3.0):
    msg = (
        "M-SEARCH * HTTP/1.1\r\n"
        "HOST: 239.255.255.250:1900\r\n"
        'MAN: "ssdp:discover"\r\n'
        "MX: 2\r\n"
        f"ST: {AVT}\r\n\r\n"
    ).encode()
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    s.settimeout(0.5)
    s.sendto(msg, (tv_ip, 1900) if tv_ip else ("239.255.255.250", 1900))
    found = {}
    end = time.time() + timeout
    while time.time() < end:
        try:
            data, addr = s.recvfrom(65507)
        except socket.timeout:
            continue
        m = re.search(rb"(?im)^location:\s*(\S+)", data)
        if m:
            found[m.group(1).decode()] = addr[0]
    s.close()
    return found


def read_renderer(location):
    root = ET.fromstring(urllib.request.urlopen(location, timeout=5).read())
    name = root.findtext(".//d:friendlyName", default="?", namespaces=NS)
    base = root.findtext("d:URLBase", default=location, namespaces=NS)
    for svc in root.iterfind(".//d:service", NS):
        stype = svc.findtext("d:serviceType", default="", namespaces=NS)
        if stype.startswith("urn:schemas-upnp-org:service:AVTransport"):
            ctrl = svc.findtext("d:controlURL", default="", namespaces=NS)
            return name, urllib.parse.urljoin(base, ctrl), stype
    return name, None, None


def find_renderers(tv_ip=None):
    out = []
    for loc, ip in ssdp_search(tv_ip).items():
        try:
            name, ctrl, stype = read_renderer(loc)
        except Exception as e:  # noqa: BLE001
            print(f"  ! {ip}: could not read {loc}: {e}")
            continue
        if ctrl:
            out.append({"name": name, "ip": ip, "control": ctrl, "service": stype})
    return out


# ---------- SOAP ----------
def soap(control, service, action, args):
    arg_xml = "".join(f"<{k}>{escape(v)}</{k}>" for k, v in args)
    body = (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        f'<s:Body><u:{action} xmlns:u="{service}">{arg_xml}</u:{action}></s:Body></s:Envelope>'
    ).encode()
    req = urllib.request.Request(control, data=body, method="POST", headers={
        "Content-Type": 'text/xml; charset="utf-8"',
        "SOAPAction": f'"{service}#{action}"',
    })
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, r.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")
    except Exception as e:  # noqa: BLE001
        return -1, str(e)


def didl(url, title="TV Mirror test"):
    return (
        '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
        f'<item id="0" parentID="-1" restricted="1"><dc:title>{escape(title)}</dc:title>'
        "<upnp:class>object.item.videoItem</upnp:class>"
        f'<res protocolInfo="{PROTOCOL_INFO}">{escape(url)}</res></item></DIDL-Lite>'
    )


# ---------- streaming ----------
def ffmpeg_cmd(desktop, silent_audio):
    if desktop:
        if sys.platform.startswith("win"):
            src = ["-f", "gdigrab", "-framerate", "30", "-i", "desktop"]
        elif sys.platform == "darwin":
            src = ["-f", "avfoundation", "-framerate", "30", "-i", "1:none"]
        else:
            src = ["-f", "x11grab", "-framerate", "30", "-i", ":0.0"]
    else:
        src = ["-re", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30"]
    audio = ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo", "-c:a", "aac", "-shortest"] if silent_audio else ["-an"]
    return ["ffmpeg", "-loglevel", "warning", *src, *audio,
            "-vf", "scale=1280:-2,format=yuv420p",
            "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
            "-profile:v", "main", "-level", "4.0", "-g", "30", "-b:v", "4M",
            "-f", "mpegts", "pipe:1"]


def make_handler(cmd):
    class StreamHandler(BaseHTTPRequestHandler):
        def _headers(self):
            self.send_response(200)
            self.send_header("Content-Type", "video/mpeg")
            self.send_header("transferMode.dlna.org", "Streaming")
            self.send_header("contentFeatures.dlna.org", DLNA_FEATURES)
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()

        def do_HEAD(self):
            self._headers()

        def do_GET(self):
            self._headers()
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)
            try:
                while True:
                    chunk = proc.stdout.read1(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                pass
            finally:
                proc.kill()
                print(f"[http] {self.client_address[0]} disconnected")

        def log_message(self, fmt, *a):
            print(f"[http] {self.client_address[0]} {fmt % a}")
    return StreamHandler


def local_ip_towards(ip):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect((ip, 9))
    me = s.getsockname()[0]
    s.close()
    return me


# ---------- commands ----------
def cmd_discover(args):
    print("Searching for DLNA renderers...")
    rs = find_renderers(args.tv)
    if not rs:
        print("Nothing found. Is the TV on? Same network? Try: --tv <TV_IP>")
        return 1
    for r in rs:
        print(f"\n  {r['name']}  ({r['ip']})\n  control URL: {r['control']}\n  service:     {r['service']}")
    print("\nPut the control URL into Shared/Config.swift -> tvControlURL")
    return 0


def cmd_play(args):
    rs = find_renderers(args.tv)
    if not rs:
        print("TV not found. Try: --tv <TV_IP>")
        return 1
    tv = rs[0]
    me = local_ip_towards(tv["ip"])
    url = f"http://{me}:{args.port}/test.ts"
    print(f"TV: {tv['name']} ({tv['ip']})\nStream: {url}")

    server = ThreadingHTTPServer(("0.0.0.0", args.port), make_handler(ffmpeg_cmd(args.desktop, args.silent_audio)))
    threading.Thread(target=server.serve_forever, daemon=True).start()

    soap(tv["control"], tv["service"], "Stop", [("InstanceID", "0")])
    code, body = soap(tv["control"], tv["service"], "SetAVTransportURI",
                      [("InstanceID", "0"), ("CurrentURI", url), ("CurrentURIMetaData", didl(url))])
    print(f"SetAVTransportURI -> {code}" + ("" if code == 200 else f"\n{body}"))
    time.sleep(0.5)
    code, body = soap(tv["control"], tv["service"], "Play", [("InstanceID", "0"), ("Speed", "1")])
    print(f"Play -> {code}" + ("" if code == 200 else f"\n{body}"))
    print("\nWatch the TV. Ctrl+C to stop.")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        soap(tv["control"], tv["service"], "Stop", [("InstanceID", "0")])
        server.shutdown()
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("command", choices=["discover", "play"])
    p.add_argument("--tv", help="TV IP (unicast discovery)")
    p.add_argument("--port", type=int, default=8090)
    p.add_argument("--desktop", action="store_true", help="stream the PC screen instead of a test pattern")
    p.add_argument("--silent-audio", action="store_true", help="add a silent audio track (if the TV refuses video-only)")
    a = p.parse_args()
    sys.exit(cmd_discover(a) if a.command == "discover" else cmd_play(a))


if __name__ == "__main__":
    main()
