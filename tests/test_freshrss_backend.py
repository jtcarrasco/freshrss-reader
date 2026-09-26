import json
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch
from urllib.parse import parse_qs

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import freshrss_backend as fb  # noqa: E402


def fake_response(body):
    resp = MagicMock()
    resp.__enter__.return_value.read.return_value = body if isinstance(body, bytes) else json.dumps(body).encode()
    return resp


def test_normalize_base_url():
    assert fb.normalize_base_url(" rss.example.com/ ") == "http://rss.example.com"
    assert fb.normalize_base_url("https://rss.example.com/api/greader.php") == "https://rss.example.com"
    assert fb.normalize_base_url("https://rss.example.com/i/") == "https://rss.example.com"


def test_check_is_freshrss_accepts_ok_and_rejects_other_pages():
    with patch.object(fb, "urlopen", return_value=fake_response(b"OK")):
        fb.check_is_freshrss("http://rss")
    with patch.object(fb, "urlopen", return_value=fake_response(b"<html>glance</html>")):
        with pytest.raises(fb.FreshRSSError, match="API isn't enabled"):
            fb.check_is_freshrss("http://rss")


def test_login_parses_auth_line_and_sends_form():
    captured = {}

    def fake_urlopen(request, timeout):
        captured["url"] = request.full_url
        captured["body"] = parse_qs(request.data.decode())
        return fake_response(b"SID=x\nLSID=null\nAuth=user/abc123\n")

    with patch.object(fb, "urlopen", side_effect=fake_urlopen):
        token = fb.login("http://rss", "jason", "apipw")
    assert token == "user/abc123"
    assert captured["url"] == "http://rss/api/greader.php/accounts/ClientLogin"
    assert captured["body"] == {"Email": ["jason"], "Passwd": ["apipw"]}


def test_overview_groups_feeds_by_category_with_counts():
    subs = {"subscriptions": [
        {"id": "feed/1", "title": "Beta", "categories": [{"id": "user/-/label/Tech", "label": "Tech"}], "iconUrl": "i1"},
        {"id": "feed/2", "title": "alpha", "categories": [{"id": "user/-/label/Tech", "label": "Tech"}]},
        {"id": "feed/3", "title": "Loose", "categories": []},
    ]}
    counts = {"unreadcounts": [
        {"id": "feed/1", "count": 3}, {"id": "feed/2", "count": "2"},
        {"id": "user/-/label/Tech", "count": 5}, {"id": fb.READING_LIST, "count": 9},
    ]}
    with patch.object(fb, "_get_json", side_effect=[subs, counts]):
        out = fb.overview("http://rss", "tok")
    assert out["totalUnread"] == 9
    tech = [c for c in out["categories"] if c["label"] == "Tech"][0]
    assert tech["unread"] == 5
    assert [f["title"] for f in tech["feeds"]] == ["alpha", "Beta"]
    assert any(c["label"] == "Uncategorized" for c in out["categories"])


def test_items_shapes_entries_and_excludes_read_by_default():
    data = {"continuation": "c2", "items": [{
        "id": "tag:google.com,2005:reader/item/1", "title": "Hello", "published": 1790000000,
        "canonical": [{"href": "https://x/1"}], "origin": {"streamId": "feed/1", "title": "X"},
        "categories": [fb.STARRED], "summary": {"content": "<p>Hi <b>there</b></p>"}}]}
    with patch.object(fb, "_get_json", return_value=data) as get:
        out = fb.items("http://rss", "tok", "user/-/label/Tech")
    path = get.call_args[0][2]
    assert path.startswith("/reader/api/0/stream/contents/user%2F-%2Flabel%2FTech?")
    assert "xt=user%2F-%2Fstate%2Fcom.google%2Fread" in path
    it = out["items"][0]
    assert it["url"] == "https://x/1" and it["starred"] and not it["read"]
    assert it["summary"] == "Hi there"
    assert out["continuation"] == "c2"


def test_edit_tag_sends_write_token_ids_and_tag():
    captured = {}

    def fake_request(url, token=None, data=None, timeout=15):
        captured["url"], captured["data"] = url, data
        return b"OK"

    with patch.object(fb, "write_token", return_value="T123"), patch.object(fb, "_request", side_effect=fake_request):
        fb.edit_tag("http://rss", "tok", ["id1", "id2"], add=fb.READ)
    assert captured["url"].endswith("/reader/api/0/edit-tag")
    assert captured["data"] == {"T": "T123", "i": ["id1", "id2"], "a": fb.READ}


def test_mark_all_read_uses_microsecond_timestamp():
    captured = {}
    with patch.object(fb, "write_token", return_value="T"), \
         patch.object(fb, "_request", side_effect=lambda url, token=None, data=None, timeout=15: captured.update(data=data) or b"OK"):
        fb.mark_all_read("http://rss", "tok", "user/-/label/Tech", before_ts=1790000000)
    assert captured["data"]["ts"] == 1790000000 * 1_000_000
    assert captured["data"]["s"] == "user/-/label/Tech"


def test_store_token_reports_missing_keyring():
    err = fb.subprocess.CalledProcessError(1, ["secret-tool"])
    with patch("freshrss_backend.subprocess.run", side_effect=err):
        with pytest.raises(fb.FreshRSSError, match="no system keyring"):
            fb.store_token("tok")


def test_html_to_text_drops_scripts():
    assert fb.html_to_text("<p>One</p><script>alert(1)</script><p>Two</p>") == "One\n\nTwo"


def test_check_is_freshrss_explains_other_servers():
    from urllib.error import HTTPError
    with patch.object(fb, "urlopen", side_effect=HTTPError("u", 401, "no", {}, None)):
        with pytest.raises(fb.FreshRSSError, match="doesn't look like a FreshRSS server"):
            fb.check_is_freshrss("http://abs")


def test_thumbnail_prefers_image_enclosure():
    item = {"enclosure": [{"href": "https://x/audio.mp3", "type": "audio/mpeg"},
                          {"href": "https://x/cover.png", "type": "image"}]}
    assert fb.thumbnail_url(item, '<img src="https://x/inline.jpg">', "https://x/post") == "https://x/cover.png"


def test_thumbnail_falls_back_to_first_real_img():
    html = ('<img src="https://t/pixel.gif" width="1" height="1">'
            '<img src="data:image/png;base64,AAAA">'
            '<p><img src="/media/hero.webp" alt=""></p>')
    assert fb.thumbnail_url({}, html, "https://blog.example/post/1") == "https://blog.example/media/hero.webp"


def test_thumbnail_skips_formats_qt_cant_decode():
    assert fb.thumbnail_url({}, '<img src="https://x/a.avif">', "https://x/") == ""
    assert fb.thumbnail_url({}, "<p>no images</p>", "https://x/") == ""


def test_favicon_url_rebuilt_on_connected_server():
    base = "https://rss.example:8080"
    assert fb.favicon_url("https://rss.example/f.php?h=abc", base) == "https://rss.example:8080/f.php?h=abc"
    assert fb.favicon_url("/f.php?h=abc", base) == "https://rss.example:8080/f.php?h=abc"
    assert fb.favicon_url("https://cdn.example/icon.png", base) == "https://cdn.example/icon.png"
    assert fb.favicon_url("", base) == ""

