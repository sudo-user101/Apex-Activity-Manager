# Apex Docker Management over SSH: sent on standard input with the request
# in its first line (APEX_REQ, base64 JSON), the answer as JSON on standard output.
# The same requests and answers as Apex Server Edition's /api/docker (Go):
# read from the Docker socket; stacks use `docker compose` with the folder
# and files Docker recorded for them (or Dockge's stacks folder), never a
# path from the request. Nothing is installed on the server.
import base64, http.client, json, os, re, socket, subprocess, sys, urllib.parse

SAFE = re.compile(r"^[A-Za-z0-9@._:+-]{1,200}$")
COMPOSE_NAMES = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]
MANAGERS = [("portainer/portainer", "Portainer", "https", 9443), ("portainer/agent", "Portainer Agent", "", 0),
            ("louislam/dockge", "Dockge", "http", 5001), ("selfhostedpro/yacht", "Yacht", "http", 8000),
            ("komodo", "Komodo", "http", 9120), ("dockpeek", "Dockpeek", "http", 3420)]


class Err(Exception):
    pass


def sock_path():
    for p in ("/var/run/docker.sock", "/run/docker.sock", "/run/podman/podman.sock"):
        if os.path.exists(p):
            return p
    return None


class UnixConn(http.client.HTTPConnection):
    def __init__(self, path, timeout):
        super().__init__("docker", timeout=timeout)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.path)


def api(method, path, timeout=30, raw=False):
    p = sock_path()
    if not p:
        raise Err("Docker isn't installed or running on this server")
    c = UnixConn(p, timeout)
    try:
        c.request(method, path)
    except PermissionError:
        raise Err("PERMISSION")
    r = c.getresponse()
    body = r.read(64 << 20)
    if r.status >= 300 and r.status != 304:
        try:
            msg = json.loads(body).get("message") or r.reason
        except Exception:
            msg = r.reason
        raise Err(msg)
    if raw:
        return body
    return json.loads(body) if body else None


def compose_cmd():
    for cmd in (["docker", "compose"], ["docker-compose"]):
        try:
            if subprocess.run(cmd + ["version"], capture_output=True, timeout=10).returncode == 0:
                return cmd
        except Exception:
            pass
    return None


def host_path(inspect, p):
    best, src = "", ""
    for m in inspect.get("Mounts") or []:
        d = m.get("Destination", "")
        if (p == d or p.startswith(d.rstrip("/") + "/")) and len(d) > len(best):
            best, src = d, m.get("Source", "")
    return os.path.join(src, p[len(best):].lstrip("/")) if best else ""


def name_of(c):
    return (c.get("Names") or ["/"])[0].lstrip("/")


def managers(cs):
    out = []
    for c in cs:
        img = (c.get("Image") or "").lower()
        for word, name, scheme, port in MANAGERS:
            if word not in img:
                continue
            m = {"name": name, "container": name_of(c), "running": c.get("State") == "running"}
            for p in c.get("Ports") or []:
                if port and p.get("PrivatePort") in (port, 9000 if name == "Portainer" else -1) and p.get("PublicPort"):
                    m["url"] = "%s://:%d" % ("http" if p.get("PrivatePort") == 9000 else scheme, p["PublicPort"])
                    if p.get("PrivatePort") == port:
                        break
            out.append(m)
            break
    return out


def dockge_dir(cs):
    for c in cs:
        if "louislam/dockge" in (c.get("Image") or "").lower():
            ins = api("GET", "/containers/%s/json" % c["Id"])
            d = "/opt/stacks"
            for e in (ins.get("Config") or {}).get("Env") or []:
                if e.startswith("DOCKGE_STACKS_DIR="):
                    d = e.split("=", 1)[1]
            return host_path(ins, d) or d
    return ""


def portainer_data(cs):
    for c in cs:
        if "portainer/portainer" in (c.get("Image") or "").lower():
            return host_path(api("GET", "/containers/%s/json" % c["Id"]), "/data")
    return ""


