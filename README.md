# Bee Swarm Server Hop (Deobf/Readable)


Core capabilities:
- Enumerates public servers and teleports to the next suitable one
- Between hops, scans for Sprouts, Vicious Bee (with level and gifted filters), Windy Bee (with level filters), optional Fireflies
- Skips blacklisted fields
- Optional Discord webhook when a target is found
- Optional in-game notification when a target is found
- Persists visited JobIds to avoid re-joining the same server

s
## File(s)
- serverhop_deobf.lua — main, readable script


## Requirements
- Roblox exploit/executor that supports:
  - HTTP requests for Discord webhook (http_request, syn.request or request)
  - isfile/readfile/writefile (optional) for visited server persistence
- Roblox client with access to Bee Swarm Simulator

Webhook only works when the executor provides an HTTP request API. The script falls back to Roblox HttpService for the Roblox games API (server list), but not for webhooks.


## Quick Start
1) Configure flags (set _G values) in your executor.
2) Load the script from raw GitHub.

Example:

```lua
-- Configure what you want to detect and how long to wait per server
_G.sprouts = true
_G.rarity = { Basic = false, Rare = true, Moon = true, Gummy = true, ["Epic+"] = true }
_G.detecttimeout = 12  -- seconds to scan a server before hopping
_G.notify = true       -- in-game notification when found

-- Optional: Discord webhook (requires http_request/syn.request)
_G.webhook = "https://discord.com/api/webhooks/..."

-- Load from your repo raw URL (update to your repo and path)
loadstring(game:HttpGet("https://raw.githubusercontent.com/<user>/<repo>/main/serverhop_deobf.lua"))()
```


## Configuration Flags (set before loading)
- cannon (boolean, default false)
  - Reserved for movement/cannon behavior; not currently used by this build.
- walkspeed (number, default nil)
  - If set, applies Humanoid.WalkSpeed when the character is available.
- movement (string, default "Walk")
  - Placeholder for movement style; not currently used by this build.
- tweenspeed (number, default 6)
  - Placeholder for tween speed; not currently used by this build.
- blacklistedfields (table<string>, default {})
  - Field names to ignore when detecting targets. Example: {"Mountain Top Field"}
- fireflies (boolean, default false)
  - Enable Fireflies detection.
- webhook (string, default nil)
  - Discord webhook URL to receive embeds when a target is detected. Requires executor HTTP API.
- notify (boolean, default true)
  - Show an in-game notification via StarterGui:SetCore when a target is detected.
- detecttimeout (number, default 25)
  - Seconds to wait/scout in a server for targets before hopping to another.

Target toggles and filters:
- sprouts (boolean, default false)
  - Enable Sprout detection.
- rarity (table<string, boolean>, default { Basic = true, Rare = true, Moon = true, Gummy = true, ["Epic+"] = true })
  - Sprout rarities to include. Keys recognized: "Basic", "Rare", "Moon", "Gummy", "Epic+".
- vicious (boolean, default false)
  - Enable Vicious Bee detection.
- giftedonly (boolean, default false)
  - When true, only report Gifted Vicious Bee.
- viciousmin (number, default 1)
- viciousmax (number, default 20)
  - Level bounds for Vicious Bee.
- windy (boolean, default false)
  - Enable Windy Bee detection.
- windymin (number, default 1)
- windymax (number, default 25)
  - Level bounds for Windy Bee.


## Behavior and Internals
- Per-server scan window is detecttimeout seconds; the script polls approximately every 1s.
- When the first matching target is found, the script:
  - Sends an in-game notification (if notify = true)
  - Sends a Discord embed (if webhook is provided and HTTP request API is available)
  - Stays in the current server (no immediate hop)
- Server selection prefers the least populated suitable server by default.
- Visited servers are remembered in serverhop_visited.json (if isfile/readfile/writefile are available) to avoid rejoining.


## Examples
- Epic+ sprouts only, shorter scan, notify and webhook:
```lua
_G.sprouts = true
_G.rarity = { Basic = false, Rare = false, Moon = false, Gummy = true, ["Epic+"] = true }
_G.detecttimeout = 8
_G.notify = true
_G.webhook = "https://discord.com/api/webhooks/..."
loadstring(game:HttpGet("https://raw.githubusercontent.com/<user>/<repo>/main/serverhop_deobf.lua"))()
```

- Gifted Vicious Bee between levels 6 and 12:
```lua
_G.vicious = true
_G.giftedonly = true
_G.viciousmin = 6
_G.viciousmax = 12
loadstring(game:HttpGet("https://raw.githubusercontent.com/<user>/<repo>/main/serverhop_deobf.lua"))()
```

- Windy Bee only, level 5–15, disable notifications:
```lua
_G.windy = true
_G.windymin = 5
_G.windymax = 15
_G.notify = false
loadstring(game:HttpGet("https://raw.githubusercontent.com/<user>/<repo>/main/serverhop_deobf.lua"))()
```

- Blacklist specific fields (skip detections from these fields):
```lua
_G.blacklistedfields = {"Mountain Top Field", "Pepper Patch"}
loadstring(game:HttpGet("https://raw.githubusercontent.com/<user>/<repo>/main/serverhop_deobf.lua"))()
```

- Apply walk speed:
```lua
_G.walkspeed = 70
loadstring(game:HttpGet("https://raw.githubusercontent.com/<user>/<repo>/main/serverhop_deobf.lua"))()
```


## Notes and Limitations
- Webhook requires an executor function (http_request/syn.request/request). Without it, webhooks are skipped.
- Field detection uses a best-effort nearest-zone heuristic based on Workspace zones and may not always be exact.
- Some configuration flags (cannon, movement, tweenspeed) are placeholders in this build.
- Roblox may rate-limit server list queries; the script pages through results as needed.
- The script will not rejoin the current JobId and tries to avoid previously visited JobIds.


## Troubleshooting
- No in-game notifications: ensure notify = true and StarterGui:SetCore is available in your executor environment.
- No webhook messages: ensure your executor supports HTTP and the webhook URL is correct; webhooks are only attempted when a requester is available.
- Not detecting targets: increase detecttimeout, ensure the relevant toggles are true, and check blacklistedfields/ranges.


## License
Use at your own risk. This code is provided for educational purposes without warranty.
