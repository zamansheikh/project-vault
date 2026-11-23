#!/usr/bin/env python3
"""Project Vault UI: a local web page for browsing and managing _ProjectVault.

Started by `vault ui` (or the Project Vault app). It listens on 127.0.0.1 only.
Every request must carry the random token made at launch: it arrives in the
opening URL and is then kept in a same-site, HttpOnly cookie. The Host header
must name this server too, so other websites cannot read the vault. The server
stops by itself after 15 minutes without requests.

Backups and restores run the same `vault` script the background job uses.
"""

import difflib
import filecmp
import fnmatch
import http.cookies
import http.server
import io
import json
import os
import re
import secrets
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
import zipfile
from datetime import datetime

HOME = os.path.expanduser("~")
ROOT = os.path.abspath(os.environ.get("VAULT_ROOT") or os.path.join(HOME, "Documents"))
VAULT = os.path.abspath(os.environ.get("VAULT_DIR") or os.path.join(ROOT, "_ProjectVault"))
CUR = os.path.join(VAULT, "current")
HIST = os.path.join(VAULT, "history")
STATE = os.path.join(VAULT, ".state")
EXTRAS = os.path.join(VAULT, "extras.txt")
HERE = os.path.dirname(os.path.realpath(__file__))
SCRIPT = os.path.join(HERE, "vault")
PAGE = os.path.join(HERE, "vault_ui.html")
UI_STATE = os.path.join(STATE, "ui.json")
AGENT_LABEL = "com.projectvault.sync"

IDLE_SECONDS = 15 * 60
MAX_PREVIEW = 256 * 1024
MAX_CANDIDATES = 400
MAX_CANDIDATE_BYTES = 20 * 1024 * 1024
MAX_FOLDER_FILES = 300
ROOT_GROUP = "(top level)"

# Same rules as bin/vault.
MATCH_NAMES = [
    ".env", ".env.*", "*.env", ".dev.vars", ".npmrc", "*.tfvars",
    "google-services.json", "GoogleService-Info.plist", "firebase_options.dart",
    "*firebase-adminsdk*.json", "serviceAccount*.json", "service-account*.json",
    ".runtimeconfig.json", "credentials*.json", "secrets*",
    "key.properties", "keystore.properties", "*.jks", "*.keystore",
    "*.p8", "*.p12", "*.pem", "*.mobileprovision",
]
SKIP_NAMES = ["*.example", "*.sample", "*.template", "*.dist", "local.properties"]
PRUNE_NAMES = {
    "node_modules", ".git", "build", "Pods", ".dart_tool", ".gradle", ".next", "dist",
    ".venv", "venv", "Library", "Temp", ".expo", "DerivedData", ".pub-cache", "ephemeral",
    ".symlinks", ".cxx", ".turbo", ".cache", ".wrangler", ".svelte-kit", "__pycache__",
    ".claude", ".worktrees", ".idea", ".vscode", ".fvm", ".firebase", "coverage",
}
# KEY=VALUE files: the page can show their keys while hiding the values.
KV_NAMES = [".env", ".env.*", "*.env", ".dev.vars", ".npmrc", "*.tfvars", "*.properties"]
NOISE = re.compile(
    r"(^|/)(\.DS_Store|xcuserdata|Generated\.xcconfig|GeneratedPluginRegistrant\.\w+|"
    r"flutter_export_environment\.sh|\.flutter-plugins(-dependencies)?|\.packages)(/|$)"
    r"|\.(log|iml|lock|tsbuildinfo|pyc|apk|aab|ipa|mp4|zip|o|d|swiftdeps|map)$"
)

TOKEN = secrets.token_urlsafe(32)
PORT = 0
COOKIE = "pv"
LAST_REQUEST = [time.time()]
SERVER = [None]


class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


# ---------- paths ----------

