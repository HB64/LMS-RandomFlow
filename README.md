# Random Flow

A dynamic music-mixing plugin for [Lyrion Music Server](https://lyrion.org/) (formerly Logitech Media Server). Random Flow builds and sustains a continuous, filtered mix for a player - picking tracks (or whole albums) from your library based on per-player rules, and keeping the queue topped up automatically as you listen.

Modeled on [SugarCube](https://github.com/HB64/lms-sugarcube)'s mixing approach, rebuilt from scratch around a SQL-based track selector.

## Features

- **Auto Mix** - starts and continuously sustains a mix per player; "Start New Mix" grabs a fresh pick on demand.
- **Filters** - genre groups, artist filters and year ranges, with a per-player quick-block list.
- **Weighting** - preferred/less preferred artists, with a "Wobble" control for how strictly that weighting is applied.
- **Cooldowns** - artist and album cooldowns (in tracks) to avoid repeats.
- **Songs mode and Album Mix mode** - mix single tracks, or whole albums at a time.
- **Batch mode** - queue a configurable batch of tracks at once, with Top Up and Replace Track/Album.
- **Don't Stop The Music integration** - two selectable DSTM providers (RandomFlow Mix, RandomFlow Batch) for players that prefer DSTM's own on/off switch over Auto Mix.
- **Live page** - a real-time (cometd-based) web UI: now playing, queue, transport controls, rejected-tracks and history panels, and live Mix Settings.
- **SqueezeClient / Jive settings menu** - Auto Mix, Mix Mode, Filter, Wobble, Batch Size, Max Play Count and both cooldowns are also reachable from Lyrion Jive clients (e.g. Android Auto).

## Installation

### Via the plugin manager (recommended)

1. In Lyrion, go to **Settings → Plugins → Additional Repositories**.
2. Add:
   ```
   https://raw.githubusercontent.com/HB64/LMS-RandomFlow/main/repository.xml
   ```
3. Random Flow will appear in the plugin list, ready to install. Future updates are picked up the same way.

### Manual installation

1. Download the latest release zip from the [Releases page](https://github.com/HB64/LMS-RandomFlow/releases).
2. Unzip it into your Lyrion `Plugins` folder, so you end up with a `Plugins/RandomFlow/` folder containing `Plugin.pm`.
3. Restart Lyrion.

## Requirements

Logitech Media Server / Lyrion Music Server 7.9 or later.

## License

See [LICENSE](LICENSE).
