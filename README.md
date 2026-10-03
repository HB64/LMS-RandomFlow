# Random Flow 1.0

First public release.

Random Flow is a dynamic music-mixing plugin for [Lyrion Music Server](https://lyrion.org/) (formerly Logitech Media Server). It builds and sustains a continuous, filtered mix for a player - picking tracks (or whole albums) from your library based on per-player rules, and keeping the queue topped up automatically as you listen.

## Why another mixing plugin?

To be clear up front: this isn't about SugarCube or MusicIP being a problem - I'm actually the candidate to take over SugarCube's own maintenance, and MusicIP and Bliss are both very good at what they do, acoustic-similarity-based mixing. For my own listening, though, that approach kept giving me mixes that didn't match what I had in mind. Random Flow takes a different, rule-based approach instead - filters, artist weighting, cooldowns - built directly on Lyrion's own library database rather than an external similarity engine. Not a replacement for SugarCube/MusicIP, just a different tool for a different preference.

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

## Usage

See the [Usage Guide](https://github.com/HB64/LMS-RandomFlow/blob/main/USAGE.md) for a full walkthrough of the Live page - Auto Mix, Mix Settings, the queue and more.

## Limitations

- **Artist/Album cooldowns need a large, varied library to work well.** A cooldown excludes an artist (or album) entirely for N tracks after it last played. The smaller or less varied your library (or the narrower your active filter), the sooner that exclusion starts eating into most of what's left to pick from - so on a small collection you'll hit the practical ceiling of what the cooldown can do much faster than on a large one.

## Requirements

Logitech Media Server / Lyrion Music Server 7.9 or later.

## Translations

Currently available in English and Dutch. Translations for other languages are welcome - open a pull request against `strings.txt` in the repo.

## License

GPLv2 - see [LICENSE](https://github.com/HB64/LMS-RandomFlow/blob/main/LICENSE).
