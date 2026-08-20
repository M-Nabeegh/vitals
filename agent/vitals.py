#!/usr/bin/env python3
"""
Vitals: a home server dashboard that only works when you are looking at it.

The whole point is the collector's lifecycle. Nothing is sampled, stored or
written to disk until a browser opens the event stream. The moment the last
viewer goes away the sampling loop stops dead, and the process idles at zero.
No time-series database, no cron, no spinning up the NAS platters to record
that nothing happened.

Standard library only. No pip install, on purpose: a monitoring tool you cannot
install on a broken machine is not much use.
"""

from __future__ import annotations

import argparse
import glob
import http.client
import json
import os
import queue
import re
import socket
import subprocess
import socketserver
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))

# Cheap things worth watching move fast; anything that touches a disk does not.
FAST_INTERVAL = 2.0
SLOW_INTERVAL = 60.0

DOCKER_SOCKET = "/var/run/docker.sock"
DOCKER_API = "v1.44"

# Thresholds that turn into alerts. Tuned for a home box, not a datacentre.
DISK_WARN, DISK_CRIT = 80.0, 92.0
MEM_WARN, MEM_CRIT = 85.0, 95.0
TEMP_WARN, TEMP_CRIT = 75.0, 88.0
LOAD_WARN_PER_CORE = 1.5


# ─────────────────────────────────────────────────────────────── host readings


def _read(path: str, default: str = "") -> str:
    try:
        with open(path) as handle:
            return handle.read()
    except OSError:
        return default


class CPUReader:
    """Percentages need two samples, so the reader keeps the previous one."""

    def __init__(self) -> None:
        self._previous: dict[str, tuple[int, int]] = {}

    def read(self) -> dict:
        totals, cores = {}, []
        for line in _read("/proc/stat").splitlines():
            if not line.startswith("cpu"):
                break
            parts = line.split()
            name, values = parts[0], [int(v) for v in parts[1:]]
            idle = values[3] + (values[4] if len(values) > 4 else 0)
            total = sum(values)
            previous = self._previous.get(name)
            self._previous[name] = (total, idle)
            if previous is None:
                percent = 0.0
            else:
                delta_total = total - previous[0]
                delta_idle = idle - previous[1]
                percent = 0.0 if delta_total <= 0 else max(
                    0.0, min(100.0, 100.0 * (delta_total - delta_idle) / delta_total))
            if name == "cpu":
                totals["percent"] = round(percent, 1)
            else:
                cores.append(round(percent, 1))
        totals["cores"] = cores
        totals["count"] = len(cores)
        load = _read("/proc/loadavg").split()[:3]
        totals["load"] = [float(v) for v in load] if len(load) == 3 else [0.0, 0.0, 0.0]
        totals["temp"] = hottest_cpu_temp()
        return totals


def hottest_cpu_temp() -> float | None:
    """The warmest core, which is the one that matters."""
    best = None
    for hwmon in glob.glob("/sys/class/hwmon/hwmon*"):
        name = _read(os.path.join(hwmon, "name")).strip()
        if name not in ("coretemp", "k10temp", "zenpower", "cpu_thermal"):
            continue
        for sensor in glob.glob(os.path.join(hwmon, "temp*_input")):
            try:
                value = int(_read(sensor)) / 1000.0
            except ValueError:
                continue
            if 0 < value < 150 and (best is None or value > best):
                best = value
    if best is None:  # some boards only expose a thermal zone
        for zone in glob.glob("/sys/class/thermal/thermal_zone*"):
            if "x86_pkg_temp" in _read(os.path.join(zone, "type")):
                try:
                    best = int(_read(os.path.join(zone, "temp"))) / 1000.0
                except ValueError:
                    pass
    return round(best, 1) if best is not None else None


def read_memory() -> dict:
    fields = {}
    for line in _read("/proc/meminfo").splitlines():
        key, _, rest = line.partition(":")
        try:
            fields[key] = int(rest.split()[0]) * 1024
        except (IndexError, ValueError):
            continue
    total = fields.get("MemTotal", 0)
    available = fields.get("MemAvailable", 0)
    used = max(0, total - available)
    swap_total = fields.get("SwapTotal", 0)
    swap_used = max(0, swap_total - fields.get("SwapFree", 0))
    return {
        "total": total,
        "used": used,
        "available": available,
        # Against available, not free: cache is not "used" in any way you care about.
        "percent": round(100.0 * used / total, 1) if total else 0.0,
        "cached": fields.get("Cached", 0),
        "swap": {
            "total": swap_total,
            "used": swap_used,
            "percent": round(100.0 * swap_used / swap_total, 1) if swap_total else 0.0,
        },
    }


