# Apex agent: prints one JSON snapshot of a Linux server or container.
# Read-only. Apex sends it over SSH each refresh (nothing is installed);
# it can also be run by hand: python3 apex-agent.py
import json, os, platform, shutil, socket, subprocess, time

def read(path, default=""):
    try:
        with open(path) as f:
            return f.read()
    except Exception:
        return default

def run(cmd, timeout=4):
    try:
        # stdout/stderr pipes rather than capture_output: works on Python 3.6 (Ubuntu 18.04, CentOS 7).
        return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=timeout).stdout
    except Exception:
        return ""

def cpu_times():
    cores = []
    for line in read("/proc/stat").splitlines():
        if line.startswith("cpu"):
            parts = line.split()
            vals = [int(v) for v in parts[1:9]]
            idle = vals[3] + vals[4]          # idle + iowait
            cores.append((parts[0], sum(vals), idle))
    return cores

def net_bytes():
    out = {}
    for line in read("/proc/net/dev").splitlines()[2:]:
        name, data = line.split(":", 1)
        f = data.split()
        out[name.strip()] = (int(f[0]), int(f[8]))
    return out

def disk_bytes():
    out = {}
    for line in read("/proc/diskstats").splitlines():
        f = line.split()
        if len(f) >= 14:
            out[f[2]] = (int(f[5]) * 512, int(f[9]) * 512, int(f[12]))   # read bytes, written bytes, ms busy
    return out

# Two readings a second apart for rates.
c1, n1, d1, t1 = cpu_times(), net_bytes(), disk_bytes(), time.time()
time.sleep(1)
c2, n2, d2, t2 = cpu_times(), net_bytes(), disk_bytes(), time.time()
dt = max(0.1, t2 - t1)

def busy(a, b):
    total, idle = b[1] - a[1], b[2] - a[2]
    return round(100.0 * (total - idle) / total, 1) if total > 0 else 0.0

cpu_total = busy(c1[0], c2[0]) if c1 and c2 else 0.0
per_core = [busy(a, b) for a, b in zip(c1[1:], c2[1:])]

mem = {}
for line in read("/proc/meminfo").splitlines():
    k, _, v = line.partition(":")
    parts = v.split()
    if parts:
        mem[k] = int(parts[0]) * 1024

net = []
for name, (rx, tx) in n2.items():
    if name == "lo" or name.startswith(("veth", "docker", "br-")):
        continue
    prx, ptx = n1.get(name, (rx, tx))
    net.append({"name": name, "inPerSec": round((rx - prx) / dt), "outPerSec": round((tx - ptx) / dt), "received": rx, "sent": tx,
                "mac": read("/sys/class/net/%s/address" % name).strip()})

disks = []
for line in run(["df", "-kP", "-x", "tmpfs", "-x", "devtmpfs", "-x", "squashfs"]).splitlines()[1:]:
    f = line.split()
    # Real devices, and a container's own root (overlay on /); not files a container mounts (/etc/hosts).
    if len(f) >= 6 and (f[0].startswith("/") or (f[0] == "overlay" and f[5] == "/")) and not os.path.isfile(f[5]):
        dev = os.path.basename(f[0])
        a, b = d1.get(dev), d2.get(dev)
        r = w = act = 0
        if a and b:
            r, w = (b[0] - a[0]) / dt, (b[1] - a[1]) / dt
            act = min(100.0, (b[2] - a[2]) / (dt * 10))
        disks.append({"device": f[0], "mount": f[5], "total": int(f[1]) * 1024, "used": int(f[2]) * 1024,
                      "free": int(f[3]) * 1024, "readPerSec": round(r), "writePerSec": round(w), "activePercent": round(act, 1)})

procs = []
for line in run(["ps", "-eo", "pid,ppid,user:20,pcpu,pmem,rss,etimes,comm", "--sort=-pcpu", "--no-headers"]).splitlines()[:500]:
    f = line.split(None, 7)
    if len(f) == 8 and os.getpid() not in (int(f[0]), int(f[1])):      # not this script or its own ps
        procs.append({"pid": int(f[0]), "ppid": int(f[1]), "user": f[2], "cpu": float(f[3]), "memPercent": float(f[4]),
                      "memory": int(f[5]) * 1024, "seconds": int(f[6]), "name": f[7]})

gpus = []
if shutil.which("nvidia-smi"):
    for line in run(["nvidia-smi", "--query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu",
                     "--format=csv,noheader,nounits"]).splitlines():
        f = [x.strip() for x in line.split(",")]
        if len(f) == 5:
            gpus.append({"name": f[0], "utilization": float(f[1] or 0), "memoryUsed": int(float(f[2] or 0)) * 1048576,
                         "memoryTotal": int(float(f[3] or 0)) * 1048576, "temperature": float(f[4] or 0)})