def clean_rel(rel):
    """A path relative to the projects folder, with no way to climb out of it."""
    if not isinstance(rel, str) or "\x00" in rel:
        raise ApiError(400, "Bad path")
    rel = rel.strip().strip("/")
    if rel.startswith(ROOT + "/"):
        rel = rel[len(ROOT) + 1:]
    if not rel:
        return ""
    if any(p in ("", ".", "..") for p in rel.split("/")):
        raise ApiError(400, "Bad path")
    return rel


def inside(base, rel):
    full = os.path.normpath(os.path.join(base, rel)) if rel else base
    if full != base and not full.startswith(base + os.sep):
        raise ApiError(400, "Bad path")
    return full


def q_get(q, key, default=None):
    v = q.get(key)
    return v[0] if v else default


def fmt_time(ts):
    return datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M")


def matches(name, patterns):
    return any(fnmatch.fnmatchcase(name, p) for p in patterns)


def is_auto(name):
    return matches(name, MATCH_NAMES) and not matches(name, SKIP_NAMES)


def is_text(path):
    try:
        with open(path, "rb") as f:
            chunk = f.read(8192)
        if b"\0" in chunk:
            return False
        chunk.decode("utf-8")
        return True
    except (OSError, UnicodeDecodeError):
        return False


def git_top(d):
    try:
        r = subprocess.run(["git", "-C", d, "rev-parse", "--show-toplevel"],
                           capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    top = r.stdout.strip()
    return top if r.returncode == 0 and top else None


# ---------- vault data ----------

def guess_project(rel):
    d = os.path.dirname(rel)
    if not d:
        return ROOT_GROUP
    return "/".join(d.split("/")[:2])


def load_index():
    idx = {}
    p = os.path.join(STATE, "index.tsv")
    if os.path.exists(p):
        with open(p, encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 3:
                    idx[parts[0]] = (parts[1], parts[2])
    return idx


def vault_files():
    out = []
    for dp, _dns, fns in os.walk(CUR):
        for fn in fns:
            if fn != ".DS_Store":
                out.append(os.path.relpath(os.path.join(dp, fn), CUR))
    out.sort(key=str.lower)
    return out


def project_of(rel, idx):
    if rel in idx and idx[rel][0]:
        return idx[rel][0]
    return guess_project(rel)


def file_status(rel, idx):
    src = os.path.join(ROOT, rel)
    if not os.path.exists(src):
        return "missing"
    if rel in idx and idx[rel][1] == "no longer watched":
        return "unwatched"
    try:
        if not filecmp.cmp(src, os.path.join(CUR, rel), shallow=False):
            return "changed"
    except OSError:
        return "unknown"
    return "ok"


def versions(rel):
    """All versions of a file, oldest first, plus copies saved before restores."""
    d, base = os.path.split(rel)
    hd = os.path.join(HIST, d)
    pat = re.compile(r"^" + re.escape(base) + r"\.v(\d+)_(.+)$")
    found, pre = [], []
    try:
        names = os.listdir(hd)
    except OSError:
        names = []
    for n in names:
        m = pat.match(n)
        if m:
            found.append((int(m.group(1)), os.path.join(hd, n)))
        elif n.startswith(base + ".pre-restore_"):
            pre.append(os.path.join(hd, n))
    found.sort()
    cur_v = (found[-1][0] if found else 0) + 1
    out = []
    for v, path in found:
        st = os.stat(path)
        out.append({"v": v, "edited": fmt_time(st.st_mtime), "size": st.st_size, "current": False})
    curp = os.path.join(CUR, rel)
    if os.path.isfile(curp):
        st = os.stat(curp)
        out.append({"v": cur_v, "edited": fmt_time(st.st_mtime), "size": st.st_size, "current": True})
    pre.sort()
    return out, cur_v, pre


def version_file(rel, v):
    vs, cur_v, _ = versions(rel)
    if v is None or int(v) == cur_v:
        return os.path.join(CUR, rel), cur_v, True
    d, base = os.path.split(rel)
    hd = os.path.join(HIST, d)
    prefix = "%s.v%d_" % (base, int(v))
    for n in sorted(os.listdir(hd)) if os.path.isdir(hd) else []:
        if n.startswith(prefix):
            return os.path.join(hd, n), int(v), False
    raise ApiError(404, "No version v%s of %s" % (v, rel))


def last_sync():
    try:
        with open(os.path.join(STATE, "last-sync"), encoding="utf-8") as f:
            line = f.read().strip()
    except OSError:
        return None
    return {"at": line[:19], "summary": line[19:].strip()}


def agent_status():
    try:
        r = subprocess.run(["launchctl", "print", "gui/%d/%s" % (os.getuid(), AGENT_LABEL)],
                           capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return {"loaded": False}
    if r.returncode != 0:
        return {"loaded": False}
    m = re.search(r"last exit code = (.+)", r.stdout)
    return {"loaded": True, "running": "state = running" in r.stdout,
            "lastExit": m.group(1).strip() if m else None}


def _last_copy(name):
    try:
        with open(os.path.join(STATE, name), encoding="utf-8") as f:
            line = f.read().strip()
        return {"at": line[:19], "name": (line[19:].split() or [""])[0]}
    except OSError:
        return None


def _usb_plugged(uuid):
    try:
        out = subprocess.run(["diskutil", "info", "-plist", uuid], capture_output=True, timeout=10).stdout
        import plistlib
        mp = plistlib.loads(out).get("MountPoint") if out else None
        return bool(mp and os.path.isdir(mp))
    except Exception:
        return False


def offsite_status():
    conf = os.path.join(VAULT, "offsite.conf")
    settings = {}
    if os.path.exists(conf):
        with open(conf, encoding="utf-8", errors="replace") as f:
            for line in f:
                if "=" in line:
                    k, v = line.rstrip("\n").split("=", 1)
                    settings[k] = v
    dest = settings.get("DEST", "").strip()
    out = {"configured": bool(dest), "usb": {"configured": bool(settings.get("USB_UUID"))}}
    if dest:
        out.update({"where": "iCloud Drive" if "com~apple~CloudDocs" in dest else dest,
                    "last": _last_copy("last-offsite"),
                    "failing": os.path.exists(os.path.join(STATE, "attempt-cloud"))})
    if settings.get("USB_UUID"):
        out["usb"].update({"name": settings.get("USB_NAME") or "USB drive",
                           "plugged": _usb_plugged(settings["USB_UUID"]),
                           "last": _last_copy("last-usb"),
                           "failing": os.path.exists(os.path.join(STATE, "attempt-usb"))})
    return out


def extras_entries():
    out = []
    if os.path.exists(EXTRAS):
        with open(EXTRAS, encoding="utf-8", errors="replace") as f:
            for line in f:
                s = line.strip()
                if not s or s.startswith("#"):
                    continue
                s = s.rstrip("/")
                if s.startswith(ROOT + "/"):
                    s = s[len(ROOT) + 1:]
                out.append(s)
    return out


def run_script(args, timeout=900):
    try:
        r = subprocess.run(["/bin/zsh", SCRIPT] + args, capture_output=True, text=True,
                           timeout=timeout, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return {"ok": False, "output": "Timed out."}
    return {"ok": r.returncode == 0, "output": (r.stdout + r.stderr).strip()}


def project_files(name, idx=None):
    idx = idx if idx is not None else load_index()
    return [rel for rel in vault_files() if project_of(rel, idx) == name]


def short_name(rel, project):
    if project != ROOT_GROUP and rel.startswith(project + "/"):
        return rel[len(project) + 1:]
    return rel


# ---------- GET handlers ----------

def api_summary(q):
    idx = load_index()
    filecmp.clear_cache()
    projects, files = {}, []
    totals = {"files": 0, "missing": 0, "changed": 0}
    for rel in vault_files():
        name = project_of(rel, idx)
        st = file_status(rel, idx)
        p = projects.setdefault(name, {"name": name, "files": 0, "missing": 0, "changed": 0, "unwatched": 0})
        p["files"] += 1
        totals["files"] += 1
        if st in ("missing", "changed", "unwatched"):
            p[st] += 1
        if st in ("missing", "changed"):
            totals[st] += 1
        files.append({"path": rel, "project": name, "status": st})
    return {
        "projects": sorted(projects.values(), key=lambda p: p["name"].lower()),
        "files": files, "totals": totals, "projectCount": len(projects),
        "lastSync": last_sync(), "agent": agent_status(), "offsite": offsite_status(),
        "vault": VAULT, "root": ROOT, "home": HOME,
    }


def api_project(q):
    name = q_get(q, "name", "")
    idx = load_index()
    filecmp.clear_cache()
    out = []
    for rel in project_files(name, idx):
        _vs, cur_v, _ = versions(rel)
        st = os.stat(os.path.join(CUR, rel))
        out.append({"path": rel, "name": short_name(rel, name), "version": cur_v,
                    "edited": fmt_time(st.st_mtime), "size": st.st_size,
                    "status": file_status(rel, idx)})
    if not out:
        raise ApiError(404, "No project called %s in the vault" % name)
    real = name != ROOT_GROUP
    src = os.path.join(ROOT, name) if real else ROOT
    return {"name": name, "files": out, "restorable": True, "source": src,
            "sourceExists": os.path.isdir(src), "isGroup": not real}


def api_file(q):
    rel = clean_rel(q_get(q, "path", ""))
    curp = inside(CUR, rel)
    if not os.path.isfile(curp):
        raise ApiError(404, "Not in the vault: %s" % rel)
    idx = load_index()
    filecmp.clear_cache()
    vs, cur_v, pre = versions(rel)
    return {
        "path": rel, "name": os.path.basename(rel), "project": project_of(rel, idx),
        "status": file_status(rel, idx), "source": os.path.join(ROOT, rel),
        "version": cur_v, "versions": vs,
        "preRestore": [{"name": os.path.basename(p), "edited": fmt_time(os.path.getmtime(p))} for p in pre],
        "text": is_text(curp), "kv": matches(os.path.basename(rel), KV_NAMES),
    }


def read_version_text(rel, v):
    path, _v, _cur = version_file(rel, v)
    if os.path.getsize(path) > MAX_PREVIEW:
        raise ApiError(400, "Too big to show here; download it instead.")
    if not is_text(path):
        raise ApiError(400, "Binary file; download it to use it.")
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def api_preview(q):
    rel = clean_rel(q_get(q, "path", ""))
    return {"text": read_version_text(rel, q_get(q, "v"))}


def api_diff(q):
    rel = clean_rel(q_get(q, "path", ""))
    a, b = int(q_get(q, "a")), int(q_get(q, "b"))
    ta, tb = read_version_text(rel, a), read_version_text(rel, b)
    lines = list(difflib.unified_diff(ta.splitlines(), tb.splitlines(), "v%d" % a, "v%d" % b, lineterm=""))
    return {"lines": lines}


def api_browse(q):
    rel = clean_rel(q_get(q, "path", ""))
    absd = inside(ROOT, rel)
    if not os.path.isdir(absd):
        raise ApiError(404, "Folder not found: %s" % rel)
    dirs = []
    try:
        entries = sorted(os.scandir(absd), key=lambda e: e.name.lower())
    except OSError as e:
        raise ApiError(403, "Cannot open %s: %s" % (rel or os.path.basename(ROOT), e.strerror))
    for e in entries:
        try:
            if not e.is_dir(follow_symlinks=False):
                continue
        except OSError:
            continue
        if e.name.startswith(".") or e.name in PRUNE_NAMES or os.path.abspath(e.path) == VAULT:
            continue
        dirs.append({"name": e.name, "path": (rel + "/" if rel else "") + e.name,
                     "git": os.path.exists(os.path.join(e.path, ".git"))})
    top = git_top(absd) if rel else None
    repo = os.path.relpath(top, ROOT) if top and top.startswith(ROOT + "/") else None
    return {"path": rel, "dirs": dirs, "repo": repo}


def expand_small_dir(absd, p, limit=50):
    """git lists a fully ignored folder as one entry; list its files instead when there are few."""
    if any(part in PRUNE_NAMES for part in p.rstrip("/").split("/")):
        return [p]
    files = []
    for dp, dns, fns in os.walk(os.path.join(absd, p)):
        dns[:] = [d for d in dns if d not in PRUNE_NAMES]
        for fn in fns:
            files.append(os.path.relpath(os.path.join(dp, fn), absd))
            if len(files) > limit:
                return [p]
    return files or [p]


def api_candidates(q):
    rel = clean_rel(q_get(q, "path", ""))
    if not rel:
        raise ApiError(400, "Open a project folder first.")
    absd = inside(ROOT, rel)
    if not os.path.isdir(absd):
        raise ApiError(404, "Folder not found: %s" % rel)
    top = git_top(absd)
    entries = []
    if top:
        seen = set()
        for extra in (["--ignored"], []):
            r = subprocess.run(["git", "-C", absd, "ls-files", "-z", "--others", "--exclude-standard",
                                "--directory", "--no-empty-directory"] + extra + ["--", "."],
                               capture_output=True, timeout=60)
            for p in r.stdout.decode("utf-8", "replace").split("\0"):
                if not p or p in seen:
                    continue
                seen.add(p)
                entries.extend(expand_small_dir(absd, p) if p.endswith("/") else [p])
    else:
        for dp, dns, fns in os.walk(absd):
            dns[:] = sorted(d for d in dns if d not in PRUNE_NAMES
                            and os.path.abspath(os.path.join(dp, d)) != VAULT)
            for fn in sorted(fns):
                entries.append(os.path.relpath(os.path.join(dp, fn), absd))
            if len(entries) > MAX_CANDIDATES * 3:
                break
    in_extras = set(extras_entries())
    items, truncated = [], False
    for p in sorted(entries, key=str.lower):
        is_dir = p.endswith("/")
        p = p.rstrip("/")
        if any(part in PRUNE_NAMES for part in p.split("/")) or NOISE.search(p):
            continue
        full = os.path.join(absd, p)
        if os.path.islink(full):
            continue
        r2 = rel + "/" + p
        if is_dir:
            item = {"path": r2, "name": p + "/", "dir": True, "size": None,
                    "inVault": os.path.isdir(os.path.join(CUR, r2)), "auto": False}
        else:
            try:
                size = os.path.getsize(full)
            except OSError:
                continue
            if size > MAX_CANDIDATE_BYTES:
                continue
            item = {"path": r2, "name": p, "dir": False, "size": size,
                    "inVault": os.path.isfile(os.path.join(CUR, r2)),
                    "auto": is_auto(os.path.basename(p))}
        item["inExtras"] = r2 in in_extras
        items.append(item)
        if len(items) >= MAX_CANDIDATES:
            truncated = True
            break
    repo = os.path.relpath(top, ROOT) if top and top.startswith(ROOT + "/") else None
    return {"path": rel, "repo": repo, "items": items, "truncated": truncated,
            "canAddFolder": top is None, "folderInExtras": rel in in_extras}


def api_extras(q):
    return {"entries": [{"path": e, "exists": os.path.exists(os.path.join(ROOT, e)),
                         "dir": os.path.isdir(os.path.join(ROOT, e))} for e in extras_entries()]}


def api_ping(q):
    return {"ok": True}


GET_ROUTES = {
    "/api/summary": api_summary, "/api/project": api_project, "/api/file": api_file,
    "/api/preview": api_preview, "/api/diff": api_diff, "/api/browse": api_browse,
    "/api/candidates": api_candidates, "/api/extras": api_extras, "/api/ping": api_ping,
}


# ---------- downloads ----------

def download_name(rel, v, is_current):
    base = os.path.basename(rel)
    if is_current:
        return base
    stem, ext = os.path.splitext(base)
    if stem and ext and not base.startswith("."):
        return "%s.v%d%s" % (stem, v, ext)
    return "%s.v%d" % (base, v)


def get_download(q):
    rel = clean_rel(q_get(q, "path", ""))
    if not os.path.isfile(inside(CUR, rel)):
        raise ApiError(404, "Not in the vault: %s" % rel)
    path, v, is_current = version_file(rel, q_get(q, "v"))
    with open(path, "rb") as f:
        return f.read(), download_name(rel, v, is_current)


def get_project_zip(q):
    name = q_get(q, "name", "")
    files = project_files(name)
    if not files:
        raise ApiError(404, "No project called %s in the vault" % name)
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for rel in files:
            z.write(os.path.join(CUR, rel), short_name(rel, name))
    label = os.path.basename(name) if name != ROOT_GROUP else "top-level"
    return buf.getvalue(), "%s-vault-%s.zip" % (label, datetime.now().strftime("%Y-%m-%d"))


# ---------- POST handlers ----------

def api_sync(body):
    return run_script(["sync"])


def api_offsite(body):
    return run_script(["offsite"])


def api_restore(body):
    version = body.get("version")
    project = body.get("project")
    if project is not None:
        files = project_files(project)
        if not files:
            raise ApiError(404, "No project called %s in the vault" % project)
        targets = files if project == ROOT_GROUP else [clean_rel(project)]
    else:
        rel = clean_rel(body.get("path", ""))
        if not rel or not os.path.isfile(inside(CUR, rel)):
            raise ApiError(404, "Not in the vault: %s" % rel)
        targets = [rel]
    outputs, ok = [], True
    for t in targets:
        args = ["restore", t, "--force"]
        if version is not None:
            args += ["--version", str(int(version))]
        r = run_script(args)
        ok = ok and r["ok"]
        if r["output"]:
            outputs.append(r["output"])
    return {"ok": ok, "output": "\n".join(outputs)}


def count_files(d, limit):
    n = 0
    for _dp, dns, fns in os.walk(d):
        dns[:] = [x for x in dns if x != ".git"]
        n += len(fns)
        if n > limit:
            break
    return n


def api_extras_add(body):
    paths = body.get("paths") or []
    if not isinstance(paths, list) or not paths:
        raise ApiError(400, "Nothing selected.")
    existing = set(extras_entries())
    added = []
    for p in paths:
        r = clean_rel(p)
        if not r:
            raise ApiError(400, "Pick a folder or file inside the projects folder, not the whole folder.")
        full = inside(ROOT, r)
        if not os.path.exists(full):
            raise ApiError(400, "Not found: %s" % r)
        if full == VAULT or full.startswith(VAULT + os.sep):
            raise ApiError(400, "That is the vault itself.")
        if os.path.isdir(full):
            if os.path.exists(os.path.join(full, ".git")):
                raise ApiError(400, "%s is a git repo. Pick the specific files it needs instead." % r)
            if count_files(full, MAX_FOLDER_FILES) > MAX_FOLDER_FILES:
                raise ApiError(400, "%s has more than %d files. Pick specific files instead." % (r, MAX_FOLDER_FILES))
        if r not in existing:
            added.append(r)
            existing.add(r)
    if added:
        text = ""
        if os.path.exists(EXTRAS):
            with open(EXTRAS, encoding="utf-8", errors="replace") as f:
                text = f.read()
        with open(EXTRAS, "a", encoding="utf-8") as f:
            if text and not text.endswith("\n"):
                f.write("\n")
            f.write("\n# Added from the Project Vault app on %s\n" % datetime.now().strftime("%Y-%m-%d %H:%M"))
            f.write("\n".join(added) + "\n")
    r = run_script(["sync"])
    return {"ok": r["ok"], "added": added, "output": r["output"]}


def api_extras_remove(body):
    target = clean_rel(body.get("path", ""))
    if not target or not os.path.exists(EXTRAS):
        raise ApiError(400, "Nothing to remove.")
    kept, removed = [], False
    with open(EXTRAS, encoding="utf-8", errors="replace") as f:
        for line in f:
            s = line.strip().rstrip("/")
            if s.startswith(ROOT + "/"):
                s = s[len(ROOT) + 1:]
            if s == target and not line.lstrip().startswith("#"):
                removed = True
                continue
            kept.append(line)
    if not removed:
        raise ApiError(404, "%s is not on the manual list." % target)
    with open(EXTRAS, "w", encoding="utf-8") as f:
        f.writelines(kept)
    return {"ok": True}


def api_open(body):
    what = body.get("what")
    if what == "vault":
        subprocess.Popen(["open", VAULT])
    elif what in ("source", "vaultfile"):
        rel = clean_rel(body.get("path", ""))
        base = ROOT if what == "source" else CUR
        full = inside(base, rel)
        while not os.path.exists(full) and full != base:
            full = os.path.dirname(full)
        subprocess.Popen(["open", "-R", full] if os.path.isfile(full) else ["open", full])
    else:
        raise ApiError(400, "Unknown target")
    return {"ok": True}


def api_quit(body):
    threading.Timer(0.3, lambda: SERVER[0].shutdown()).start()
    return {"ok": True}


POST_ROUTES = {
    "/api/sync": api_sync, "/api/offsite": api_offsite, "/api/restore": api_restore, "/api/extras/add": api_extras_add,
    "/api/extras/remove": api_extras_remove, "/api/open": api_open, "/api/quit": api_quit,
}

SECURITY_HEADERS = [
    ("Cache-Control", "no-store"),
    ("X-Content-Type-Options", "nosniff"),
    ("X-Frame-Options", "DENY"),
    ("Referrer-Policy", "no-referrer"),
    ("Content-Security-Policy",
     "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; "
     "img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; form-action 'self'"),
]

LOCKED_PAGE = """<!doctype html><meta charset="utf-8"><title>Project Vault</title>
<body style="font:15px -apple-system,system-ui,sans-serif;max-width:520px;margin:15vh auto;padding:0 16px;color:#1d2330">
<h1 style="font-size:20px">This Project Vault link has expired</h1>
<p>Open Project Vault again: the <b>Project Vault</b> app, or <code>vault ui</code> in Terminal.</p></body>"""


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "ProjectVault"
    sys_version = ""

    def log_message(self, fmt, *args):
        pass

    def _host_ok(self):
        return self.headers.get("Host") in ("127.0.0.1:%d" % PORT, "localhost:%d" % PORT)

    def _cookie_ok(self):
        try:
            c = http.cookies.SimpleCookie(self.headers.get("Cookie", ""))
        except http.cookies.CookieError:
            return False
        m = c.get(COOKIE)
        return m is not None and secrets.compare_digest(m.value, TOKEN)

    def _send(self, status, body, ctype, extra=()):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(status)
        for k, v in SECURITY_HEADERS:
            self.send_header(k, v)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _json(self, status, obj):
        self._send(status, json.dumps(obj), "application/json; charset=utf-8")

    def _attachment(self, data, filename):
        quoted = urllib.parse.quote(filename, safe="")
        ascii_name = re.sub(r"[^A-Za-z0-9._-]", "_", filename) or "download"
        self._send(200, data, "application/octet-stream",
                   [("Content-Disposition", "attachment; filename=\"%s\"; filename*=UTF-8''%s" % (ascii_name, quoted))])

    def do_GET(self):
        LAST_REQUEST[0] = time.time()
        if not self._host_ok():
            return self._send(403, "Forbidden", "text/plain")
        u = urllib.parse.urlsplit(self.path)
        q = urllib.parse.parse_qs(u.query)
        if u.path == "/":
            t = q_get(q, "t", "")
            if t and secrets.compare_digest(t, TOKEN):
                self.send_response(303)
                for k, v in SECURITY_HEADERS:
                    self.send_header(k, v)
                self.send_header("Set-Cookie", "%s=%s; HttpOnly; SameSite=Strict; Path=/" % (COOKIE, TOKEN))
                self.send_header("Location", "/")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if not self._cookie_ok():
                return self._send(403, LOCKED_PAGE, "text/html; charset=utf-8")
            with open(PAGE, "rb") as f:
                return self._send(200, f.read(), "text/html; charset=utf-8")
        if not self._cookie_ok():
            return self._json(403, {"error": "This window has expired. Open Project Vault again."})
        try:
            if u.path == "/api/download":
                return self._attachment(*get_download(q))
            if u.path == "/api/download-project":
                return self._attachment(*get_project_zip(q))
            route = GET_ROUTES.get(u.path)
            if not route:
                raise ApiError(404, "Not found")
            self._json(200, route(q))
        except ApiError as e:
            self._json(e.status, {"error": e.message})
        except (ValueError, TypeError) as e:
            self._json(400, {"error": "Bad request: %s" % e})
        except Exception as e:  # keep the server alive; show the error on the page
            self._json(500, {"error": "%s: %s" % (type(e).__name__, e)})

    def do_POST(self):
        LAST_REQUEST[0] = time.time()
        if not (self._host_ok() and self._cookie_ok() and self.headers.get("X-Vault-Request") == "1"):
            return self._json(403, {"error": "This window has expired. Open Project Vault again."})
        try:
            length = int(self.headers.get("Content-Length") or 0)
            if length > 1000000:
                raise ApiError(413, "Request too large")
            body = json.loads(self.rfile.read(length) or b"{}")
            if not isinstance(body, dict):
                raise ApiError(400, "Bad request")
            route = POST_ROUTES.get(urllib.parse.urlsplit(self.path).path)
            if not route:
                raise ApiError(404, "Not found")
            self._json(200, route(body))
        except ApiError as e:
            self._json(e.status, {"error": e.message})
        except (ValueError, TypeError) as e:
            self._json(400, {"error": "Bad request: %s" % e})
        except Exception as e:
            self._json(500, {"error": "%s: %s" % (type(e).__name__, e)})


# ---------- launch ----------

def running_instance():
    """URL of a Project Vault UI that is already running, if any."""
    try:
        with open(UI_STATE, encoding="utf-8") as f:
            s = json.load(f)
        port, token = int(s["port"]), s["token"]
        req = urllib.request.Request("http://127.0.0.1:%d/api/ping" % port,
                                     headers={"Cookie": "%s=%s" % (COOKIE, token)})
        with urllib.request.urlopen(req, timeout=2) as r:
            if r.status == 200:
                return "http://127.0.0.1:%d/?t=%s" % (port, token)
    except Exception:
        pass
    return None


def watchdog():
    while True:
        time.sleep(20)
        if time.time() - LAST_REQUEST[0] > IDLE_SECONDS:
            SERVER[0].shutdown()
            return


def main():
    global PORT
    no_open = "--no-open" in sys.argv[1:]
    url = running_instance()
    if url:
        print("Project Vault is already open: %s" % url, flush=True)
        if not no_open:
            subprocess.run(["open", url])
        return
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    SERVER[0] = server
    PORT = server.server_address[1]
    os.makedirs(STATE, exist_ok=True)
    fd = os.open(UI_STATE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump({"port": PORT, "token": TOKEN, "pid": os.getpid()}, f)
    url = "http://127.0.0.1:%d/?t=%s" % (PORT, TOKEN)
    print("Project Vault is open at %s\nIt stops after 15 idle minutes, or press Ctrl+C." % url, flush=True)
    if not no_open:
        subprocess.Popen(["open", url])
    threading.Thread(target=watchdog, daemon=True).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        try:
            with open(UI_STATE, encoding="utf-8") as f:
                if json.load(f).get("pid") == os.getpid():
                    os.remove(UI_STATE)
        except (OSError, ValueError):
            pass
        print("Project Vault stopped.", flush=True)


if __name__ == "__main__":
    main()