class NetReader:
    def __init__(self) -> None:
        self._previous: dict[str, tuple[float, int, int]] = {}

    def read(self) -> list[dict]:
        now = time.time()
        interfaces = []
        for line in _read("/proc/net/dev").splitlines()[2:]:
            name, _, rest = line.partition(":")
            name = name.strip()
            if name == "lo" or name.startswith(("veth", "br-", "docker")):
                continue
            values = rest.split()
            if len(values) < 9:
                continue
            received, sent = int(values[0]), int(values[8])
            previous = self._previous.get(name)
            self._previous[name] = (now, received, sent)
            rx_rate = tx_rate = 0.0
            if previous:
                elapsed = now - previous[0]
                if elapsed > 0:
                    rx_rate = max(0.0, (received - previous[1]) / elapsed)
                    tx_rate = max(0.0, (sent - previous[2]) / elapsed)
            interfaces.append({
                "name": name,
                "rx_bytes": received, "tx_bytes": sent,
                "rx_rate": round(rx_rate), "tx_rate": round(tx_rate),
            })
        interfaces.sort(key=lambda i: i["rx_bytes"] + i["tx_bytes"], reverse=True)
        return interfaces[:4]


def read_disks() -> list[dict]:
    """Real filesystems only. Nobody wants to monitor a snap loopback."""
    disks, seen = [], set()
    for line in _read("/proc/mounts").splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        device, mount, fstype = parts[0], parts[1], parts[2]
        if not device.startswith("/dev/") or fstype in ("squashfs", "iso9660"):
            continue
        if device in seen:
            continue
        seen.add(device)
        try:
            stats = os.statvfs(mount)
        except OSError:
            continue
        total = stats.f_blocks * stats.f_frsize
        if total < 1_000_000_000:  # ignore /boot-sized slivers
            continue
        free = stats.f_bavail * stats.f_frsize
        used = total - stats.f_bfree * stats.f_frsize
        disks.append({
            "device": device,
            "mount": mount,
            "fstype": fstype,
            "total": total, "used": used, "free": free,
            "percent": round(100.0 * used / total, 1) if total else 0.0,
        })
    disks.sort(key=lambda d: d["total"], reverse=True)
    return disks


# ────────────────────────────────────────────────────────────────────── S.M.A.R.T.

SMART_ATTRIBUTES = {
    "Reallocated_Sector_Ct": "reallocated",
    "Current_Pending_Sector": "pending",
    "Offline_Uncorrectable": "uncorrectable",
    "Power_On_Hours": "hours",
    "Temperature_Celsius": "temp",
    "Airflow_Temperature_Cel": "temp",
}


def physical_disks() -> list[str]:
    found = []
    for path in sorted(glob.glob("/sys/block/*")):
        name = os.path.basename(path)
        if name.startswith(("loop", "ram", "dm-", "sr", "zram")):
            continue
        if _read(os.path.join(path, "removable")).strip() == "1":
            continue
        found.append(name)
    return found


def read_smart() -> list[dict]:
    """
    Capacity tells you when a disk is full. SMART tells you when it is dying,
    which is the failure you actually cannot recover from.

    Needs root, so it runs through `sudo -n`. If that is not permitted the whole
    section degrades to unavailable rather than breaking the dashboard.
    """
    results = []
    for name in physical_disks():
        device = f"/dev/{name}"
        try:
            proc = subprocess.run(
                ["sudo", "-n", "smartctl", "-H", "-A", device],
                capture_output=True, text=True, timeout=20)
            output = proc.stdout
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            results.append({"device": name, "available": False})
            continue

        if "a password is required" in (proc.stderr or "") or not output.strip():
            results.append({"device": name, "available": False})
            continue

        entry: dict = {"device": name, "available": True, "model": None,
                       "health": None, "temp": None, "hours": None,
                       "reallocated": None, "pending": None, "uncorrectable": None}

        health = re.search(r"overall-health self-assessment test result:\s*(\S+)", output)
        if health:
            entry["health"] = health.group(1)
        elif "SMART Health Status:" in output:
            entry["health"] = output.split("SMART Health Status:")[1].split("\n")[0].strip()

        for line in output.splitlines():
            for attribute, key in SMART_ATTRIBUTES.items():
                if attribute in line:
                    parts = line.split()
                    if len(parts) >= 10:
                        try:
                            value = int(parts[9].split()[0])
                        except ValueError:
                            continue
                        if entry.get(key) is None:
                            entry[key] = value
        entry["model"] = _read(f"/sys/block/{name}/device/model").strip() or None
        entry["rotational"] = _read(f"/sys/block/{name}/queue/rotational").strip() == "1"
        results.append(entry)
    return results


