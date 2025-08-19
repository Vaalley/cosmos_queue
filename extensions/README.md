# Cosmos Queue Browser Extension (Chrome + Firefox)

This cross-browser MV3 extension lets you add the current YouTube or SoundCloud track to your Cosmos Queue host with one click or via right-click context menus.

- Location: `extensions/`
- Default server: `http://localhost:5283`
- Endpoint used: `POST /append-queue` with JSON `{ "url": string, "device_name": string }`

## Load in Chrome
1. Open `chrome://extensions`
2. Enable "Developer mode"
3. Click "Load unpacked" and select the `extensions/` folder
4. Pin the extension (optional)

## Load in Firefox (temporary add-on)
1. Open `about:debugging#/runtime/this-firefox`
2. Click "Load Temporary Add-on" and choose any file inside `extensions/` (e.g., `manifest.json`)

Note: Firefox MV3 requires v109+.

## Configure
1. Click the extension icon -> Options
2. Set:
   - Server base URL (e.g., `http://<host-ip>:5283` if the host runs elsewhere)
   - Device name (shown in the queue as "added by")
3. Use "Test connection" to hit `/health`

## Use
- From the popup: "Add current tab" or paste a URL.
- Right-click on a YouTube/SoundCloud page or link -> "Add to Cosmos Queue".

## Server integration
The host app (see `lib/main.dart`) listens on port `5283` and handles `POST /append-queue` JSON:

```
{ "url": "https://youtu.be/...", "device_name": "Browser" }
```

For YouTube: `videoId` is parsed from the URL. For SoundCloud: the full URL is used.

## Notes
- If the server runs on a different machine, ensure it is reachable from the browser and update the Server base URL accordingly.
- Notifications require permission; if notifications fail (e.g., missing icon), the extension falls back silently.