containers = []
if shutil.which("docker"):
    states = {}
    for line in run(["docker", "ps", "-a", "--format", "{{json .}}"]).splitlines():
        try:
            c = json.loads(line)
            states[c.get("ID", "")[:12]] = c
        except Exception:
            pass
    stats = {}
    for line in run(["docker", "stats", "--no-stream", "--format", "{{json .}}"], timeout=8).splitlines():
        try:
            s = json.loads(line)
            stats[s.get("ID", "")[:12]] = s
        except Exception:
            pass
    for cid, c in states.items():
        s = stats.get(cid, {})
        containers.append({"id": cid, "name": c.get("Names", ""), "image": c.get("Image", ""), "state": c.get("State", ""),
                           "status": c.get("Status", ""), "cpu": s.get("CPUPerc", ""), "memory": s.get("MemUsage", ""),
                           "net": s.get("NetIO", ""), "block": s.get("BlockIO", "")})

failed = []
if shutil.which("systemctl"):
    for line in run(["systemctl", "list-units", "--type=service", "--state=failed", "--no-legend", "--plain"]).splitlines():
        f = line.split()
        if f:
            failed.append(f[0])

# Every service (for the Services page): name, state, description.
services = []
if shutil.which("systemctl"):
    for line in run(["systemctl", "list-units", "--type=service", "--all", "--no-legend", "--plain", "--no-pager"]).splitlines()[:400]:
        f = line.split(None, 4)
        if len(f) >= 4 and f[0].endswith(".service"):
            services.append({"name": f[0][:-8], "loaded": f[1], "active": f[2], "sub": f[3], "description": f[4] if len(f) > 4 else ""})

# Who's signed in (for the Users page).
sessions = []
for line in run(["who"]).splitlines():
    f = line.split()
    if len(f) >= 2:
        frm = f[-1] if f[-1].startswith("(") else ""
        sessions.append({"user": f[0], "terminal": f[1], "from": frm.strip("()")})

osr = {}
for line in read("/etc/os-release").splitlines():
    k, _, v = line.partition("=")
    osr[k] = v.strip().strip('"')

web = []
for name in ("nginx", "apache2", "httpd", "caddy", "node", "gunicorn", "php-fpm"):
    if any(p["name"].startswith(name) for p in procs):
        web.append(name)
conns = 0
ss = run(["ss", "-Htan", "state", "established"])
if ss:
    conns = len(ss.splitlines())

# Web traffic: the end of the busiest web server's access log (last 1 MB,
# so it stays cheap every refresh), summed over the last 10 minutes.
# nginx / Apache "combined" lines and Caddy's JSON lines.
import re
from datetime import datetime
LOG_CANDIDATES = ["/var/log/nginx/access.log", "/var/log/apache2/access.log", "/var/log/httpd/access_log",
                  "/var/log/caddy/access.log", "/var/log/caddy/caddy.log", "/usr/local/var/log/nginx/access.log"]
COMBINED = re.compile(r'^(\S+) \S+ \S+ \[([^\]]+)\] "(\S+) (\S+)[^"]*" (\d{3}) (\S+)(?: "[^"]*" "([^"]*)")?')
PROBES = ("/wp-login.php", "/xmlrpc.php", "/.env", "/.git", "/phpmyadmin", "/wp-admin", "/admin.php", "/cgi-bin", "/boaform", "/.aws")
BOTS = ("bot", "crawl", "spider", "slurp", "curl", "wget", "python-requests", "go-http-client", "scanner")

def parse_line(line):
    """One access-log line -> (epoch, client, method, path, status, bytes, agent) or None."""
    line = line.strip()
    if line.startswith("{"):
        try:
            j = json.loads(line)
            r = j.get("request", {})
            ua = (r.get("headers", {}).get("User-Agent") or [""])[0]
            return (float(j.get("ts", 0)), r.get("remote_ip") or r.get("client_ip") or r.get("remote_addr", "").rsplit(":", 1)[0],
                    r.get("method", ""), r.get("uri", ""), int(j.get("status", 0)), int(j.get("size", 0)), ua)
        except Exception:
            return None
    m = COMBINED.match(line)
    if not m:
        return None
    try:
        t = datetime.strptime(m.group(2), "%d/%b/%Y:%H:%M:%S %z").timestamp()
    except Exception:
        return None
    size = m.group(6)
    return (t, m.group(1), m.group(3), m.group(4), int(m.group(5)), int(size) if size.isdigit() else 0, m.group(7) or "")

