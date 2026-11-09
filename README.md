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
| `status` | | Returns screen, tab, title and player position |
| `play` | `id`, `type`, optional `season` + `episode`, optional `fromStart` | Plays a movie, the next-up episode, or a specific episode |
| `resume` | optional `id` | Resumes a Continue Watching title, or unpauses the player |
| `pause` / `stop` | | Pauses or closes the player |
| `seek` | `seconds` (absolute) or `by` (relative) | Moves the playhead |
| `open` | `id`, `type` | Opens a title's details page |
| `search` | `query` | Opens Search with the query typed in |
| `tab` / `home` / `back` | `name` for `tab` | Navigates |
| `continue` | | Lists Continue Watching |
| `sync` | | Forces a Chao Sync pull and push |

Ids are IMDb ids (`tt...`); `type` is `movie` or `series`.

## Building

There is no local Mac. Every push to `main` that touches code builds an **unsigned IPA** on GitHub's hosted Xcode 27 runner ([`.github/workflows/build-tvos.yml`](.github/workflows/build-tvos.yml), about 18 minutes). The workflow runs [`scripts/build-ipa.sh`](scripts/build-ipa.sh) and uploads the IPA as the `chao-tv-ipa` artifact. The IPA is then signed for the Apple TV with a sideload-signing service and installed.

On a Mac you can build locally with Xcode 27, [mise](https://mise.jdx.dev) and [Tuist](https://tuist.dev): run `mise install`, then `bash scripts/build-ipa.sh`.

## Keeping up with upstream

The `upstream` remote is `bobsupra/NuvioTVOS`. Chao TV's changes are kept small and mostly confined to `Core/ChaoTV*` plus a few marked hooks (search for `Chao TV`), so upstream fixes can be merged in.

## Changelog

- **2026-11-09**
  - Forked from NuvioTVOS 3.5.0 (build 81).
  - CI builds unsigned IPAs.
  - Rebranded to Chao TV.
  - Top tab bar.
  - No sign-in, profiles, Watch Party or Calendar.
  - Added the agent link and Chao Sync (in testing).

## License

GPL-3.0, see [LICENSE](LICENSE). Original work © the NuvioTVOS and Nuvio contributors; Chao TV changes © 2026 digi-magi.
