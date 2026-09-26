#!/usr/bin/env python3
"""FreshRSS backend for the Omarchy/DMS plugin.

Talks to FreshRSS through its Google Reader-compatible API
(<server>/api/greader.php). Every command prints one JSON object on stdout;
failures are reported as {"error": "..."} so the QML side never has to parse
anything else. Standard library only.
"""
import json
import os
import shutil
import subprocess
import sys
import time
from html.parser import HTMLParser
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode, urljoin, urlparse
from urllib.request import Request, urlopen

CONFIG_DIR = os.path.expanduser("~/.config/freshrss-plugin")
CONFIG_PATH = os.path.join(CONFIG_DIR, "config.json")
STATE_DIR = os.path.expanduser("~/.local/state/freshrss-plugin")

_KEYRING_SERVICE = "freshrss-plugin"
_KEYRING_ACCOUNT = "token"

READING_LIST = "user/-/state/com.google/reading-list"
READ = "user/-/state/com.google/read"
STARRED = "user/-/state/com.google/starred"

NO_KEYRING_MESSAGE = ("couldn't save the login: no system keyring is running. Install one "
                      "that provides the Secret Service (e.g. gnome-keyring), then connect again.")


class FreshRSSError(Exception):
    pass


# ---------------------------------------------------------------- helpers

def normalize_base_url(base_url: str) -> str:
    """Accept what people paste: add http:// when missing, drop a trailing
    slash and a pasted /api/greader.php or /i/ web path."""
    url = base_url.strip()
    if url and "://" not in url:
        url = "http://" + url
    url = url.rstrip("/")
    for suffix in ("/api/greader.php", "/i"):
        if url.endswith(suffix):
            url = url[: -len(suffix)]
    return url.rstrip("/")


def api_url(base_url: str, path: str) -> str:
    return base_url.rstrip("/") + "/api/greader.php" + path


class _TextExtractor(HTMLParser):
    _BLOCK = {"p", "br", "div", "li", "ul", "ol", "h1", "h2", "h3", "h4", "tr", "blockquote"}

    def __init__(self):
        super().__init__()
        self.parts = []
        self._skip = 0

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style"):
            self._skip += 1
        elif tag in self._BLOCK:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in ("script", "style"):
            self._skip = max(0, self._skip - 1)
        elif tag in self._BLOCK:
            self.parts.append("\n")

    def handle_data(self, data):
        if not self._skip:
            self.parts.append(data)


class _FirstImage(HTMLParser):
    """First real <img> in an article: skips tracking pixels (1x1) and
    data: URIs."""

    def __init__(self):
        super().__init__()
        self.src = ""

    def handle_starttag(self, tag, attrs):
        if self.src or tag != "img":
            return
        a = dict(attrs)
        if a.get("width") in ("0", "1") or a.get("height") in ("0", "1"):
            return
        src = (a.get("src") or "").strip()
        if src and not src.startswith("data:"):
            self.src = src


# Qt on Omarchy decodes jpg/png/gif/webp/svg; AVIF and HEIC need extra plugins.
_UNSUPPORTED_IMAGE = (".avif", ".heic", ".heif")


def _usable_image(url: str, base: str) -> str:
    url = urljoin(base, url.strip()) if url else ""
    if not url.startswith(("http://", "https://")):
        return ""
    if urlparse(url).path.lower().endswith(_UNSUPPORTED_IMAGE):
        return ""
    return url


def thumbnail_url(item: dict, html: str, link: str) -> str:
    """An image enclosure if the feed has one, else the first <img> in the
    article. Relative URLs resolve against the article link."""
    for enc in item.get("enclosure") or []:
        href = enc.get("href") or ""
        if (enc.get("type") or "").startswith("image") or \
                urlparse(href).path.lower().endswith((".jpg", ".jpeg", ".png", ".gif", ".webp")):
            url = _usable_image(href, link)
            if url:
                return url
    if html:
        finder = _FirstImage()
        finder.feed(html)
        return _usable_image(finder.src, link)
    return ""