# ───────────────────────────────────────────────────────────────────── containers


class DockerClient:
    """Just enough Docker API to avoid depending on the whole SDK."""

    def __init__(self, path: str = DOCKER_SOCKET) -> None:
        self.path = path
        self.available = os.path.exists(path)

    def _request(self, route: str, timeout: float = 8.0):
        connection = http.client.HTTPConnection("localhost", timeout=timeout)

        def connect() -> None:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(timeout)
            sock.connect(self.path)
            connection.sock = sock

        connection.connect = connect  # type: ignore[method-assign]
        try:
            connection.request("GET", route)
            response = connection.getresponse()
            if response.status != 200:
                return None
            return json.loads(response.read() or b"null")
        except (OSError, ValueError, http.client.HTTPException):
            return None
        finally:
            try:
                connection.close()
            except OSError:
                pass

    def containers(self) -> list[dict]:
        raw = self._request(f"/{DOCKER_API}/containers/json?all=true")
        return raw if isinstance(raw, list) else []

    def stats(self, container_id: str) -> dict | None:
        raw = self._request(
            f"/{DOCKER_API}/containers/{container_id}/stats?stream=false&one-shot=true")
        return raw if isinstance(raw, dict) else None


def _container_cpu_percent(stats: dict) -> float:
    try:
        cpu, previous = stats["cpu_stats"], stats["precpu_stats"]
        delta = cpu["cpu_usage"]["total_usage"] - previous["cpu_usage"].get("total_usage", 0)
        system = cpu.get("system_cpu_usage", 0) - previous.get("system_cpu_usage", 0)
        count = cpu.get("online_cpus") or len(
            cpu["cpu_usage"].get("percpu_usage") or []) or 1
        if delta > 0 and system > 0:
            return round(100.0 * delta / system * count, 2)
    except (KeyError, TypeError, ZeroDivisionError):
        pass
    return 0.0


def read_containers(client: DockerClient) -> list[dict]:
    if not client.available:
        return []
    raw = client.containers()
    if not raw:
        return []

    results: list[dict] = []
    lock = threading.Lock()

    def collect(entry: dict) -> None:
        name = (entry.get("Names") or ["/?"])[0].lstrip("/")
        state = entry.get("State", "unknown")
        status = entry.get("Status", "")
        health = None
        match = re.search(r"\((healthy|unhealthy|health: starting)\)", status)
        if match:
            health = match.group(1).replace("health: ", "")

        record = {
            "id": entry.get("Id", "")[:12],
            "name": name,
            "image": (entry.get("Image") or "").split("@")[0],
            "state": state,
            "health": health,
            "status": status,
            "created": entry.get("Created"),
            "cpu": 0.0, "mem": 0, "mem_limit": 0, "mem_percent": 0.0,
        }
        if state == "running":
            stats = client.stats(entry.get("Id", ""))
            if stats:
                record["cpu"] = _container_cpu_percent(stats)
                memory = stats.get("memory_stats") or {}
                usage = memory.get("usage", 0)
                # Docker counts page cache in usage; subtracting it matches `docker stats`.
                cache = (memory.get("stats") or {}).get("inactive_file", 0)
                usage = max(0, usage - cache)
                limit = memory.get("limit", 0)
                record["mem"] = usage
                record["mem_limit"] = limit
                record["mem_percent"] = round(100.0 * usage / limit, 2) if limit else 0.0
        with lock:
            results.append(record)

    threads = [threading.Thread(target=collect, args=(entry,), daemon=True)
               for entry in raw]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=10)

    order = {"running": 0, "restarting": 1, "paused": 2, "exited": 3, "created": 4}
    results.sort(key=lambda c: (order.get(c["state"], 9), c["name"].lower()))
    return results