def stacks(cs):
    dockge, portainer = dockge_dir(cs), portainer_data(cs)
    by, order = {}, []
    for c in cs:
        lb = c.get("Labels") or {}
        p = lb.get("com.docker.compose.project")
        if not p:
            continue
        if p not in by:
            files = [f.strip() for f in lb.get("com.docker.compose.project.config_files", "").split(",") if f.strip()]
            by[p] = {"name": p, "manager": "compose", "dir": lb.get("com.docker.compose.project.working_dir", ""), "files": files, "total": 0, "running": 0}
            order.append(p)
        by[p]["total"] += 1
        if c.get("State") == "running":
            by[p]["running"] += 1
    if dockge and os.path.isdir(dockge):
        for e in sorted(os.listdir(dockge)):
            if e in by or not os.path.isdir(os.path.join(dockge, e)):
                continue
            for n in COMPOSE_NAMES:
                f = os.path.join(dockge, e, n)
                if os.path.isfile(f):
                    by[e] = {"name": e, "manager": "compose", "dir": os.path.join(dockge, e), "files": [f], "total": 0, "running": 0}
                    order.append(e)
                    break
    out = []
    for n in order:
        s = by[n]
        if dockge and s["dir"].startswith(dockge.rstrip("/") + "/"):
            s["manager"] = "dockge"
        elif s["dir"].startswith("/data/compose/") and portainer:
            s["manager"] = "portainer"
        s["editable"] = s["manager"] != "portainer" and bool(s["files"]) and os.path.isfile(s["files"][0])
        out.append(s)
    return sorted(out, key=lambda s: s["name"])


def stats_for(cs):
    out = {}
    for c in cs:
        if c.get("State") != "running":
            continue
        try:
            st = api("GET", "/containers/%s/stats?stream=false" % c["Id"], timeout=6)
            cpu = st["cpu_stats"]["cpu_usage"]["total_usage"] - st["precpu_stats"]["cpu_usage"]["total_usage"]
            sysd = st["cpu_stats"].get("system_cpu_usage", 0) - st["precpu_stats"].get("system_cpu_usage", 0)
            n = st["cpu_stats"].get("online_cpus") or 1
            mem = st["memory_stats"].get("usage", 0) - (st["memory_stats"].get("stats") or {}).get("inactive_file", 0)
            lim = st["memory_stats"].get("limit", 0)
            out[c["Id"]] = ("%.2f%%" % (cpu / sysd * n * 100 if sysd > 0 else 0), "%s / %s" % (mib(mem), mib(lim)))
        except Exception:
            pass
    return out


def mib(b):
    return "%.1fMiB" % (b / 1048576) if b < 1 << 30 else "%.2fGiB" % (b / (1 << 30))


def to_container(c, st):
    d = {"id": c["Id"], "name": name_of(c), "image": c.get("Image", ""), "imageId": c.get("ImageID", ""), "state": c.get("State", ""),
         "status": c.get("Status", ""), "created": c.get("Created", 0), "ports": [], "networks": sorted((c.get("NetworkSettings") or {}).get("Networks") or {}),
         "volumes": [m["Name"] for m in c.get("Mounts") or [] if m.get("Type") == "volume" and m.get("Name")]}
    lb = c.get("Labels") or {}
    if lb.get("com.docker.compose.project"):
        d["project"], d["service"] = lb["com.docker.compose.project"], lb.get("com.docker.compose.service", "")
    for p in c.get("Ports") or []:
        if p.get("PublicPort"):
            ip = p.get("IP", "")
            ip = "" if ip in ("", "0.0.0.0", "::") else ip + ":"
            s = "%s%d→%d/%s" % (ip, p["PublicPort"], p["PrivatePort"], p.get("Type", "tcp"))
            if s not in d["ports"]:
                d["ports"].append(s)
    if c["Id"] in st:
        d["cpu"], d["memory"] = st[c["Id"]]
    return d