def tail(path, limit=1 << 20):
    with open(path, "rb") as f:
        f.seek(0, 2)
        size = f.tell()
        f.seek(max(0, size - limit))
        data = f.read().decode("utf-8", "replace")
    lines = data.splitlines()
    return lines[1:] if size > limit else lines      # the first line may be cut in half

def summarize(lines, now, window=600):
    """Pure (tested by hand and in CI): the last `window` seconds of requests."""
    reqs = [r for r in (parse_line(l) for l in lines) if r and now - window <= r[0] <= now + 60]
    if not reqs:
        return {"requests": 0, "window": window}
    span = max(60.0, now - min(r[0] for r in reqs))
    statuses = {"2xx": 0, "3xx": 0, "4xx": 0, "5xx": 0}
    paths, clients, errors, notfound, probes = {}, {}, {}, {}, {}
    total_bytes, bots = 0, 0
    for t, ip, method, path, status, size, ua in reqs:
        key = "%dxx" % (status // 100)
        if key in statuses:
            statuses[key] += 1
        clean = path.split("?", 1)[0]
        paths[clean] = paths.get(clean, 0) + 1
        clients[ip] = clients.get(ip, 0) + 1
        total_bytes += size
        if any(b in ua.lower() for b in BOTS):
            bots += 1
        if status >= 500:
            k = "%d %s" % (status, clean)
            errors[k] = errors.get(k, 0) + 1
        if status == 404:
            notfound[ip] = notfound.get(ip, 0) + 1
        if clean.lower().startswith(PROBES):
            probes[ip] = probes.get(ip, 0) + 1
    def top(d, n=5):
        return sorted(d.items(), key=lambda kv: -kv[1])[:n]
    # Clients that look like scanners: many 404s, or asking for well-known attack paths.
    scanners = []
    for ip in set(list(notfound) + list(probes)):
        if notfound.get(ip, 0) >= 20 or probes.get(ip, 0) >= 3:
            scanners.append({"ip": ip, "requests": clients.get(ip, 0), "notFound": notfound.get(ip, 0), "probes": probes.get(ip, 0)})
    scanners.sort(key=lambda s: -(s["notFound"] + s["probes"] * 10))
    return {
        "requests": len(reqs), "window": round(span), "perMinute": round(len(reqs) / span * 60, 1),
        "statuses": statuses, "bytes": total_bytes, "bots": bots,
        "topPaths": [{"path": p, "count": c} for p, c in top(paths)],
        "topClients": [{"ip": ip, "count": c} for ip, c in top(clients)],
        "errors": [{"what": k, "count": c} for k, c in top(errors)],
        "scanners": scanners[:5],
    }

web_traffic = None
logs = [p for p in LOG_CANDIDATES if os.path.isfile(p)]
if logs:
    newest = max(logs, key=lambda p: os.path.getmtime(p))
    try:
        web_traffic = summarize(tail(newest), time.time())
        web_traffic["log"] = newest
        web_traffic["readable"] = True
    except PermissionError:
        web_traffic = {"log": newest, "readable": False, "requests": 0, "window": 600}
    except Exception:
        web_traffic = None

load = read("/proc/loadavg").split()
print(json.dumps({
    "agent": 1,
    "host": socket.gethostname(),
    "os": osr.get("PRETTY_NAME", platform.system()),
    "kernel": platform.release(),
    "inContainer": os.path.exists("/.dockerenv") or "docker" in read("/proc/1/cgroup") or "containerd" in read("/proc/1/cgroup"),
    "uptime": float(read("/proc/uptime", "0 0").split()[0]),
    "cpu": {"total": cpu_total, "perCore": per_core, "cores": len(per_core),
            "model": next((l.split(":", 1)[1].strip() for l in read("/proc/cpuinfo").splitlines() if l.startswith("model name")), ""),
            "load": [float(x) for x in load[:3]] if len(load) >= 3 else []},
    "memory": {"total": mem.get("MemTotal", 0), "available": mem.get("MemAvailable", 0), "cached": mem.get("Cached", 0),
               "swapTotal": mem.get("SwapTotal", 0), "swapFree": mem.get("SwapFree", 0)},
    "disks": disks, "network": net, "processes": procs, "gpus": gpus, "containers": containers,
    "failedServices": failed, "services": services, "sessions": sessions, "webServers": web, "connections": conns,
    "webTraffic": web_traffic,
}))