# ─────────────────────────────────────────────────────────────────────── alerts


def build_alerts(snapshot: dict) -> list[dict]:
    """
    Anything that needs a human. Kept deliberately short: a dashboard that cries
    wolf about a disk at 81% gets ignored when a disk actually fails.
    """
    alerts: list[dict] = []

    def add(level: str, subject: str, message: str) -> None:
        alerts.append({"level": level, "subject": subject, "message": message})

    for container in snapshot.get("containers", []):
        name = container["name"]
        if container["health"] == "unhealthy":
            add("critical", name, "Health check failing")
        elif container["state"] == "restarting":
            add("critical", name, "Stuck restarting")
        elif container["state"] == "exited":
            code = re.search(r"\((\d+)\)", container.get("status", ""))
            if code and code.group(1) != "0":
                add("warning", name, f"Exited with code {code.group(1)}")

    for disk in snapshot.get("disks", []):
        percent = disk["percent"]
        if percent >= DISK_CRIT:
            add("critical", disk["mount"], f"{percent:.0f}% full")
        elif percent >= DISK_WARN:
            add("warning", disk["mount"], f"{percent:.0f}% full")

    for disk in snapshot.get("smart", []):
        if not disk.get("available"):
            continue
        device = disk["device"]
        if disk.get("health") and disk["health"].upper() not in ("PASSED", "OK"):
            add("critical", device, f"SMART health {disk['health']}")
        for key, label in (("reallocated", "reallocated sectors"),
                           ("pending", "pending sectors"),
                           ("uncorrectable", "uncorrectable sectors")):
            value = disk.get(key)
            if isinstance(value, int) and value > 0:
                add("critical" if key != "reallocated" else "warning",
                    device, f"{value} {label}")

    memory = snapshot.get("memory", {})
    if memory.get("percent", 0) >= MEM_CRIT:
        add("critical", "Memory", f"{memory['percent']:.0f}% used")
    elif memory.get("percent", 0) >= MEM_WARN:
        add("warning", "Memory", f"{memory['percent']:.0f}% used")

    cpu = snapshot.get("cpu", {})
    temp = cpu.get("temp")
    if isinstance(temp, (int, float)):
        if temp >= TEMP_CRIT:
            add("critical", "CPU temperature", f"{temp:.0f}°C")
        elif temp >= TEMP_WARN:
            add("warning", "CPU temperature", f"{temp:.0f}°C")

    cores = cpu.get("count") or 1
    load = (cpu.get("load") or [0])[0]
    if load > LOAD_WARN_PER_CORE * cores:
        add("warning", "Load average", f"{load:.2f} across {cores} cores")

    order = {"critical": 0, "warning": 1}
    alerts.sort(key=lambda a: order.get(a["level"], 9))
    return alerts


# ────────────────────────────────────────────────────────────────── the collector