def listing():
    rep = {"available": False, "compose": False, "managers": [], "containers": [], "stacks": [], "images": [], "volumes": [], "networks": []}
    try:
        rep["version"] = api("GET", "/version").get("Version", "")
    except Err as e:
        if str(e) == "PERMISSION":
            raise
        rep["problem"] = str(e)
        return rep
    rep["available"], rep["compose"] = True, compose_cmd() is not None
    cs = api("GET", "/containers/json?all=1") or []
    st = stats_for(cs)
    rep["containers"] = sorted((to_container(c, st) for c in cs), key=lambda c: c["name"])
    rep["managers"], rep["stacks"] = managers(cs), stacks(cs)
    for im in api("GET", "/images/json") or []:
        rep["images"].append({"id": im["Id"], "tags": [t for t in im.get("RepoTags") or [] if t != "<none>:<none>"], "size": im.get("Size", 0),
                              "created": im.get("Created", 0), "usedBy": [c["name"] for c in rep["containers"] if c["imageId"] == im["Id"]]})
    rep["images"].sort(key=lambda i: -i["size"])
    for v in (api("GET", "/volumes") or {}).get("Volumes") or []:
        n = v["Name"]
        rep["volumes"].append({"name": n, "driver": v.get("Driver", ""), "mountpoint": v.get("Mountpoint", ""),
                               "usedBy": [c["name"] for c in rep["containers"] if n in c["volumes"]],
                               "anonymous": bool((v.get("Labels") or {}).get("com.docker.volume.anonymous")) or bool(re.fullmatch(r"[0-9a-f]{64}", n))})
    rep["volumes"].sort(key=lambda v: v["name"])
    for n in api("GET", "/networks") or []:
        rep["networks"].append({"id": n["Id"], "name": n["Name"], "driver": n.get("Driver", ""), "scope": n.get("Scope", ""),
                                "containers": [c["name"] for c in rep["containers"] if n["Name"] in c["networks"]],
                                "builtin": n["Name"] in ("bridge", "host", "none")})
    rep["networks"].sort(key=lambda n: n["name"])
    return rep


def compose(s, *args):
    cmd = compose_cmd()
    if not cmd:
        raise Err("Docker Compose isn't installed on this server")
    full = cmd + ["-p", s["name"]] + (["--project-directory", s["dir"]] if s["dir"] else [])
    for f in s["files"]:
        full += ["-f", f]
    r = subprocess.run(full + list(args), capture_output=True, text=True, timeout=600)
    out = r.stdout + r.stderr
    return out, r.returncode == 0


def last_line(o):
    lines = [l for l in o.strip().splitlines() if l.strip()]
    return lines[-1] if lines else "no details"


def container_verb(cid, verb):
    if verb in ("start", "stop", "restart", "pause", "unpause"):
        api("POST", "/containers/%s/%s" % (cid, verb), timeout=90)
    elif verb == "remove":
        api("DELETE", "/containers/%s?force=1" % cid, timeout=90)
    else:
        raise Err("unknown action")


def stack_verb(cs, s, verb):
    if verb in ("start", "stop", "restart"):
        failed = []
        for c in cs:
            if (c.get("Labels") or {}).get("com.docker.compose.project") != s["name"]:
                continue
            if verb == "start" and c.get("State") == "running" or verb == "stop" and c.get("State") != "running":
                continue
            try:
                container_verb(c["Id"], verb)
            except Err as e:
                failed.append("%s: %s" % (name_of(c), e))
        if failed:
            raise Err("; ".join(failed))
        return None
    if verb in ("up", "down", "update"):
        if s["manager"] == "portainer":
            raise Err("Portainer keeps this stack's settings: deploy it from Portainer (start, stop and restart work here)")
        if not s["files"] or not os.path.isfile(s["files"][0]):
            raise Err("its compose file isn't on this server")
        steps = {"up": [["up", "-d", "--remove-orphans"]], "down": [["down"]], "update": [["pull"], ["up", "-d", "--remove-orphans"]]}[verb]
        text = ""
        for st in steps:
            o, ok = compose(s, *st)
            text += o
            if not ok:
                raise Err("docker compose %s didn't work: %s" % (st[0], last_line(o)))
        return {"text": text}
    raise Err("unknown action")


