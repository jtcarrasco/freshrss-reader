# FreshRSS for Omarchy

*Work in progress.* A FreshRSS client for the Omarchy bar: unread count on the icon,
categories and articles in a themed dropdown, and read/starred state synced both ways
with your self-hosted FreshRSS server through its Google Reader-compatible API.

*An independent client. Not affiliated with or endorsed by the FreshRSS project.*

## Requirements
- A FreshRSS server with **API access enabled** (Settings → Authentication) and an
  **API password** set for your user (Settings → Profile). The plugin uses the API
  password, not your web login password.
- `python3`, `secret-tool` and a running keyring (gnome-keyring on minimal installs).

## Development
```
uv run --with pytest python -m pytest tests
```

## License
MIT, see [LICENSE](LICENSE).
