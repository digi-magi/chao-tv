# Chao TV

A house-built streaming app for **Apple TV** (`tvosApp/`, fork of NuvioTVOS) and **Google TV** (`android/`, fork of [NuvioMedia/NuvioTV](https://github.com/NuvioMedia/NuvioTV), GPL-3.0). Both talk to the same house hub, so watch progress follows you between TVs.

A house-built Apple TV streaming app: simple, Omni-style, and made for one household's setup. Chao TV is a fork of [NuvioTVOS](https://github.com/bobsupra/NuvioTVOS), which is GPL-3.0, so this fork is GPL-3.0 too. The upstream project's README is kept at [docs/UPSTREAM-README.md](docs/UPSTREAM-README.md).

It plays from Stremio-compatible add-ons, mainly a self-hosted local-cache add-on. The house agent ("Chao") can drive it directly through a built-in agent link, with no remote-control button presses and no screenshots.

## How it differs from upstream

| Area | Chao TV |
|---|---|
| Name / bundle id | Chao TV, `com.digimagi.chaotv`, URL scheme `chaotv://` |
| Navigation | Top tab bar (Home, Search, Library, Settings), not the sidebar |
| Accounts | No sign-in screen; one shared household profile, entered automatically |
| Removed | Watch Party, Calendar, profile picker, Account settings, third-party integrations (Simkl, MDBList, WeTrakr, Trakt, AI subtitles, metadata providers, Debrid, P2P, SMB, Usenet, Jellyfin) |
| Streams | Only via the house cache add-on, whose upstream resolves through Real-Debrid; the in-app BitTorrent engine is hard-disabled |
| Branding | Chao TV icon, Top Shelf and wordmark: the house agent's Chao drawn as green phosphor LED dots (the Chao is Sega's, from the Chao Adventure 2 VMU sprite sheet; fan use); "Nuvio" replaced by "Chao TV" in every UI string and all translations |
| Playback | Auto Select Stream on by default, so play and resume start immediately |
| Sync | **Chao Sync**: watch progress, Library and watched marks shared by every Chao TV in the house (Apple TV and Google TV) |
| Agent link | **ChaoLink**: the house agent can open, play, pause, seek and read state |
| Updates | Update and announcement checks point at this repo, not upstream |

The house switches live in [`tvosApp/NuvioTV/Sources/Core/ChaoTV.swift`](tvosApp/NuvioTV/Sources/Core/ChaoTV.swift). The new code lives in [`Core/ChaoTV/`](tvosApp/NuvioTV/Sources/Core/ChaoTV/).

## The house hub

Chao Sync and ChaoLink talk to a small hub at `/chaotv` on the same server as the stream add-on. The app finds the hub itself by trying each installed add-on's origin, so no address is built into the app. The hub runs inside the self-hosted cache add-on, which is not part of this repo.

| Endpoint | Used by | Purpose |
|---|---|---|
| `GET /chaotv/<table>?since=<ms>` | app | Pull rows changed since the last pull. Tables: `progress`, `library`, `watched`. `since` is the hub's receive time |
| `PUT /chaotv/<table>` | app | Push changed rows (newest `updatedAt` wins; deletes are tombstones). Library keys are `type:id`; watched keys are `type:id` or `type:id:season:episode` |
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
| `library` | optional `action` (`add` default, `remove`, `toggle`) | Adds "this" (the title on screen or playing) to Library |
| `watched` / `unwatched` | optional `scope` (`title`, `episode`, `season`, `upto`), `season`, `episode` | Marks "this" title, the playing episode, a season, or everything up to an episode |
| `forget` | | Removes "this" from Continue Watching |
| `tracks` | | Lists audio and subtitle tracks of what's playing |
| `audio` / `subtitle` | `id` or `language` (`subtitle id=off` turns them off) | Switches tracks |
| `next` | | Next episode |
| `setting` | `key`, optional `value` | Reads or writes one app setting |
| `toast` | `text` | Shows a popup on the TV |
| `screen` / `press` | `label` for `press` | Fallback: reads the on-screen accessibility labels, or presses a button by name |
| `sync` | | Forces a Chao Sync pull and push |
| `addon` | `url` | Installs or re-enables an add-on by manifest URL |
| `addons` | | Lists installed add-ons and whether catalogs (Cinemeta) are on |

Ids are IMDb ids (`tt...`); `type` is `movie` or `series`. "This" is the title on the open details page, or what is playing; any of those commands also accepts an explicit `id` and `type`. Every action shows a small "done" popup on the TV, such as "Added Blue Planet II to Library".

## Google TV (android/)

- **Source:** `android/` is NuvioMedia/NuvioTV (dev branch) added as a squashed git subtree. Update it with `git subtree pull --prefix=android https://github.com/NuvioMedia/NuvioTV.git dev --squash`.
- **House changes:** live in `android/app/src/main/java/com/nuvio/tv/chao/`.
  - `ChaoTv.kt`: switches and first-run defaults (no sign-in QR, Advanced mode, Modern layout, Auto Play on the first stream).
  - `ChaoSync.kt`: the same `/chaotv/progress` wire format as tvOS. Seconds on the wire, milliseconds locally.
  - `ChaoLink.kt`: the same agent commands.
  - Elsewhere, edits are marked `Chao TV`: app id `com.digimagi.chaotv`, "Nuvio" renamed in all string resources, the account/profile/Watch Party/Integration/Tracking settings hidden, P2P forced off, and LED-Chao icons and banners.
- **Build:** `.github/workflows/build-android.yml` runs on GitHub's Ubuntu runner and produces the `chao-tv-apk` artifact. It is signed with the committed house key `android/chao/chaotv-release.p12` (see `android/chao/README.md`), so updates install over the previous version with `adb install -r`.

## Building

There is no local Mac. Every push to `main` that touches code builds an **unsigned IPA** on GitHub's hosted Xcode 27 runner ([`.github/workflows/build-tvos.yml`](.github/workflows/build-tvos.yml), about 18 minutes). The workflow runs [`scripts/build-ipa.sh`](scripts/build-ipa.sh) and uploads the IPA as the `chao-tv-ipa` artifact. The IPA is then signed for the Apple TV with a sideload-signing service and installed.

On a Mac you can build locally with Xcode 27, [mise](https://mise.jdx.dev) and [Tuist](https://tuist.dev): run `mise install`, then `bash scripts/build-ipa.sh`.

## Keeping up with upstream

The `upstream` remote is `bobsupra/NuvioTVOS`. Chao TV's changes are kept small and mostly confined to `Core/ChaoTV*` plus a few marked hooks (search for `Chao TV`), so upstream fixes can be merged in.

## Changelog

### Apple TV build 9 + Google TV build 3 (in progress)
- **Library and watched-mark sync** between all Chao TVs. Adding, removing or marking something watched on one TV shows up on the others.
- **Google TV:** the agent link always acts on the screen in front (a deep link no longer leaves a hidden second copy holding the link).

### Google TV build 1
- First Android TV build: NuvioTV dev with all the Chao changes.
  - Rename, plus icons and banners.
  - Omni-style **top tab bar** instead of the sidebar.
  - No sign-in or onboarding screens.
  - Slim Settings, no P2P.
  - Auto Play on the first stream.
  - **Chao Sync** with the Apple TV.
  - The **agent link**, with the same commands, including `library`, `watched`, `unwatched` and `forget` on "this", and on-screen confirmations.

### Build 7 (superseded by build 8: launch screen)
- **New icon:** the house Chao in green LED dots, matching the rack-panel face (App Icon, Top Shelf, wordmark, and the launch screen, which still flashed the Nuvio logo).
- **Appearance:** the Sidebar section (Calendar and Watch Party toggles) is gone.
- **Server side, no app change needed:**
  - "Popular Anime" and "Top Rated Anime" Home rows from the hub's Chao Anime catalog.
  - The Omni library and history were imported.
  - Hub progress sync now delivers late-arriving history.

### Build 6
- **Do-it commands on "this":** add to or remove from Library, mark the title, episode, season or "up to here" watched or unwatched, remove from Continue Watching. These act on whatever is open or playing, with no button pressing.
- **Player control:** list and switch audio and subtitle tracks (including subtitles off) and skip to the next episode.
- **On-TV popups:** every agent action shows a short confirmation in the top corner.
- **Settings:** read or write a single app setting.
- **Fallback:** `screen` and `press` read on-screen labels and press a button by name, for anything without a direct command.

### Build 5
- **Full rebrand:** every on-screen "Nuvio" is now "Chao TV" (132 strings in code, 1,549 translations), with an original icon, Top Shelf banner and wordmark.
- **Settings slimmed down:**
  - Account & Profiles page removed.
  - Integrations now shows only Add-ons. Simkl, MDBList, WeTrakr, Trakt, AI subtitles, metadata providers (TMDB/MDBList keys), Debrid, P2P, SMB, Usenet and Jellyfin are hidden.
- **No P2P from the TV:** the in-app BitTorrent engine is hard-disabled (`ChaoTV.allowsP2P`).

### Build 4
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
