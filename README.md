# Chao TV

A house-built Apple TV streaming app: simple, Omni-style, and made for one household's setup. Chao TV is a fork of [NuvioTVOS](https://github.com/bobsupra/NuvioTVOS), which is GPL-3.0, so this fork is GPL-3.0 too. The upstream project's README is kept at [docs/UPSTREAM-README.md](docs/UPSTREAM-README.md).

It plays from Stremio-compatible add-ons, mainly a self-hosted local-cache add-on. The house agent ("Chao") can drive it directly through a built-in agent link, with no remote-control button presses and no screenshots.

## How it differs from upstream

| Area | Chao TV |
|---|---|
| Name / bundle id | Chao TV, `com.digimagi.chaotv`, URL scheme `chaotv://` |
| Navigation | Top tab bar (Home, Search, Library, Settings), not the sidebar |
| Accounts | No sign-in screen; one shared household profile, entered automatically |
| Removed | Watch Party, Calendar, profile picker |
| Playback | Auto Select Stream on by default, so play and resume start immediately |
| Progress | **Chao Sync**: watch progress shared by every Chao TV in the house |
| Agent link | **ChaoLink**: the house agent can open, play, pause, seek and read state |
| Updates | Update and announcement checks point at this repo, not upstream |

The house switches live in [`tvosApp/NuvioTV/Sources/Core/ChaoTV.swift`](tvosApp/NuvioTV/Sources/Core/ChaoTV.swift). The new code lives in [`Core/ChaoTV/`](tvosApp/NuvioTV/Sources/Core/ChaoTV/).

## The house hub

Chao Sync and ChaoLink talk to a small hub at `/chaotv` on the same server as the stream add-on. The app finds the hub itself by trying each installed add-on's origin, so no address is built into the app. The hub runs inside the self-hosted cache add-on, which is not part of this repo.

| Endpoint | Used by | Purpose |
|---|---|---|
| `GET /chaotv/progress?since=<ms>` | app | Pull progress changed since the last pull |
| `PUT /chaotv/progress` | app | Push changed progress rows (newest `lastWatchedAt` wins; deletes are tombstones) |
| `GET /chaotv/link/poll?device=<name>` | app | Long-poll (25 s) for agent commands |
| `POST /chaotv/link/result` | app | Report a command's outcome |
| `POST /chaotv/link/state` | app | Report what is on screen (after each command and every 15 s) |
| `POST /chaotv/cmd` | agent | Send a command to a device, optionally waiting for the result |
| `GET /chaotv/devices` | agent | List connected devices and their last state |

### Agent commands

Send them as `{"cmd": "...", "args": {...}}`.

| Command | Args | Does |
|---|---|---|
| `status` | | Returns screen, tab, title, player position, search results, Continue Watching and catalog state |
| `play` | `id`, `type`, optional `season` + `episode`, optional `fromStart` | Plays a movie, the next-up episode, or a specific episode |
| `resume` | optional `id` | Resumes a Continue Watching title, or unpauses the player |
| `pause` / `stop` | | Pauses or closes the player |
| `seek` | `seconds` (absolute) or `by` (relative) | Moves the playhead |
| `open` | `id`, `type` | Opens a title's details page |
| `search` | `query` | Opens Search with the query typed in |
| `tab` / `home` / `back` | `name` for `tab` | Navigates |
| `continue` | | Lists Continue Watching |
| `sync` | | Forces a Chao Sync pull and push |
| `addon` | `url` | Installs or re-enables an add-on by manifest URL |
| `addons` | | Lists installed add-ons and whether catalogs (Cinemeta) are on |

Ids are IMDb ids (`tt...`); `type` is `movie` or `series`.

## Building

There is no local Mac. Every push to `main` that touches code builds an **unsigned IPA** on GitHub's hosted Xcode 27 runner ([`.github/workflows/build-tvos.yml`](.github/workflows/build-tvos.yml), about 18 minutes). The workflow runs [`scripts/build-ipa.sh`](scripts/build-ipa.sh) and uploads the IPA as the `chao-tv-ipa` artifact. The IPA is then signed for the Apple TV with a sideload-signing service and installed.

On a Mac you can build locally with Xcode 27, [mise](https://mise.jdx.dev) and [Tuist](https://tuist.dev): run `mise install`, then `bash scripts/build-ipa.sh`.

## Keeping up with upstream

The `upstream` remote is `bobsupra/NuvioTVOS`. Chao TV's changes are kept small and mostly confined to `Core/ChaoTV*` plus a few marked hooks (search for `Chao TV`), so upstream fixes can be merged in.

## Changelog

### Build 4 (in progress)
- **Fix (upstream bug):** installing the first add-on switched Cinemeta off silently, which emptied search ("No searchable catalogs") and dropped metadata. Cinemeta now stays on unless it is turned off explicitly.
- **Agent link:** new `addon` and `addons` commands, and `status` now reports what's on screen (search results, Continue Watching, catalog state), so the agent doesn't need screenshots.
- **First install without any navigation:** `chaotv://addon?url=<manifest>` adds the first add-on. The agent link then connects by itself, because it finds the hub through that add-on.

### Build 3 (2026-11-09, `08633243e`)
- **Agent link (back door):** the app keeps a live connection to the house hub. The agent can `play` (including a specific season and episode), `resume`, `pause`, `seek`, `stop`, `open`, `search`, switch tabs, list Continue Watching and read the current screen and player state.
- **Chao Sync:** watch progress is shared across every Chao TV in the house. The newest progress wins, removals sync too, and it runs on launch, when the app comes back to the foreground and every 60 s.
- **Auto Select Stream** is on by default, so play and resume start without the source picker.
- **`chaotv://` deep links** work like the `nuvio://` ones.

### Build 2 (2026-11-09, `e96a291f6`)
- Renamed to **Chao TV** (bundle id `com.digimagi.chaotv`).
- Omni-style **top tab bar** instead of the sidebar.
- **No sign-in screen** and **no profile picker**: one shared household profile.
- **Watch Party and Calendar removed.**
- Update and announcement checks point at this repo.

### Build 1 (2026-11-09, `4d5e7f5c0`)
- Forked from NuvioTVOS 3.5.0 (build 81).
- GitHub Actions builds an unsigned IPA on the Xcode 27 runner.
- Stock app verified on the Apple TV playing a 1080p MKV from the house cache.

## License

GPL-3.0, see [LICENSE](LICENSE). Original work © the NuvioTVOS and Nuvio contributors; Chao TV changes © 2026 digi-magi.