def do(req):
    op, target, verb = req.get("op"), req.get("target", ""), req.get("verb", "")
    if op == "list":
        return listing()
    cs = api("GET", "/containers/json?all=1") or []

    def container():
        for c in cs:
            if c["Id"] == target or name_of(c) == target:
                return c
        raise Err("there's no container called %s" % target)

    def stack():
        for s in stacks(cs):
            if s["name"] == target:
                return s
        raise Err("there's no stack called %s" % target)

    if op == "container":
        return container_verb(container()["Id"], verb)
    if op == "logs":
        tail = req.get("tail") or 300
        tail = 300 if tail <= 0 or tail > 5000 else tail
        b = api("GET", "/containers/%s/logs?stdout=1&stderr=1&timestamps=1&tail=%d" % (container()["Id"], tail), raw=True)
        return {"text": demux(b)}
    if op == "stack":
        return stack_verb(cs, stack(), verb)
    if op == "file":
        s = stack()
        if not s["files"] or s["manager"] == "portainer":
            raise Err("this stack's file is kept by Portainer: open it there")
        with open(s["files"][0], "rb") as f:
            b = f.read((1 << 20) + 1)
        if len(b) > 1 << 20:
            raise Err("the file is too big to show here")
        return {"text": b.decode("utf-8", "replace"), "path": s["files"][0], "editable": s["editable"]}
    if op == "save":
        s = stack()
        if not s["editable"]:
            raise Err("this stack's file can't be changed here")
        text = req.get("text", "")
        if not text.strip() or len(text) > 1 << 20:
            raise Err("that file is empty or too big")
        path = s["files"][0]
        with open(path, "rb") as f:
            old = f.read()
        with open(path, "w") as f:
            f.write(text)
        o, ok = compose(s, "config", "-q")
        if not ok:
            with open(path, "wb") as f:
                f.write(old)
            raise Err("docker compose found a problem, so the file wasn't changed: " + last_line(o))
        try:
            with open(path + ".apex-before", "wb") as f:
                f.write(old)
        except OSError:
            pass
        return stack_verb(cs, s, "up") if req.get("deploy") else None
    if op in ("image", "volume", "network"):
        if op == "network" and target in ("bridge", "host", "none"):
            raise Err("Docker's own networks can't be removed")
        if verb != "remove" or not SAFE.match(target):
            raise Err("unknown action")
        api("DELETE", "/%ss/%s" % (op, urllib.parse.quote(target, safe="")), timeout=60)
        return None
    if op == "prune":
        q = {"images": "/images/prune" + ("?filters=" + urllib.parse.quote('{"dangling":["false"]}') if req.get("all") else ""),
             "volumes": "/volumes/prune" + ("?filters=" + urllib.parse.quote('{"all":["true"]}') if req.get("all") else ""),
             "networks": "/networks/prune", "containers": "/containers/prune"}.get(target)
        if not q:
            raise Err("unknown action")
        r = api("POST", q, timeout=300) or {}
        return {"reclaimed": r.get("SpaceReclaimed", 0)}
    raise Err("unknown action")


def demux(b):
    out, rest = b"", b
    while len(rest) >= 8 and rest[0] <= 2 and rest[1:4] == b"\0\0\0":
        n = int.from_bytes(rest[4:8], "big")
        if 8 + n > len(rest):
            break
        out += rest[8:8 + n]
        rest = rest[8 + n:]
    return (out + rest if out else b).decode("utf-8", "replace")


def main():
    req = json.loads(base64.b64decode(globals().get("APEX_REQ") or sys.argv[1]))
    try:
        res = do(req)
        print(json.dumps({"ok": True, "result": res}))
    except Err as e:
        m = str(e)
        if m == "PERMISSION":
            print(json.dumps({"ok": False, "permission": True, "message": "This user can't use Docker on the server. Add it to the docker group (sudo usermod -aG docker USER), or allow Apex to use sudo without a password."}))
        else:
            print(json.dumps({"ok": False, "message": m[:1].upper() + m[1:].rstrip(".") + "."}))
    except Exception as e:
        print(json.dumps({"ok": False, "message": "Docker answered something unexpected: %s" % e}))


main()