def html_to_text(fragment: str) -> str:
    """Article summaries arrive as HTML; the panel renders themed plain text."""
    if not fragment:
        return ""
    parser = _TextExtractor()
    parser.feed(fragment)
    lines = [" ".join(line.split()) for line in "".join(parser.parts).splitlines()]
    text = "\n".join(lines)
    while "\n\n\n" in text:
        text = text.replace("\n\n\n", "\n\n")
    return text.strip()


# ---------------------------------------------------------------- HTTP

def _request(url: str, *, token: str = None, data: dict = None, timeout: int = 15) -> bytes:
    headers = {}
    if token:
        headers["Authorization"] = f"GoogleLogin auth={token}"
    body = None
    if data is not None:
        body = urlencode(data, doseq=True).encode("utf-8")
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    request = Request(url, data=body, headers=headers, method="POST" if body is not None else "GET")
    try:
        with urlopen(request, timeout=timeout) as response:
            return response.read()
    except HTTPError as exc:
        if exc.code == 401:
            raise FreshRSSError("not authorized: check the username and API password") from exc
        raise FreshRSSError(f"request failed: HTTP {exc.code}") from exc
    except URLError as exc:
        raise FreshRSSError(f"could not reach server: {exc.reason}") from exc


def _get_json(base_url: str, token: str, path: str) -> dict:
    raw = _request(api_url(base_url, path), token=token)
    try:
        return json.loads(raw.decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise FreshRSSError("server returned invalid JSON") from exc


# ---------------------------------------------------------------- API

def check_is_freshrss(base_url: str) -> None:
    """GET /api/greader.php answers "OK" when the API is enabled. Catches a
    wrong address before the API password is sent anywhere."""
    try:
        with urlopen(Request(api_url(base_url, "")), timeout=10) as response:
            raw = response.read()
    except HTTPError as exc:
        raise FreshRSSError(f"{base_url} doesn't look like a FreshRSS server "
                            f"(its /api/greader.php answered HTTP {exc.code})") from exc
    except URLError as exc:
        raise FreshRSSError(f"could not reach {base_url} ({exc.reason})") from exc
    if raw.strip() != b"OK":
        raise FreshRSSError(f"{base_url} answered, but its FreshRSS API isn't enabled "
                            "(Settings → Authentication → Allow API access)")


def login(base_url: str, username: str, api_password: str) -> str:
    """ClientLogin with the API password (Settings → Profile → API password in
    FreshRSS, not the web login password). Returns the auth token."""
    raw = _request(api_url(base_url, "/accounts/ClientLogin"),
                   data={"Email": username, "Passwd": api_password})
    for line in raw.decode("utf-8", "replace").splitlines():
        if line.startswith("Auth="):
            return line[len("Auth="):].strip()
    raise FreshRSSError("login failed: no auth token in the response")


def write_token(base_url: str, token: str) -> str:
    """Short-lived token required on every edit request (T=...)."""
    return _request(api_url(base_url, "/reader/api/0/token"), token=token).decode("utf-8").strip()


def favicon_url(icon_url: str, base_url: str) -> str:
    """FreshRSS serves favicons from its own f.php but builds the URL from its
    base_url setting, which is often missing the port (or wrong) behind a
    proxy. Rebuild it on the address the user connected with."""
    if not icon_url:
        return ""
    parts = urlparse(urljoin(base_url + "/", icon_url))
    if parts.path.endswith("/f.php"):
        return base_url + "/f.php" + ("?" + parts.query if parts.query else "")
    return parts.geturl()


def overview(base_url: str, token: str) -> dict:
    """Categories and feeds with unread counts, shaped for the panel:
    {"totalUnread": n, "categories": [{"id", "label", "unread",
     "feeds": [{"id", "title", "unread", "iconUrl", "htmlUrl"}]}]}"""
    subs = _get_json(base_url, token, "/reader/api/0/subscription/list?output=json")
    counts = _get_json(base_url, token, "/reader/api/0/unread-count?output=json")
    unread = {c.get("id"): int(c.get("count") or 0) for c in counts.get("unreadcounts") or []}

    categories = {}
    for sub in subs.get("subscriptions") or []:
        cats = sub.get("categories") or [{"id": "user/-/label/Uncategorized", "label": "Uncategorized"}]
        cat = cats[0]
        entry = categories.setdefault(cat.get("id"), {
            "id": cat.get("id"), "label": cat.get("label") or "Uncategorized",
            "unread": unread.get(cat.get("id"), 0), "feeds": []})
        entry["feeds"].append({
            "id": sub.get("id"), "title": sub.get("title") or "",
            "unread": unread.get(sub.get("id"), 0),
            "iconUrl": favicon_url(sub.get("iconUrl") or "", base_url), "htmlUrl": sub.get("htmlUrl") or ""})
    for cat in categories.values():
        if not cat["unread"]:
            cat["unread"] = sum(f["unread"] for f in cat["feeds"])
        cat["feeds"].sort(key=lambda f: f["title"].lower())
    ordered = sorted(categories.values(), key=lambda c: c["label"].lower())
    total = unread.get(READING_LIST) or sum(c["unread"] for c in ordered)
    return {"totalUnread": total, "categories": ordered}


def items(base_url: str, token: str, stream_id: str, *, unread_only: bool = True,
          continuation: str = "", count: int = 40) -> dict:
    """Items in a stream (reading list, a label, a feed, or starred), newest
    first. Returns {"items": [...], "continuation": "..."}."""
    params = {"output": "json", "n": count}
    if unread_only:
        params["xt"] = READ
    if continuation:
        params["c"] = continuation
    path = "/reader/api/0/stream/contents/" + quote(stream_id, safe="") + "?" + urlencode(params)
    data = _get_json(base_url, token, path)
    out = []
    for it in data.get("items") or []:
        cats = it.get("categories") or []
        link = ""
        for key in ("canonical", "alternate"):
            if it.get(key):
                link = it[key][0].get("href") or ""
                break
        origin = it.get("origin") or {}
        html = ((it.get("summary") or it.get("content") or {}).get("content")) or ""
        out.append({
            "id": it.get("id"),
            "title": it.get("title") or "(untitled)",
            "published": int(it.get("published") or 0),
            "author": it.get("author") or "",
            "url": link,
            "feedId": origin.get("streamId") or "",
            "feedTitle": origin.get("title") or "",
            "read": READ in cats,
            "starred": STARRED in cats,
            "summary": html_to_text(html),
            "thumbnail": thumbnail_url(it, html, link),
        })
    return {"items": out, "continuation": data.get("continuation") or ""}


def edit_tag(base_url: str, token: str, item_ids: list, *, add: str = "", remove: str = "") -> None:
    data = {"T": write_token(base_url, token), "i": list(item_ids)}
    if add:
        data["a"] = add
    if remove:
        data["r"] = remove
    _request(api_url(base_url, "/reader/api/0/edit-tag"), token=token, data=data)


def mark_all_read(base_url: str, token: str, stream_id: str, before_ts: int = 0) -> None:
    """Marks everything in the stream read up to before_ts (seconds; now if 0),
    so items that arrive while the user reads aren't swept up."""
    ts_us = int((before_ts or time.time()) * 1_000_000)
    _request(api_url(base_url, "/reader/api/0/mark-all-as-read"), token=token,
             data={"T": write_token(base_url, token), "s": stream_id, "ts": ts_us})


# ---------------------------------------------------------------- local state

def store_token(token: str) -> None:
    try:
        subprocess.run(
            ["secret-tool", "store", "--label=FreshRSS plugin token",
             "service", _KEYRING_SERVICE, "account", _KEYRING_ACCOUNT],
            input=token.encode("utf-8"), check=True, stderr=subprocess.PIPE)
    except (subprocess.CalledProcessError, FileNotFoundError) as exc:
        raise FreshRSSError(NO_KEYRING_MESSAGE) from exc


def load_token():
    result = subprocess.run(
        ["secret-tool", "lookup", "service", _KEYRING_SERVICE, "account", _KEYRING_ACCOUNT],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if result.returncode != 0:
        return None
    return result.stdout.decode("utf-8").strip() or None


def save_json_atomic(path: str, obj) -> None:
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f)
    os.replace(tmp, path)


def disconnect() -> None:
    subprocess.run(["secret-tool", "clear", "service", _KEYRING_SERVICE, "account", _KEYRING_ACCOUNT],
                   check=False)
    for path in (CONFIG_DIR, STATE_DIR):
        shutil.rmtree(path, ignore_errors=True)


def load_config() -> dict:
    with open(CONFIG_PATH) as f:
        return json.load(f)


# ---------------------------------------------------------------- CLI

def _main(argv: list) -> dict:
    if len(argv) < 2:
        raise FreshRSSError("no command given")
    command = argv[1]

    if command == "login":
        if len(argv) < 4:
            raise FreshRSSError("usage: login <base_url> <username> (API password on stdin)")
        base_url, username = normalize_base_url(argv[2]), argv[3]
        # One newline-terminated password per attempt on a persistent stdin
        # (see the QML Process): readline, never read().
        api_password = sys.stdin.readline().rstrip("\n")
        check_is_freshrss(base_url)
        token = login(base_url, username, api_password)
        store_token(token)
        os.makedirs(CONFIG_DIR, exist_ok=True)
        save_json_atomic(CONFIG_PATH, {"baseUrl": base_url, "username": username})
        return {"ok": True, "baseUrl": base_url}

    if command == "check-configured":
        try:
            cfg = load_config()
        except (OSError, ValueError):
            return {"configured": False, "baseUrl": ""}
        return {"configured": True, "baseUrl": cfg.get("baseUrl", ""), "username": cfg.get("username", "")}

    if command == "disconnect":
        disconnect()
        return {"ok": True}

    token = load_token()
    if token is None:
        raise FreshRSSError("not logged in")
    try:
        base_url = load_config()["baseUrl"]
    except (OSError, ValueError, KeyError) as exc:
        raise FreshRSSError("not configured") from exc

    if command == "overview":
        return overview(base_url, token)
    if command == "items":
        stream = argv[2] if len(argv) > 2 else READING_LIST
        unread_only = (argv[3] if len(argv) > 3 else "unread") == "unread"
        continuation = argv[4] if len(argv) > 4 else ""
        return items(base_url, token, stream, unread_only=unread_only, continuation=continuation)
    if command == "mark":
        if len(argv) < 4:
            raise FreshRSSError("usage: mark <read|unread|star|unstar> <itemId> [itemId...]")
        action, ids = argv[2], argv[3:]
        tags = {"read": {"add": READ}, "unread": {"remove": READ},
                "star": {"add": STARRED}, "unstar": {"remove": STARRED}}
        if action not in tags:
            raise FreshRSSError(f"unknown mark action {action}")
        edit_tag(base_url, token, ids, **tags[action])
        return {"ok": True, "action": action, "ids": ids}
    if command == "mark-all-read":
        stream = argv[2] if len(argv) > 2 else READING_LIST
        before = int(argv[3]) if len(argv) > 3 else 0
        mark_all_read(base_url, token, stream, before)
        return {"ok": True, "stream": stream}
    raise FreshRSSError(f"unknown command {command}")


if __name__ == "__main__":
    try:
        print(json.dumps(_main(sys.argv)))
    except FreshRSSError as exc:
        print(json.dumps({"error": str(exc)}))
        sys.exit(1)
    except Exception as exc:  # the UI can only read JSON, so report crashes as JSON too
        print(json.dumps({"error": f"backend error: {exc}"}))
        sys.exit(1)