class Collector:
    """
    Reference counted. The sampling thread exists only while somebody is
    subscribed; the moment the count hits zero it is torn down and the process
    goes back to doing nothing at all.
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._subscribers: set[queue.Queue] = set()
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()
        self._cpu = CPUReader()
        self._net = NetReader()
        self._docker = DockerClient()
        self._slow_cache: dict = {"disks": [], "smart": [], "at": 0.0}
        self.started_at = time.time()
        self.samples_taken = 0
        self.woke_count = 0

    # -- subscriber bookkeeping

    def subscribe(self) -> queue.Queue:
        channel: queue.Queue = queue.Queue(maxsize=8)
        with self._lock:
            self._subscribers.add(channel)
            if self._thread is None or not self._thread.is_alive():
                self._stop.clear()
                self.woke_count += 1
                self._thread = threading.Thread(target=self._run, daemon=True,
                                                name="collector")
                self._thread.start()
        return channel

    def unsubscribe(self, channel: queue.Queue) -> None:
        with self._lock:
            self._subscribers.discard(channel)
            if not self._subscribers:
                self._stop.set()  # nobody watching: stop sampling entirely

    @property
    def viewers(self) -> int:
        with self._lock:
            return len(self._subscribers)

    @property
    def awake(self) -> bool:
        return self._thread is not None and self._thread.is_alive()

    # -- sampling

    def _slow_metrics(self, force: bool = False) -> dict:
        now = time.time()
        if force or now - self._slow_cache["at"] >= SLOW_INTERVAL:
            self._slow_cache = {
                "disks": read_disks(),
                "smart": read_smart(),
                "at": now,
            }
        return self._slow_cache

    def snapshot(self, force_slow: bool = False, standalone: bool = False) -> dict:
        """
        `standalone` is for one-shot API calls made while the collector is
        asleep. Rates need two readings, and borrowing the shared counters would
        both report the average since the last sample and corrupt the deltas for
        anyone currently watching, so a lone request gets its own pair.
        """
        if standalone:
            cpu_reader, net_reader = CPUReader(), NetReader()
            cpu_reader.read()
            net_reader.read()
            time.sleep(0.25)
        else:
            cpu_reader, net_reader = self._cpu, self._net

        slow = self._slow_metrics(force=force_slow)
        snapshot = {
            "at": time.time(),
            "host": host_facts(),
            "cpu": cpu_reader.read(),
            "memory": read_memory(),
            "network": net_reader.read(),
            "disks": slow["disks"],
            "smart": slow["smart"],
            "containers": read_containers(self._docker),
            "agent": {
                "viewers": self.viewers,
                "samples": self.samples_taken,
                "wakes": self.woke_count,
                "docker": self._docker.available,
            },
        }
        snapshot["alerts"] = build_alerts(snapshot)
        return snapshot

    def _run(self) -> None:
        # First sample primes the CPU/network deltas; percentages need two reads.
        self._cpu.read()
        self._net.read()
        while not self._stop.wait(FAST_INTERVAL):
            try:
                payload = self.snapshot()
            except Exception as error:  # a bad reading must not kill the loop
                payload = {"at": time.time(), "error": str(error)}
            self.samples_taken += 1
            with self._lock:
                channels = list(self._subscribers)
            for channel in channels:
                try:
                    channel.put_nowait(payload)
                except queue.Full:
                    pass  # a stalled client is dropped, never blocks the others


# ───────────────────────────────────────────────────────────────────── http layer


def host_facts() -> dict:
    pretty = ""
    for line in _read("/etc/os-release").splitlines():
        if line.startswith("PRETTY_NAME="):
            pretty = line.split("=", 1)[1].strip().strip('"')
    uptime = 0.0
    try:
        uptime = float(_read("/proc/uptime").split()[0])
    except (IndexError, ValueError):
        pass
    return {
        "hostname": socket.gethostname(),
        "os": pretty,
        "kernel": os.uname().release,
        "uptime": uptime,
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "Vitals"
    protocol_version = "HTTP/1.1"
    collector: Collector
    token: str | None

    def log_message(self, fmt: str, *args) -> None:  # quieter than the default
        if os.environ.get("VITALS_VERBOSE"):
            super().log_message(fmt, *args)

    # -- helpers

    def _authorised(self) -> bool:
        if not self.token:
            return True
        header = self.headers.get("Authorization", "")
        if header.startswith("Bearer ") and header[7:] == self.token:
            return True
        query = self.path.partition("?")[2]
        return f"token={self.token}" in query

    def _send(self, code: int, body: bytes, content_type: str,
              extra: dict | None = None) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def _json(self, payload, code: int = 200) -> None:
        self._send(code, json.dumps(payload).encode(), "application/json")

    # -- routes

    def do_GET(self) -> None:  # noqa: N802
        route = self.path.partition("?")[0]

        if route in ("/", "/index.html"):
            page = os.path.join(HERE, "dashboard.html")
            try:
                with open(page, "rb") as handle:
                    body = handle.read()
            except OSError:
                self._send(500, b"dashboard.html missing next to vitals.py",
                           "text/plain; charset=utf-8")
                return
            self._send(200, body, "text/html; charset=utf-8")
            return

        if route == "/healthz":
            self._json({"ok": True, "awake": self.collector.awake,
                        "viewers": self.collector.viewers})
            return

        if not self._authorised():
            self._json({"error": "unauthorised"}, code=401)
            return

        if route == "/api/snapshot":
            self._json(self.collector.snapshot(
                force_slow=True, standalone=not self.collector.awake))
            return

        if route == "/events":
            self._stream()
            return

        self._send(404, b"not found", "text/plain; charset=utf-8")

    def _stream(self) -> None:
        """
        Server-sent events. One-way, reconnects on its own, and survives the
        reverse proxies people put in front of a home server. The connection
        being open is the entire signal that anyone wants this data.
        """
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "keep-alive")
        self.send_header("X-Accel-Buffering", "no")  # nginx would buffer it away
        self.end_headers()

        channel = self.collector.subscribe()
        try:
            self._emit("hello", {"interval": FAST_INTERVAL,
                                 "slow_interval": SLOW_INTERVAL})
            # Paint immediately rather than making the viewer wait a full tick.
            self._emit("sample", self.collector.snapshot(force_slow=True))
            while True:
                try:
                    payload = channel.get(timeout=20)
                except queue.Empty:
                    self.wfile.write(b": keepalive\n\n")  # keeps idle proxies open
                    self.wfile.flush()
                    continue
                self._emit("sample", payload)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass  # the tab was closed, which is a completely normal way to end
        finally:
            self.collector.unsubscribe(channel)

    def _emit(self, event: str, payload) -> None:
        body = json.dumps(payload, separators=(",", ":"))
        self.wfile.write(f"event: {event}\ndata: {body}\n\n".encode())
        self.wfile.flush()


class InheritedServer(ThreadingHTTPServer):
    """
    A server for a socket somebody else already opened.

    Under socket activation systemd binds the port, then starts this process
    only when a connection actually arrives and hands the listener over. The
    normal constructor would try to bind a second time, so this one skips
    straight past bind and listen.
    """

    def __init__(self, fd: int, handler) -> None:
        socketserver.BaseServer.__init__(self, ("", 0), handler)
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM, fileno=fd)
        self.server_address = self.socket.getsockname()


def systemd_socket_fd() -> int | None:
    """systemd hands listeners over starting at fd 3, per sd_listen_fds(3)."""
    try:
        if int(os.environ.get("LISTEN_PID", 0)) not in (0, os.getpid()):
            return None
        count = int(os.environ.get("LISTEN_FDS", 0))
    except ValueError:
        return None
    if count >= 1:
        return 3
    return 0 if not sys.stdin.isatty() else None


def watch_for_idle(collector: Collector, seconds: float) -> None:
    """
    Exit once nobody has watched for a while.

    Only useful under socket activation, where systemd keeps the port open and
    will start a fresh process the next time somebody opens the dashboard. The
    machine goes back to running no agent at all.
    """
    idle_since: float | None = time.time()

    def loop() -> None:
        nonlocal idle_since
        while True:
            time.sleep(5)
            if collector.viewers > 0:
                idle_since = None
                continue
            if idle_since is None:
                idle_since = time.time()
            elif time.time() - idle_since >= seconds:
                print(f"idle {seconds:.0f}s, exiting; systemd will restart on demand")
                os._exit(0)

    threading.Thread(target=loop, daemon=True, name="idle-watch").start()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8321)
    parser.add_argument("--token", default=os.environ.get("VITALS_TOKEN"),
                        help="require ?token=… or a bearer header")
    parser.add_argument("--systemd-socket", action="store_true",
                        help="serve on the socket systemd passed in")
    parser.add_argument("--idle-exit", type=float, default=0,
                        help="exit after N seconds with no viewers (0 disables)")
    arguments = parser.parse_args()

    Handler.collector = Collector()
    Handler.token = arguments.token

    if arguments.systemd_socket:
        fd = systemd_socket_fd()
        if fd is None:
            parser.error("--systemd-socket but systemd passed no listener")
        server = InheritedServer(fd, Handler)
        where = f"inherited socket fd {fd}"
    else:
        server = ThreadingHTTPServer((arguments.host, arguments.port), Handler)
        where = f"http://{arguments.host}:{arguments.port}"

    server.daemon_threads = True
    if arguments.idle_exit > 0:
        watch_for_idle(Handler.collector, arguments.idle_exit)

    guard = "token required" if arguments.token else "open, no token"
    print(f"vitals on {where}  ({guard})")
    print("idle until a browser connects; sampling stops when the last one leaves")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    main()
