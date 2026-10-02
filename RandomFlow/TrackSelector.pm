package TrackSelector;

#
# TrackSelector - picks tracks directly from Lyrion's own library.db
# (catalog: tracks/genres/artists) plus persist.db (APC's
# alternativeplaycount table for real-time playcount/skip data, and
# Lyrion's native tracks_persistent table for rating).
#
# This is the successor to the old MixEngine.pm (which called
# bliss-mixer's HTTP API). It does not use bliss-mixer, bliss-analyser
# or bliss.db at all - no acoustic similarity, purely metadata-driven,
# so there is no candidate-list cap and no exhaustion risk: every call
# searches the full eligible catalog fresh.
#
# DESIGN (agreed with Henk, 20-09-2026):
#   1. HARD constraints (must match, no exceptions) - mirrors
#      recipes.xml's <constraint max="0">/<constraint cutoff="0">:
#        - genreGroup:    track's genre must be one of the given list
#        - artistBlock:   track's artist must NOT be one of the given list
#        - artistCooldownTracks: track's artist must NOT appear among the
#                          N most-recently-played tracks (per
#                          playCountProvider's lastPlayed, across the whole
#                          library - NOT just tracks this mix itself has
#                          picked) - checked HARD, before any weighting, so a
#                          "preferred" artist can never repeat sooner than
#                          this just because of a high preference weight
#                          (added 20-09-2026 after Henk pointed out the
#                          same repeat-too-soon problem we saw in bliss-mixer
#                          would otherwise resurface here; CHANGED 24-09-2026
#                          from a day-based window - "not played in the last
#                          N days" - to this track-count-based one - "not
#                          among the last N tracks played" - Henk's own
#                          request, since a fixed number-of-days window
#                          behaves very differently depending on how much is
#                          being played that day)
#        - albumCooldownTracks: same idea as artistCooldownTracks above, but
#                          for the track's ALBUM instead of its artist -
#                          identified by Lyrion's own numeric album id
#                          (t.album), never by album title, so two
#                          different artists' albums that happen to share
#                          a name are never confused with each other. Also
#                          checked HARD, before weighting, for the same
#                          reason as artistCooldownTracks. This lets an
#                          artist come back sooner than their albums do -
#                          e.g. artistCooldownTracks=20 + albumCooldownTracks
#                          =100 means "this artist" can repeat after 20
#                          tracks, but "this exact album" only after 100
#                          (added 24-09-2026, Henk's own request - the
#                          "artist may return, the album may not" case from
#                          his 23-09-2026 message)
#        - maxPlaycount:  track's playCount (per playCountProvider) must be
#                          <= this (undef = no limit)
#        - playCountProvider: which playCount/lastPlayed source to use for
#                          maxPlaycount, artistCooldownTracks AND
#                          albumCooldownTracks above -
#                          'lyrion' (tracks_persistent), 'apc'
#                          (alternativeplaycount), or 'both' (default) -
#                          Henk confirmed 20-09-2026 that "both" means the
#                          HIGHEST of the two values (never SUM - both
#                          providers hook the same real playback events, so
#                          summing would double-count), treating a source
#                          with no data as simply absent rather than 0.
#                          AUTO-DEGRADE (added 21-09-2026, widened
#                          22-09-2026): a Lyrion version upgrade has now
#                          TWICE briefly left persist.db in a state this
#                          module couldn't fully use - first just APC's
#                          own alternativeplaycount table missing, then
#                          (22-09-2026) the whole ATTACHed 'p' connection
#                          itself going stale after persist.db got
#                          rebuilt out from under it, taking Lyrion's OWN
#                          tracks_persistent table down too. Either way
#                          this used to crash every query outright - "no
#                          such table", mix refused to start, alarm
#                          missed. Now every selectTracks() call checks
#                          fresh whether alternativeplaycount AND
#                          tracks_persistent each actually exist
#                          (_apcAvailable()/_tracksPersistentAvailable()),
#                          and if even checking that fails (the stale-
#                          connection case), automatically DETACHes and
#                          re-ATTACHes persist.db once and retries before
#                          giving up. Whichever of the two tables turns
#                          out missing is simply left out of the query
#                          (no JOIN, no column reference) rather than
#                          referenced and crashing - playCount/lastPlayed
#                          degrade to whichever source(s) are actually
#                          reachable (both missing -> no constraint at
#                          all, same "absent = no constraint" treatment
#                          this file already uses everywhere else), and
#                          excludeRatings is skipped entirely if
#                          tracks_persistent isn't reachable (no rating
#                          data to filter by right now). All logged once
#                          per state change, not spammed per track; it
#                          re-checks every call, so everything resumes
#                          automatically the moment persist.db is healthy
#                          again - no restart of this plugin needed.
#        - excludeRatings: track's normalized 1-5 rating must NOT be one of these
#        - excludeUrls:   track's own URL must not be one of these (e.g. to
#                          avoid immediately re-picking the current/just-played seed)
#        - genreGroup is ALWAYS a hard SQL filter, no exceptions - Henk
#                          confirmed 20-09-2026 that a track outside the
#                          selected genres must never be picked, full stop.
#                          (This module briefly had a "Style"/genreStrictness
#                          dial that turned genre into a soft preference
#                          instead - removed the same day: once genre stays
#                          hard no matter what, wobble below already covers
#                          "how much randomness within the selection", so
#                          Style had nothing left to do.)
#        - filterArtists: a filter can ALSO name specific artists
#                          (Henk, 20-09-2026) - a track matches the hard
#                          filter if its genre is in genreGroup OR its
#                          artist matches one of these (partial/substring
#                          match, case-insensitive, so a collaboration
#                          like "Ajna (5) & Dronny Darko" is included by
#                          just naming "Ajna"). This is additive, not a
#                          second hard AND-constraint: naming an artist
#                          here means "also always include this artist,
#                          regardless of genre" - confirmed with Henk,
#                          who wants it exactly that way round. If
#                          BOTH genreGroup and filterArtists are empty,
#                          this is still "no constraint" (whole library),
#                          same as genreGroup alone always was.
#        - yearRanges:    a filter can ALSO restrict which years a track
#                          may be from (Henk, 25-09-2026 - a gap noticed
#                          while designing the Live page: discussed
#                          earlier but never actually built). Each entry
#                          is either a single year ("1985") or an
#                          inclusive range ("1980-1989"); a track matches
#                          if its year falls in ANY of the given entries
#                          (OR between entries), but - UNLIKE
#                          filterArtists above - this is a genuinely
#                          SEPARATE hard AND-constraint on top of the
#                          genreGroup/filterArtists match, not an
#                          OR-widener (Henk confirmed 25-09-2026: "AND
#                          klinkt het meest logisch"). Empty/absent means
#                          no year restriction at all, same "no
#                          constraint" convention as everything else
#                          here. Resolved from the active filter's
#                          `years` field the same way genreGroup/
#                          filterArtists are - see Settings::Util::
#                          resolveFilterYears and Settings/Basic.pm's own
#                          design notes on the `years` field for the
#                          text-entry syntax and parsing/validation.
#   2. From the tracks surviving those hard constraints, a random pool of
#      up to poolSize (Henk's "ask size", default 300) is drawn straight
#      from SQLite (ORDER BY RANDOM()). Raised from a fixed 50 to a
#      configurable 300 default on 20-09-2026: with a very broad filter the
#      full hard-filtered set can be thousands of tracks, and a sample of
#      just 50 made preferredWeight barely noticeable in practice. 300 is
#      still trivially fast (an unfiltered ~35,000-row query measured well
#      under half a second).
#   3. SOFT weighting is then applied in plain Perl on that pool -
#      NOT as a mathematical formula inside the SQL query (deliberately
#      simple, per Henk: SugarCube's own preferred/less-preferred-artist
#      fields are the model, not a weighted-sampling formula). Since
#      24-09-2026 the actual per-artist multiplier matches SugarCube's own
#      documented weight scale exactly (confirmed with Henk, same design
#      as SugarCube's Artist Weighting, README section "How It Works -
#      Artist Weighting and Floating Wobble"):
#        - preferredArtists / preferredWeight (1-5):    multiplier = weight + 1
#          (weight 1 -> ~2x as likely, weight 5 -> ~6x as likely)
#        - lessPreferredArtists / lessPreferredWeight (1-5): multiplier = 1 / (weight + 1)
#          (weight 1 -> ~2x LESS likely (half), weight 5 -> ~6x less likely)
#        - everyone/everything else: weight 1 (neutral)
#      A raw weight value equal to the multiplier itself (the pre-24-09-2026
#      behaviour) meant the slider's lowest useful setting (1) had NO effect
#      at all for either field, since 1 == neutral - that didn't match
#      SugarCube's own behaviour and is why this was revisited.
#      Those weights are combined per track, then "wobble" (0-100, default
#      0 = "Tight", confirmed 20-09-2026 - inspired by SugarCube's Wobble,
#      reinterpreted since we have no ranked similarity list to pick a
#      window from) blends that combined weight towards 1 for everyone as
#      wobble rises - at 0 the configured weights count fully, at 100
#      they're ignored and the pick is pure random (but always still from
#      within the hard genre/artist-block/cooldown-filtered pool - wobble
#      never lets a track outside those hard constraints in). When nothing
#      is actually weighted (no preferred/less-preferred artists
#      configured), every track already has weight 1 and wobble has
#      nothing to flatten - that is expected, not a gap (Henk confirmed
#      20-09-2026).
#      A track is then picked from the pool with probability proportional
#      to its (wobble-adjusted) weight, without replacement, until `count`
#      tracks are chosen.
#
# RATING NORMALIZATION (agreed with Henk, 20-09-2026): Henk's data has a
# mix of two scales in tracks_persistent.rating - mostly already 1-5,
# but a couple of tracks at 99/100 (Lyrion's native 0-100 star scale).
# We always normalize to 1-5: a value already <=5 is used as-is; a
# value >5 is divided by 20 and rounded to the nearest whole number.
#
# NOT yet included here (still to be designed/ported separately):
#   - album repeat-spacing (SugarCube's AlbumTracker) - now covered via
#     albumCooldownTracks (see the design notes above), added 24-09-2026,
#     same track-count-based approach as artistCooldownTracks
#   - the full recipes.xml-style DSL (overlap()/abs()/strlen()/seed
#     cross-references, RecipeFilterEngine.pm's existing constraint/
#     modifier evaluator) - this module only implements the specific,
#     agreed-on fields above; RecipeFilterEngine.pm's more general
#     parser can be wired in on top of this later if needed.
#
# ALBUM MODE (Henk, 29-09-2026): selectAlbums() below is the album-mix
# counterpart to selectTracks() - same hard constraints/weighting, but
# candidate tracks are collapsed to distinct albums (one surviving track
# is enough, no minimum-match-count) and weighted by the album's own
# contributor instead of a track's. Once an album is picked, ALL of its
# tracks come back, unfiltered, in disc/track order.
#

use strict;
use warnings;

use Slim::Schema;
use Slim::Utils::Log;

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.trackselector',
    'defaultLevel' => 'INFO',
});

# Adjust this if your persist.db ever lives somewhere else inside the
# container - this is the path confirmed working on Henk's server.
use constant PERSIST_DB_PATH => '/config/prefs/persist.db';

# Default for poolSize ("ask size") when the caller doesn't specify one.
# See point 2 above for why 300, not the original 50.
use constant DEFAULT_POOL_SIZE => 300;

# Hard cap on how many rows findRejectedTracks() below ever returns for
# actual display, regardless of how many tracks really got excluded -
# Henk confirmed 25-09-2026 that an uncapped list is impractical at a
# poolSize of 300 (SC's own "MIP Response" list has the same problem,
# per its own comment - "can run to dozens of rows"). The exact total
# is still reported separately (see totalCount below) so the UI can
# show "and N more" rather than silently truncating.
use constant REJECTED_LIST_CAP => 100;

# findRecentlyPlayed() below (Live page's "History" panel, added
# 25-09-2026, Henk) - default and hard-cap for the "how many recently
# played tracks to show" setting (Settings/Basic.pm's historyDisplayCount
# pref). Unlike REJECTED_LIST_CAP, the effective count here IS user-
# configurable (the whole point of the setting) - MAX_HISTORY_DISPLAY_COUNT
# is only a safety clamp against an impractically large saved value,
# same "unbounded is impractical" reasoning as REJECTED_LIST_CAP's own
# comment. Deliberately NOT a three-state pref like historyLimit's own
# undef/''/N (see Settings/Basic.pm) - "no limit" doesn't mean anything
# safe here (that would be every track Lyrion has ever recorded a
# lastPlayed for), so blank/unset just falls back to the default and
# there is no separate "unlimited" state at all.
use constant DEFAULT_HISTORY_DISPLAY_COUNT => 20;
use constant MAX_HISTORY_DISPLAY_COUNT     => 200;

my $persistAttached = 0;

# Tracks the last _tableAvailable() result per table name, purely so
# state CHANGES get logged once instead of every single call - see
# _tableAvailable() below.
my %lastTableAvailable;

# selectTracks(%criteria) -> arrayref of { url, title, artist, albumId, playCount, rating }
#
# %criteria:
#   genreGroup        => arrayref of genre names (required - pass all
#                         genres to effectively disable genre filtering).
#                         ALWAYS a hard filter - a track outside this list
#                         is never picked, no exceptions (Henk confirmed
#                         20-09-2026; this module briefly had a "Style"
#                         soft-genre mode, removed the same day).
#   filterArtists     => arrayref of artist-name substrings (optional) -
#                         a track whose artist contains one of these
#                         (case-insensitive) is included REGARDLESS of
#                         genreGroup - additive, not a second AND
#                         constraint (Henk confirmed 20-09-2026).
#   yearRanges        => arrayref of "YYYY" or "YYYY-YYYY" entries
#                         (optional) - a track's year must match at least
#                         one of these. UNLIKE filterArtists, this IS a
#                         second, independent hard AND-constraint on top
#                         of genreGroup/filterArtists (Henk confirmed
#                         25-09-2026). Empty/absent = no year constraint.
#   artistBlock       => arrayref of artist names to hard-exclude (optional)
#   artistCooldownTracks => integer number of tracks; any artist who
#                         appears among the N most-recently-played tracks
#                         (per playCountProvider's lastPlayed, library-wide -
#                         not just tracks this mix picked) is hard-excluded,
#                         same as artistBlock (optional, undef/0 = no cooldown)
#   albumCooldownTracks => integer number of tracks; same idea as
#                         artistCooldownTracks, but for the track's album
#                         (matched by Lyrion's numeric album id, not title -
#                         see the design notes above) (optional, undef/0 =
#                         no cooldown). Independent from artistCooldownTracks -
#                         set both to let an artist repeat sooner than any
#                         one of their specific albums does.
#   maxPlaycount      => integer, or undef for no playcount limit
#   playCountProvider => 'lyrion' | 'apc' | 'both' (default 'both' - highest
#                         of the two values; see note above)
#   excludeRatings    => arrayref of normalized 1-5 ratings to hard-exclude (optional)
#   excludeUrls       => arrayref of track URLs to hard-exclude (optional)
#   preferredArtists      => arrayref of artist names (optional)
#   preferredWeight       => number, default 1 (only matters if preferredArtists given)
#   lessPreferredArtists  => arrayref of artist names (optional)
#   lessPreferredWeight   => number, default 1 (only matters if lessPreferredArtists given)
#   wobble            => 0-100, default 0 ("Tight" - configured weights
#                         count fully). 100 ("Loose") ignores all weights,
#                         picking uniformly at random from the pool. See
#                         point 3 in the design notes above.
#   poolSize          => integer, default DEFAULT_POOL_SIZE (300) - Henk's
#                         "ask size": how many candidates to sample before
#                         the weighted pick.
#   count             => how many tracks to return, default 1
#
sub selectTracks {
    my (%criteria) = @_;

    my $dbh = Slim::Schema->dbh;
    if (!$dbh) {
        $log->error("TrackSelector: could not get Slim::Schema->dbh");
        return [];
    }

    _attachPersistDb($dbh);

    my $playCountProvider = $criteria{playCountProvider} || 'both';

    # Checked fresh on every call, deliberately not cached for the life
    # of the process - see the AUTO-DEGRADE design note above. Cheap: a
    # single indexed sqlite_master lookup each, self-healing if even that
    # fails (a stale ATTACHed connection).
    my $apcAvailable = _apcAvailable($dbh);
    my $tpAvailable  = _tracksPersistentAvailable($dbh);

    # Merge recently-played artists/albums (cooldowns) into the hard
    # artistBlock/albumBlock lists - BEFORE any weighting, so a
    # "preferred" artist who was just played is still excluded. Shared
    # with selectAlbums() below - see _mergeCooldownBlocks().
    _mergeCooldownBlocks(\%criteria, $dbh, $playCountProvider, $apcAvailable, $tpAvailable);

    my $poolSize = defined $criteria{poolSize} ? $criteria{poolSize} : DEFAULT_POOL_SIZE;

    # Genre is always a hard SQL filter - one plain query, no soft/tiered
    # mode (that existed briefly as "Style"/genreStrictness, removed
    # 20-09-2026 - see the design notes at the top of this file).
    my ($sql, @bindValues) = _buildPoolQuery(%criteria, poolSize => $poolSize, apcAvailable => $apcAvailable, tpAvailable => $tpAvailable);
    my $pool = eval { $dbh->selectall_arrayref($sql, { Slice => {} }, @bindValues) };
    if ($@) {
        $log->error("TrackSelector: query failed: $@");
        return [];
    }

    if (!@$pool) {
        $log->warn("TrackSelector: no tracks survived the hard constraints - pool is empty.");
        return [];
    }

    my $count = $criteria{count} || 1;

    return _weightedPick(
        $pool,
        $count,
        $criteria{preferredArtists}     || [],
        $criteria{preferredWeight}      || 1,
        $criteria{lessPreferredArtists} || [],
        $criteria{lessPreferredWeight}  || 1,
        $criteria{wobble} || 0,
    );
}

# selectAlbums(%criteria) -> arrayref of
#   { albumId, albumTitle, albumArtist, albumYear,
#     tracks => [ { url, title, artist, albumId }, ... ] }
#
# Album Mix mode (Henk, 29-09-2026): the album-mix counterpart to
# selectTracks() above. Same %criteria and hard constraints, but
# candidate TRACKS are collapsed to distinct ALBUMS (one surviving
# track is enough to make the album a candidate - no minimum-match-
# count, Henk confirmed). Weighting (preferredArtists/wobble) uses the
# album's own contributor (Lyrion's "album artist"), not whichever
# track happened to survive the filter. Once an album is picked, ALL of
# its tracks come back, unfiltered, in disc/track order - the point is
# the real album, not a filtered subset of it.
#
# One extra criterion beyond selectTracks():
#   excludeAlbumIds => arrayref of album ids to hard-exclude (e.g. the
#                       currently playing album, when picking a
#                       replacement for the upcoming one)
sub selectAlbums {
    my (%criteria) = @_;

    my $dbh = Slim::Schema->dbh;
    if (!$dbh) {
        $log->error("TrackSelector: could not get Slim::Schema->dbh");
        return [];
    }

    _attachPersistDb($dbh);

    my $playCountProvider = $criteria{playCountProvider} || 'both';
    my $apcAvailable = _apcAvailable($dbh);
    my $tpAvailable  = _tracksPersistentAvailable($dbh);

    _mergeCooldownBlocks(\%criteria, $dbh, $playCountProvider, $apcAvailable, $tpAvailable);

    my $poolSize = defined $criteria{poolSize} ? $criteria{poolSize} : DEFAULT_POOL_SIZE;

    my ($sql, @bindValues) = _buildAlbumPoolQuery(%criteria, poolSize => $poolSize, apcAvailable => $apcAvailable, tpAvailable => $tpAvailable);
    my $pool = eval { $dbh->selectall_arrayref($sql, { Slice => {} }, @bindValues) };
    if ($@) {
        $log->error("TrackSelector: album query failed: $@");
        return [];
    }

    if (!@$pool) {
        $log->warn("TrackSelector: no albums survived the hard constraints - pool is empty.");
        return [];
    }

    my $count = $criteria{count} || 1;

    # _weightedPick() reads $row->{artist} - the album pool query already
    # aliases the album's own contributor to that same key, so this is
    # reused unchanged from selectTracks() above.
    my $picked = _weightedPick(
        $pool,
        $count,
        $criteria{preferredArtists}     || [],
        $criteria{preferredWeight}      || 1,
        $criteria{lessPreferredArtists} || [],
        $criteria{lessPreferredWeight}  || 1,
        $criteria{wobble} || 0,
    );

    my @albums;
    for my $row (@$picked) {
        push @albums, {
            albumId     => $row->{albumId},
            albumTitle  => $row->{albumTitle},
            albumArtist => $row->{artist},
            albumYear   => $row->{albumYear},
            tracks      => _albumTracks($dbh, $row->{albumId}),
        };
    }

    return \@albums;
}

# findRejectedTracks(%criteria) -> { tracks => arrayref, totalCount => N }
#
# For the Live page's "Afgewezen tracks" panel (added 25-09-2026, Henk).
# NOT the same thing as SC's "MIP Response" - that's the surviving
# CANDIDATE POOL (matched the hard filters, just not the one auto-picked
# this round). This is the genuine opposite: tracks that DID match the
# base genre/filterArtists criteria but got excluded by one of the SOFT
# criteria - manually blocked artist, artist cooldown, album cooldown,
# maxPlaycount, or an excluded rating - together with WHICH of those
# reasons applied to each one.
#
# Deliberately mirrors _buildPoolQuery()'s hard-filter block (genre/
# filterArtists) but INVERTS the soft-filter block into an OR instead of
# several ANDs: a track only needs to fail ONE soft criterion to show up
# here, and _every_ criterion it fails gets its own reason string, not
# just the first one found - a track can rightly show up with more than
# one reason (e.g. both "Artist cooldown" and "Max playcount").
#
# Capped at REJECTED_LIST_CAP rows for the actual list (Henk confirmed
# 25-09-2026: unbounded is impractical at a poolSize of 300), but
# totalCount is always the real, uncapped count, via a separate
# COUNT(DISTINCT ...) query - so the UI can say "and N more" instead of
# just cutting the list off silently.
#
# Artist/album cooldown blocklists are resolved the SAME way selectTracks()
# above resolves them (via _recentlyPlayedArtists/_recentlyPlayedAlbums),
# but kept in their OWN sets here rather than merged into a single
# artistBlock/albumBlock like selectTracks() does - purely so the reason
# text can tell "Manually blocked artist" apart from "Artist cooldown"
# for the same row.
sub findRejectedTracks {
    my (%criteria) = @_;

    my $dbh = Slim::Schema->dbh;
    if (!$dbh) {
        $log->error("TrackSelector: could not get Slim::Schema->dbh");
        return { tracks => [], totalCount => 0 };
    }

    _attachPersistDb($dbh);

    my $playCountProvider = $criteria{playCountProvider} || 'both';
    my $apcAvailable = _apcAvailable($dbh);
    my $tpAvailable  = _tracksPersistentAvailable($dbh);

    my $manualArtistBlock = $criteria{artistBlock} || [];

    my $cooldownArtists = [];
    if (defined $criteria{artistCooldownTracks} && $criteria{artistCooldownTracks} > 0) {
        $cooldownArtists = _recentlyPlayedArtists($dbh, $criteria{artistCooldownTracks}, $playCountProvider, $apcAvailable, $tpAvailable);
    }
    my $cooldownAlbums = [];
    if (defined $criteria{albumCooldownTracks} && $criteria{albumCooldownTracks} > 0) {
        $cooldownAlbums = _recentlyPlayedAlbums($dbh, $criteria{albumCooldownTracks}, $playCountProvider, $apcAvailable, $tpAvailable);
    }

    my $playCountExpr = _playCountExpr($playCountProvider, $apcAvailable, $tpAvailable);
    my $ratingExpr = $tpAvailable
        ? '(CASE WHEN tp.rating > 5 THEN ROUND(tp.rating / 20.0) ELSE tp.rating END)'
        : 'NULL';
    my $apcJoin = $apcAvailable ? 'LEFT JOIN p.alternativeplaycount apc ON apc.urlmd5 = t.urlmd5' : '';
    my $tpJoin  = $tpAvailable  ? 'LEFT JOIN p.tracks_persistent tp ON tp.urlmd5 = t.urlmd5'       : '';

    # Same hard base match as _buildPoolQuery() - a track has to be a
    # candidate for this mix's genre/artist criteria at all before it can
    # be "rejected" from it. No filter configured at all -> nothing to
    # report (same "no constraint" convention as _buildPoolQuery()).
    my $genreGroup    = $criteria{genreGroup}    || [];
    my $filterArtists = $criteria{filterArtists} || [];
    my (@orParts, @orBind);
    if (@$genreGroup) {
        push @orParts, 'g.name IN (' . join(',', ('?') x @$genreGroup) . ')';
        push @orBind, @$genreGroup;
    }
    if (@$filterArtists) {
        push @orParts, '(' . join(' OR ', ('c.name LIKE ? COLLATE NOCASE') x @$filterArtists) . ')';
        push @orBind, map { '%' . $_ . '%' } @$filterArtists;
    }
    return { tracks => [], totalCount => 0 } unless @orParts;

    my @where = ('t.audio = 1', '(' . join(' OR ', @orParts) . ')');
    my @bind  = @orBind;

    # yearRanges is treated the same as genreGroup here: part of what
    # makes a track a candidate for this mix at all, not one of the
    # soft/invertible reject reasons below - a track outside the
    # configured years was never a real candidate, same as one outside
    # the genre (see _yearWhereClause's own comment and the design notes
    # at the top of this file).
    my ($yearWhere, @yearBind) = _yearWhereClause($criteria{yearRanges});
    if ($yearWhere) {
        push @where, $yearWhere;
        push @bind, @yearBind;
    }

    # The soft-filter block, INVERTED into an OR: failing any ONE of
    # these is enough to be "rejected". If none of these criteria are
    # even configured, nothing can be rejected by them - report empty
    # rather than a query with no exclusion condition at all.
    my (@rejectParts, @rejectBind);
    if (@$manualArtistBlock) {
        push @rejectParts, 'c.name IN (' . join(',', ('?') x @$manualArtistBlock) . ')';
        push @rejectBind, @$manualArtistBlock;
    }
    if (@$cooldownArtists) {
        push @rejectParts, 'c.name IN (' . join(',', ('?') x @$cooldownArtists) . ')';
        push @rejectBind, @$cooldownArtists;
    }
    if (@$cooldownAlbums) {
        push @rejectParts, 't.album IN (' . join(',', ('?') x @$cooldownAlbums) . ')';
        push @rejectBind, @$cooldownAlbums;
    }
    if (defined $criteria{maxPlaycount}) {
        push @rejectParts, "$playCountExpr > ?";
        push @rejectBind, $criteria{maxPlaycount};
    }
    my $excludeRatings = $criteria{excludeRatings} || [];
    if (@$excludeRatings && $tpAvailable) {
        push @rejectParts, "(tp.rating IS NOT NULL AND $ratingExpr IN (" . join(',', ('?') x @$excludeRatings) . '))';
        push @rejectBind, @$excludeRatings;
    }
    return { tracks => [], totalCount => 0 } unless @rejectParts;

    push @where, '(' . join(' OR ', @rejectParts) . ')';
    push @bind, @rejectBind;

    my $fromClause = qq{
        FROM tracks t
        LEFT JOIN genre_track gt ON gt.track = t.id
        LEFT JOIN genres g ON g.id = gt.genre
        LEFT JOIN contributors c ON c.id = t.primary_artist
        $apcJoin
        $tpJoin
        WHERE } . join("\n          AND ", @where);

    my $totalCount = eval {
        $dbh->selectrow_array(qq{ SELECT COUNT(DISTINCT t.id) $fromClause }, undef, @bind);
    };
    if ($@) {
        $log->error("TrackSelector: findRejectedTracks count query failed: $@");
        return { tracks => [], totalCount => 0 };
    }

    # t.coverid, added 25-09-2026 (Henk's request - "een hoesje erbij zou
    # mooi zijn"): a real column on tracks (confirmed against the real
    # slimserver source, Slim::Schema::Track - accessor is coverid(),
    # backed by the plain _coverid column), but LAZILY computed - it can
    # still read NULL for a track that has real embedded/folder artwork
    # if nothing has ever called ->coverid on it to trigger that
    # computation (the raw column update happens on first ACCESS, not at
    # scan time, per that same source). Selected as-is, no special-casing
    # for that here - live.html already treats a missing coverid as "no
    # thumbnail, show the placeholder instead" for the Queue panel's own
    # rows (see tstQueueRowCoverUrl), same graceful degradation as every
    # other optional field this function already returns (rating/
    # playCount can be NULL too, for the same "AUTO-DEGRADE" reasons
    # documented at the top of this file).
    my $rows = eval {
        $dbh->selectall_arrayref(qq{
            SELECT t.id AS trackId, t.url, t.title, c.name AS artist, t.album AS albumId, t.coverid AS coverId, $playCountExpr AS playCount, $ratingExpr AS rating
            $fromClause
            GROUP BY t.id
            ORDER BY t.title COLLATE NOCASE
            LIMIT } . REJECTED_LIST_CAP, { Slice => {} }, @bind);
    };
    if ($@) {
        $log->error("TrackSelector: findRejectedTracks query failed: $@");
        return { tracks => [], totalCount => 0 };
    }

    # Reason-tag each row in Perl by comparing against the SAME resolved
    # sets used to build the SQL above - guarantees the displayed reasons
    # always match the actual exclusion logic, rather than re-deriving
    # them (possibly incorrectly) from the raw row data alone.
    my %manualArtistSet   = map { lc($_) => 1 } @$manualArtistBlock;
    my %cooldownArtistSet = map { lc($_) => 1 } @$cooldownArtists;
    my %cooldownAlbumSet  = map { $_ => 1 } @$cooldownAlbums;
    my %excludeRatingSet  = map { $_ => 1 } @$excludeRatings;

    for my $row (@$rows) {
        my @reasons;
        my $artistKey = lc($row->{artist} // '');
        push @reasons, 'Manually blocked artist' if $manualArtistSet{$artistKey};
        push @reasons, 'Artist cooldown'         if $cooldownArtistSet{$artistKey};
        push @reasons, 'Album cooldown'          if defined $row->{albumId} && $cooldownAlbumSet{$row->{albumId}};
        push @reasons, 'Max playcount'           if defined $criteria{maxPlaycount} && defined $row->{playCount} && $row->{playCount} > $criteria{maxPlaycount};
        push @reasons, 'Excluded rating'         if defined $row->{rating} && $excludeRatingSet{$row->{rating}};
        $row->{reasons} = \@reasons;
    }

    return { tracks => $rows, totalCount => $totalCount };
}

# findRecentlyPlayed(%args) -> { tracks => arrayref, totalCount => N, unavailable => 0|1 }
#
# For the Live page's "History" panel (added 25-09-2026, Henk). NOT a
# port of SC-EXTMIP's own History panel - Henk agreed 25-09-2026 this
# should genuinely diverge: SC's History is its OWN queue-time-logged
# SQLite table (SaveHistory records a track the moment MixRunner ADDS it
# to the queue, not when it's actually played), and it never stores a
# track id at all - confirmed by reading Breakout.pm's GrabHistory/
# SaveHistory - so SC's own panel can't offer a "use as next" action the
# way this one does. This function instead reads Lyrion's OWN lastPlayed
# tracking (tracks_persistent - the same table findRejectedTracks/
# selectTracks already use for rating/playcount), so it's a genuine
# "what did I actually just listen to" list, with a real track id to
# act on.
#
# Global, not per-mix-criteria: unlike findRejectedTracks, there's no
# genre/filterArtists scoping here - History shows what was actually
# played, regardless of which mix (or no mix at all) picked it.
#
# Requires tracks_persistent to exist at all - if it doesn't, there is
# no lastPlayed data anywhere to show, full stop, which is a different
# situation from "available, just nothing played yet" (unavailable => 1
# vs. an empty tracks list) - same AUTO-DEGRADE spirit as the rest of
# this file, just with its own flag since the two cases need different
# messages on the Live page.
sub findRecentlyPlayed {
    my (%args) = @_;

    my $limit = $args{limit};
    $limit = DEFAULT_HISTORY_DISPLAY_COUNT unless defined $limit && length $limit;
    $limit = 0                        if $limit < 0;
    $limit = MAX_HISTORY_DISPLAY_COUNT if $limit > MAX_HISTORY_DISPLAY_COUNT;
    return { tracks => [], totalCount => 0, unavailable => 0 } if $limit == 0;

    my $dbh = Slim::Schema->dbh;
    if (!$dbh) {
        $log->error("TrackSelector: could not get Slim::Schema->dbh");
        return { tracks => [], totalCount => 0, unavailable => 0 };
    }

    _attachPersistDb($dbh);

    my $playCountProvider = $args{playCountProvider} || 'both';
    my $apcAvailable = _apcAvailable($dbh);
    my $tpAvailable  = _tracksPersistentAvailable($dbh);

    return { tracks => [], totalCount => 0, unavailable => 1 } unless $tpAvailable;

    my $playCountExpr = _playCountExpr($playCountProvider, $apcAvailable, $tpAvailable);
    my $ratingExpr = '(CASE WHEN tp.rating > 5 THEN ROUND(tp.rating / 20.0) ELSE tp.rating END)';
    my $apcJoin = $apcAvailable ? 'LEFT JOIN p.alternativeplaycount apc ON apc.urlmd5 = t.urlmd5' : '';

    my $fromClause = qq{
        FROM tracks t
        LEFT JOIN contributors c ON c.id = t.primary_artist
        LEFT JOIN albums al ON al.id = t.album
        JOIN p.tracks_persistent tp ON tp.urlmd5 = t.urlmd5
        $apcJoin
        WHERE t.audio = 1 AND tp.lastPlayed IS NOT NULL
    };

    my $totalCount = eval {
        $dbh->selectrow_array(qq{ SELECT COUNT(DISTINCT t.id) $fromClause });
    };
    if ($@) {
        $log->error("TrackSelector: findRecentlyPlayed count query failed: $@");
        return { tracks => [], totalCount => 0, unavailable => 0 };
    }

    # t.coverid - same lazily-computed caveat as findRejectedTracks above
    # (see its own comment): can legitimately read NULL for a track that
    # does have real artwork if nothing has triggered the computation
    # yet. Same graceful "show the placeholder" degradation client-side.
    my $rows = eval {
        $dbh->selectall_arrayref(qq{
            SELECT t.id AS trackId, t.title, c.name AS artist, t.album AS albumId,
                   al.title AS albumTitle, al.year AS albumYear, t.coverid AS coverId,
                   tp.lastPlayed AS lastPlayed, $playCountExpr AS playCount, $ratingExpr AS rating
            $fromClause
            GROUP BY t.id
            ORDER BY tp.lastPlayed DESC
            LIMIT } . $limit, { Slice => {} });
    };
    if ($@) {
        $log->error("TrackSelector: findRecentlyPlayed query failed: $@");
        return { tracks => [], totalCount => 0, unavailable => 0 };
    }

    return { tracks => $rows, totalCount => $totalCount, unavailable => 0 };
}

# lastPlayedForTracks(@trackIds) -> { trackId => lastPlayedEpoch, ... }
#
# For the Live page's new Now Playing/Up Next stat lines (added 25-09-2026,
# THIRD round, Henk - "het uitgebreidere tekstveld met ratings, last played
# e.d. zoals bij SC"). Genre/rating/playcount all ride along on the page's
# existing cometd status push (Lyrion's own per-track tags: g/R/O) - "last
# played" is the one field with no tag at all, confirmed against the real
# LMS source (Slim::Control::Queries %tagMap - it's a blank line in that
# table's own comment column, unlike every other field around it), so it
# needs this own small lookup instead, same tracks_persistent source
# findRecentlyPlayed above already uses.
#
# Deliberately takes a plain list of ids rather than %criteria - this has
# nothing to do with mix criteria at all, it's a direct "give me these
# specific tracks' lastPlayed" lookup, called with at most two ids
# (current + next track) at a time.
sub lastPlayedForTracks {
    my (@trackIds) = @_;
    return {} unless @trackIds;

    my $dbh = Slim::Schema->dbh;
    if (!$dbh) {
        $log->error("TrackSelector: could not get Slim::Schema->dbh");
        return {};
    }

    _attachPersistDb($dbh);
    return {} unless _tracksPersistentAvailable($dbh);

    my $rows = eval {
        $dbh->selectall_arrayref(qq{
            SELECT t.id AS trackId, tp.lastPlayed AS lastPlayed
            FROM tracks t
            JOIN p.tracks_persistent tp ON tp.urlmd5 = t.urlmd5
            WHERE t.id IN (} . join(',', ('?') x @trackIds) . qq{)
        }, { Slice => {} }, @trackIds);
    };
    if ($@) {
        $log->error("TrackSelector: lastPlayedForTracks query failed: $@");
        return {};
    }

    my %result;
    for my $row (@$rows) {
        $result{ $row->{trackId} } = $row->{lastPlayed};
    }
    return \%result;
}

# albumIdForUrl($url) -> numeric album id, or undef
#
# Album Mix mode (Henk, 29-09-2026): resolves which album a given
# queued/playing track URL belongs to - used by MixRunner to exclude
# the currently playing album when picking or replacing the next one.
sub albumIdForUrl {
    my ($url) = @_;
    return undef unless defined $url && length $url;

    my $dbh = Slim::Schema->dbh;
    return undef unless $dbh;

    my $albumId = eval {
        $dbh->selectrow_array('SELECT album FROM tracks WHERE url = ?', undef, $url);
    };
    return undef if $@;
    return $albumId;
}

sub _attachPersistDb {
    my ($dbh) = @_;

    return if $persistAttached;

    eval {
        $dbh->do("ATTACH '" . PERSIST_DB_PATH . "' AS p");
    };
    if ($@ && $@ !~ /already in use/i) {
        $log->error("TrackSelector: could not ATTACH persist.db: $@");
        return;
    }

    $persistAttached = 1;
}

# Raw existence check for one table inside the attached 'p' (persist.db)
# schema. Returns 1/0 when the check itself worked, or undef when even
# THAT failed (e.g. "no such table: p.sqlite_master") - which doesn't
# mean the table is missing, it means the ATTACHed connection itself is
# unusable right now (seen for real 22-09-2026: persist.db got rebuilt
# out from under an already-open connection during a Lyrion upgrade).
# _tableAvailable() below is what tells those two cases apart and
# recovers from the second one.
sub _tableExistsInP {
    my ($dbh, $table) = @_;

    my $row = eval {
        $dbh->selectrow_arrayref(
            "SELECT name FROM p.sqlite_master WHERE type = 'table' AND name = ?", undef, $table
        );
    };
    return undef if $@;
    return $row ? 1 : 0;
}

# Checks whether a given table actually exists in the attached
# persist.db right now (added 21-09-2026 for alternativeplaycount,
# widened 22-09-2026 to any persist.db table - see the AUTO-DEGRADE
# design note at the top of this file). Deliberately NOT cached for the
# process lifetime - re-checked on every selectTracks() call, which is
# what lets things come back automatically once persist.db is healthy
# again, without needing this plugin restarted. Cheap: a single indexed
# sqlite_master lookup, not a full table scan. Only logs when the result
# actually CHANGES, so a long stretch of "still not there yet" doesn't
# spam the log once per track pick.
sub _tableAvailable {
    my ($dbh, $table) = @_;

    my $available = _tableExistsInP($dbh, $table);

    if (!defined $available) {
        # Checking existence itself failed - the ATTACHed connection is
        # stale, not just this one table missing. Try to recover once by
        # detaching and re-attaching, then retry this same check.
        $log->warn("TrackSelector: persist.db's ATTACHed connection looks stale (checking for '$table' failed) - re-attaching and retrying.");
        eval { $dbh->do("DETACH p") };
        $persistAttached = 0;
        _attachPersistDb($dbh);
        $available = _tableExistsInP($dbh, $table);
    }
    $available = 0 unless defined $available;

    my $last = $lastTableAvailable{$table};
    if (!$available && (!defined $last || $last)) {
        # Either the very first check ever came back missing, or it just
        # went missing after previously being there - worth a warning
        # either way.
        $log->warn("TrackSelector: persist.db's '$table' table not found (normal briefly after a Lyrion restart/upgrade while it's rebuilt/re-initialized) - queries needing it degrade for now. Will resume automatically once it reappears.");
    } elsif ($available && defined $last && !$last) {
        # Only worth announcing as a RECOVERY when it was actually
        # missing a moment ago - not on every ordinary first check.
        $log->info("TrackSelector: persist.db's '$table' table is present again - resuming normal use of it.");
    }
    $lastTableAvailable{$table} = $available;

    return $available;
}

sub _apcAvailable             { return _tableAvailable($_[0], 'alternativeplaycount'); }
sub _tracksPersistentAvailable { return _tableAvailable($_[0], 'tracks_persistent'); }

# Builds a SQL expression for the "effective" playCount or lastPlayed
# value, per the chosen provider. 'both' takes the HIGHEST of the two
# (never a sum - Lyrion's own tracking and APC both hook the same real
# playback events, so adding them would double-count the same plays),
# treating a source with no data as simply absent, not 0/never.
#
# The 'both' branch is wrapped in CAST(...AS INTEGER). This is not
# cosmetic: a bare CASE...END expression has no SQLite type affinity,
# so when it's later compared against a bound Perl parameter that
# DBD::SQLite happens to bind as TEXT (which it does for a plain
# scalar - it has nothing that tells it "this is a number"), SQLite
# falls back to raw storage-class ordering, where EVERY integer sorts
# below EVERY text value - regardless of the actual numbers involved.
# That silently broke both ">=" (cooldown lookups always came back
# empty) and, unmasked-but-unnoticed, "<=" (maxPlaycount would have
# let everything through, since integer <= text is always true).
# CAST(...AS INTEGER) gives the expression real INTEGER affinity, so
# SQLite coerces the other side to a number first, as expected.
sub _providerExpr {
    my ($provider, $lyrionCol, $apcCol, $apcAvailable, $tpAvailable) = @_;

    # $lyrionCol always references the 'tp' (tracks_persistent) alias,
    # $apcCol always references 'apc' (alternativeplaycount) - NEVER
    # reference either one unless that table is actually joined right
    # now (see _tableAvailable/AUTO-DEGRADE above), regardless of what
    # playCountProvider is configured. 'NULL' is a literal SQL NULL, not
    # a column reference - always safe.
    if ($provider eq 'lyrion') {
        return $tpAvailable ? $lyrionCol : 'NULL';
    }
    if ($provider eq 'apc') {
        return $apcAvailable ? $apcCol : 'NULL';
    }

    # 'both'
    return 'NULL'     if !$tpAvailable && !$apcAvailable;
    return $apcCol    if !$tpAvailable;
    return $lyrionCol if !$apcAvailable;

    return "CAST(CASE "
        . "WHEN $lyrionCol IS NULL AND $apcCol IS NULL THEN NULL "
        . "WHEN $lyrionCol IS NULL THEN $apcCol "
        . "WHEN $apcCol IS NULL THEN $lyrionCol "
        . "ELSE MAX($lyrionCol, $apcCol) END AS INTEGER)";
}

sub _playCountExpr { return _providerExpr($_[0], 'tp.playCount', 'apc.playCount', $_[1], $_[2]); }
sub _lastPlayedExpr { return _providerExpr($_[0], 'tp.lastPlayed', 'apc.lastPlayed', $_[1], $_[2]); }

# Returns an arrayref of distinct artist names found among the
# $trackCount most-recently-played tracks (per playCountProvider's
# effective lastPlayed, library-wide - this looks at Lyrion's overall
# play history, not just tracks this particular mix has picked). One
# plain upfront query, reused as a simple exclusion list - not a
# per-row subquery - so it stays fast and easy to follow.
#
# CHANGED 24-09-2026 (Henk's request) from a day-based time window
# ("lastPlayed >= cutoff") to this track-count window ("the N most
# recent lastPlayed timestamps, whichever artists own those tracks").
# A plain time window behaves very differently depending on how much
# gets played on a given day; counting back a fixed number of tracks
# instead gives a consistent-feeling cooldown regardless of how busy
# a day is. Implemented as an inner query that orders all tracks with
# a known lastPlayed by that timestamp descending and takes the first
# $trackCount rows, then reads off the distinct artist names from
# THAT set - not $trackCount distinct artists, $trackCount tracks
# (which may of course repeat an artist several times within the
# window, same as the real play history would).
sub _recentlyPlayedArtists {
    my ($dbh, $trackCount, $provider, $apcAvailable, $tpAvailable) = @_;

    $provider ||= 'both';
    my $lastPlayedExpr = _lastPlayedExpr($provider, $apcAvailable, $tpAvailable);

    # Only join a table when it's actually there right now (see
    # _tableAvailable/AUTO-DEGRADE above) - otherwise this query would
    # reference a table that doesn't exist, regardless of $provider. If
    # $lastPlayedExpr came back as the literal 'NULL' (neither source
    # reachable), the inner query's WHERE clause naturally matches
    # nothing ("NULL IS NOT NULL" is always false) - no special-casing
    # needed, it just means "we don't know who was recently played, so
    # don't exclude anyone for it right now".
    my $apcJoin = $apcAvailable ? 'LEFT JOIN p.alternativeplaycount apc ON apc.urlmd5 = t.urlmd5' : '';
    my $tpJoin  = $tpAvailable  ? 'LEFT JOIN p.tracks_persistent tp ON tp.urlmd5 = t.urlmd5'       : '';

    my $rows = eval {
        $dbh->selectcol_arrayref(qq{
            SELECT DISTINCT recent.artist
            FROM (
                SELECT c.name AS artist, $lastPlayedExpr AS lastPlayed
                FROM tracks t
                JOIN contributors c ON c.id = t.primary_artist
                $apcJoin
                $tpJoin
                WHERE c.name IS NOT NULL
                  AND $lastPlayedExpr IS NOT NULL
                ORDER BY $lastPlayedExpr DESC
                LIMIT ?
            ) recent
        }, undef, $trackCount);
    };
    if ($@) {
        $log->error("TrackSelector: could not fetch recently played artists: $@");
        return [];
    }

    return $rows || [];
}

# Same as _recentlyPlayedArtists above, but for albums (albumCooldownTracks,
# added 24-09-2026) - identified by Lyrion's own numeric t.album id, NEVER
# by album title, so two different artists' albums that happen to share a
# name are never confused with each other. No JOIN needed for this one
# (album is a plain column on tracks itself), unlike artist which needs the
# contributors table for its display name.
sub _recentlyPlayedAlbums {
    my ($dbh, $trackCount, $provider, $apcAvailable, $tpAvailable) = @_;

    $provider ||= 'both';
    my $lastPlayedExpr = _lastPlayedExpr($provider, $apcAvailable, $tpAvailable);

    my $apcJoin = $apcAvailable ? 'LEFT JOIN p.alternativeplaycount apc ON apc.urlmd5 = t.urlmd5' : '';
    my $tpJoin  = $tpAvailable  ? 'LEFT JOIN p.tracks_persistent tp ON tp.urlmd5 = t.urlmd5'       : '';

    my $rows = eval {
        $dbh->selectcol_arrayref(qq{
            SELECT DISTINCT recent.album
            FROM (
                SELECT t.album AS album, $lastPlayedExpr AS lastPlayed
                FROM tracks t
                $apcJoin
                $tpJoin
                WHERE t.album IS NOT NULL
                  AND $lastPlayedExpr IS NOT NULL
                ORDER BY $lastPlayedExpr DESC
                LIMIT ?
            ) recent
        }, undef, $trackCount);
    };
    if ($@) {
        $log->error("TrackSelector: could not fetch recently played albums: $@");
        return [];
    }

    return $rows || [];
}

# _yearWhereClause($yearRanges) -> ($sqlFragment, @bindValues)
#
# Turns a yearRanges arrayref (see selectTracks()'s own criteria docs -
# each entry "YYYY" or "YYYY-YYYY") into a single parenthesized OR
# condition on t.year, ready to AND into the rest of a WHERE clause.
# Shared between _buildPoolQuery() (the hard pool filter) and
# findRejectedTracks() (which treats years the same as genreGroup: part
# of what makes a track a candidate at all, not a soft/invertible reject
# reason - see that function's own comment for why).
#
# Returns ('', ()) when $yearRanges is empty/absent, or once every entry
# turns out unparseable - same "no constraint" convention as an empty
# genreGroup, so a caller can just skip adding anything to @where/@bind
# when the fragment comes back blank. Deliberately re-validates each
# entry here too (not just trusting Settings/Basic.pm's own save-time
# validation) - defensive against a filter saved by an older version of
# this plugin, before this field existed, or any other stored value that
# didn't go through that validation.
sub _yearWhereClause {
    my ($yearRanges) = @_;
    $yearRanges ||= [];

    my (@parts, @bind);
    for my $entry (@$yearRanges) {
        next unless defined $entry;

        if ($entry =~ /^(\d{4})$/) {
            push @parts, 't.year = ?';
            push @bind, $1;
        }
        elsif ($entry =~ /^(\d{4})-(\d{4})$/) {
            push @parts, 't.year BETWEEN ? AND ?';
            push @bind, $1, $2;
        }
        # else: doesn't parse - skipped, same tolerance
        # Settings/Basic.pm::_parseYears already applies at save time.
    }

    return ('', ()) unless @parts;
    return ('(' . join(' OR ', @parts) . ')', @bind);
}

# Merges recently-played artists/albums (artistCooldownTracks/
# albumCooldownTracks, if set) into $criteria->{artistBlock}/
# {albumBlock} in place. Shared by selectTracks() and selectAlbums() so
# both fully hard-exclude anything in cooldown before any weighting.
sub _mergeCooldownBlocks {
    my ($criteria, $dbh, $playCountProvider, $apcAvailable, $tpAvailable) = @_;

    if (defined $criteria->{artistCooldownTracks} && $criteria->{artistCooldownTracks} > 0) {
        my $recent = _recentlyPlayedArtists($dbh, $criteria->{artistCooldownTracks}, $playCountProvider, $apcAvailable, $tpAvailable);
        if (@$recent) {
            my @artistBlock = @{ $criteria->{artistBlock} || [] };
            my %seen = map { lc($_) => 1 } @artistBlock;
            push @artistBlock, grep { !$seen{lc($_)}++ } @$recent;
            $criteria->{artistBlock} = \@artistBlock;
        }
    }

    if (defined $criteria->{albumCooldownTracks} && $criteria->{albumCooldownTracks} > 0) {
        my $recentAlbums = _recentlyPlayedAlbums($dbh, $criteria->{albumCooldownTracks}, $playCountProvider, $apcAvailable, $tpAvailable);
        if (@$recentAlbums) {
            my @albumBlock = @{ $criteria->{albumBlock} || [] };
            my %seen = map { $_ => 1 } @albumBlock;
            push @albumBlock, grep { !$seen{$_}++ } @$recentAlbums;
            $criteria->{albumBlock} = \@albumBlock;
        }
    }
}

# Album-pool counterpart to _buildPoolQuery() below - same hard-filter
# WHERE clause (candidate tracks, genre/artistBlock/cooldowns/etc.), but
# collapsed to one row per distinct album (GROUP BY t.album) and
# weighted on the album's own contributor (al.contributor) instead of
# each surviving track's primary_artist - see selectAlbums()'s own
# comment for why.
sub _buildAlbumPoolQuery {
    my (%criteria) = @_;

    my $playCountProvider = $criteria{playCountProvider} || 'both';
    my $apcAvailable      = $criteria{apcAvailable};
    my $tpAvailable       = $criteria{tpAvailable};
    my $playCountExpr     = _playCountExpr($playCountProvider, $apcAvailable, $tpAvailable);
    my $limit             = defined $criteria{poolSize} ? $criteria{poolSize} : DEFAULT_POOL_SIZE;

    my $apcJoin = $apcAvailable ? 'LEFT JOIN p.alternativeplaycount apc ON apc.urlmd5 = t.urlmd5' : '';
    my $tpJoin  = $tpAvailable  ? 'LEFT JOIN p.tracks_persistent tp ON tp.urlmd5 = t.urlmd5'       : '';

    my $ratingExpr = $tpAvailable
        ? '(CASE WHEN tp.rating > 5 THEN ROUND(tp.rating / 20.0) ELSE tp.rating END)'
        : 'NULL';

    my @where = ('t.audio = 1', 't.album IS NOT NULL');
    my @bind;

    my $genreGroup    = $criteria{genreGroup}    || [];
    my $filterArtists = $criteria{filterArtists} || [];
    my (@orParts, @orBind);
    if (@$genreGroup) {
        push @orParts, 'g.name IN (' . join(',', ('?') x @$genreGroup) . ')';
        push @orBind, @$genreGroup;
    }
    if (@$filterArtists) {
        push @orParts, '(' . join(' OR ', ('c.name LIKE ? COLLATE NOCASE') x @$filterArtists) . ')';
        push @orBind, map { '%' . $_ . '%' } @$filterArtists;
    }
    if (@orParts) {
        push @where, '(' . join(' OR ', @orParts) . ')';
        push @bind, @orBind;
    }

    my ($yearWhere, @yearBind) = _yearWhereClause($criteria{yearRanges});
    if ($yearWhere) {
        push @where, $yearWhere;
        push @bind, @yearBind;
    }

    my $artistBlock = $criteria{artistBlock} || [];
    if (@$artistBlock) {
        push @where, '(c.name IS NULL OR c.name NOT IN (' . join(',', ('?') x @$artistBlock) . '))';
        push @bind, @$artistBlock;
    }

    my $albumBlock = $criteria{albumBlock} || [];
    if (@$albumBlock) {
        push @where, 't.album NOT IN (' . join(',', ('?') x @$albumBlock) . ')';
        push @bind, @$albumBlock;
    }

    if (defined $criteria{maxPlaycount}) {
        push @where, "($playCountExpr IS NULL OR $playCountExpr <= ?)";
        push @bind, $criteria{maxPlaycount};
    }

    my $excludeRatings = $criteria{excludeRatings} || [];
    if (@$excludeRatings && $tpAvailable) {
        push @where, "(tp.rating IS NULL OR $ratingExpr NOT IN (" . join(',', ('?') x @$excludeRatings) . '))';
        push @bind, @$excludeRatings;
    }

    my $excludeAlbumIds = $criteria{excludeAlbumIds} || [];
    if (@$excludeAlbumIds) {
        push @where, 't.album NOT IN (' . join(',', ('?') x @$excludeAlbumIds) . ')';
        push @bind, @$excludeAlbumIds;
    }

    my $sql = qq{
        SELECT t.album AS albumId, al.title AS albumTitle, al.year AS albumYear,
               ac.name AS artist
        FROM tracks t
        LEFT JOIN genre_track gt ON gt.track = t.id
        LEFT JOIN genres g ON g.id = gt.genre
        LEFT JOIN contributors c ON c.id = t.primary_artist
        JOIN albums al ON al.id = t.album
        LEFT JOIN contributors ac ON ac.id = al.contributor
        $apcJoin
        $tpJoin
        WHERE } . join("\n          AND ", @where) . qq{
        GROUP BY t.album
        ORDER BY RANDOM()
        LIMIT $limit
    };

    return ($sql, @bind);
}

# All audio tracks of one album, in play order - used by selectAlbums()
# once an album has been picked. Deliberately unfiltered (no genre/
# artistBlock/etc. re-check per track) - the album itself was already
# the filtered/weighted pick, this just returns it whole.
sub _albumTracks {
    my ($dbh, $albumId) = @_;

    my $rows = eval {
        $dbh->selectall_arrayref(qq{
            SELECT t.url, t.title, c.name AS artist, t.album AS albumId
            FROM tracks t
            LEFT JOIN contributors c ON c.id = t.primary_artist
            WHERE t.album = ? AND t.audio = 1
            ORDER BY t.disc, t.tracknum
        }, { Slice => {} }, $albumId);
    };
    if ($@) {
        $log->error("TrackSelector: could not fetch tracks for album $albumId: $@");
        return [];
    }
    return $rows || [];
}

sub _buildPoolQuery {
    my (%criteria) = @_;

    my $playCountProvider = $criteria{playCountProvider} || 'both';
    my $apcAvailable      = $criteria{apcAvailable};
    my $tpAvailable       = $criteria{tpAvailable};
    my $playCountExpr     = _playCountExpr($playCountProvider, $apcAvailable, $tpAvailable);
    my $limit             = defined $criteria{poolSize} ? $criteria{poolSize} : DEFAULT_POOL_SIZE;

    # Only join a table when it's actually there right now - see
    # _tableAvailable/AUTO-DEGRADE at the top of this file. Omitted
    # entirely otherwise, so the query never references a table that
    # doesn't exist, regardless of what playCountProvider is configured.
    my $apcJoin = $apcAvailable ? 'LEFT JOIN p.alternativeplaycount apc ON apc.urlmd5 = t.urlmd5' : '';
    my $tpJoin  = $tpAvailable  ? 'LEFT JOIN p.tracks_persistent tp ON tp.urlmd5 = t.urlmd5'       : '';

    # Rating only ever comes from tracks_persistent - if it isn't
    # reachable right now there is no rating data to read OR to exclude
    # by, so the expression is a literal NULL and (below) the
    # excludeRatings constraint is skipped entirely rather than
    # referencing a 'tp' that was never joined.
    my $ratingExpr = $tpAvailable
        ? '(CASE WHEN tp.rating > 5 THEN ROUND(tp.rating / 20.0) ELSE tp.rating END)'
        : 'NULL';

    my @where = ('t.audio = 1');
    my @bind;

    # --- HARD constraints ---

    # genreGroup is always a hard filter - see the design notes at the
    # top of this file for why (Henk confirmed 20-09-2026). filterArtists
    # (added 20-09-2026) widens this with an OR, not a second AND: a
    # track is in if its genre matches OR its artist matches one of
    # these substrings - naming an artist here always includes them,
    # genre or not. Matching is case-insensitive (COLLATE NOCASE) and by
    # substring (LIKE '%...%') so a collaboration credit like "Ajna (5)
    # & Dronny Darko" is included by just naming "Ajna". When both are
    # empty this adds nothing, same "no constraint" behaviour genreGroup
    # alone always had.
    my $genreGroup    = $criteria{genreGroup}    || [];
    my $filterArtists = $criteria{filterArtists} || [];

    my (@orParts, @orBind);
    if (@$genreGroup) {
        push @orParts, 'g.name IN (' . join(',', ('?') x @$genreGroup) . ')';
        push @orBind, @$genreGroup;
    }
    if (@$filterArtists) {
        push @orParts, '(' . join(' OR ', ('c.name LIKE ? COLLATE NOCASE') x @$filterArtists) . ')';
        push @orBind, map { '%' . $_ . '%' } @$filterArtists;
    }
    if (@orParts) {
        push @where, '(' . join(' OR ', @orParts) . ')';
        push @bind, @orBind;
    }

    # yearRanges (added 25-09-2026) is a SEPARATE hard AND-constraint,
    # not folded into the genre/filterArtists OR-block above - see the
    # design notes at the top of this file for why (Henk: "AND klinkt
    # het meest logisch").
    my ($yearWhere, @yearBind) = _yearWhereClause($criteria{yearRanges});
    if ($yearWhere) {
        push @where, $yearWhere;
        push @bind, @yearBind;
    }

    my $artistBlock = $criteria{artistBlock} || [];
    if (@$artistBlock) {
        push @where, '(c.name IS NULL OR c.name NOT IN (' . join(',', ('?') x @$artistBlock) . '))';
        push @bind, @$artistBlock;
    }

    # albumBlock is only ever populated by the albumCooldownTracks merge in
    # selectTracks() above (see the design notes at the top of this file) -
    # unlike artistBlock there's no manual "always block this album" field,
    # Henk didn't ask for one. Matched by numeric album id, not title.
    my $albumBlock = $criteria{albumBlock} || [];
    if (@$albumBlock) {
        push @where, '(t.album IS NULL OR t.album NOT IN (' . join(',', ('?') x @$albumBlock) . '))';
        push @bind, @$albumBlock;
    }

    if (defined $criteria{maxPlaycount}) {
        push @where, "($playCountExpr IS NULL OR $playCountExpr <= ?)";
        push @bind, $criteria{maxPlaycount};
    }

    my $excludeRatings = $criteria{excludeRatings} || [];
    if (@$excludeRatings && $tpAvailable) {
        # Normalize tracks_persistent.rating to 1-5 before comparing:
        # a value already <=5 is used as-is; anything higher (Lyrion's
        # native 0-100 scale) is divided by 20 and rounded. Skipped
        # entirely when tracks_persistent isn't reachable right now (see
        # $ratingExpr above) - there's no rating data to filter by, so
        # this degrades to "no constraint" rather than referencing a
        # 'tp' alias that was never joined.
        push @where, "(tp.rating IS NULL OR $ratingExpr NOT IN (" . join(',', ('?') x @$excludeRatings) . '))';
        push @bind, @$excludeRatings;
    }

    my $excludeUrls = $criteria{excludeUrls} || [];
    if (@$excludeUrls) {
        push @where, 't.url NOT IN (' . join(',', ('?') x @$excludeUrls) . ')';
        push @bind, @$excludeUrls;
    }

    my $sql = qq{
        SELECT t.url, t.title, c.name AS artist, t.album AS albumId, $playCountExpr AS playCount,
               $ratingExpr AS rating
        FROM tracks t
        LEFT JOIN genre_track gt ON gt.track = t.id
        LEFT JOIN genres g ON g.id = gt.genre
        LEFT JOIN contributors c ON c.id = t.primary_artist
        $apcJoin
        $tpJoin
        WHERE } . join("\n          AND ", @where) . qq{
        GROUP BY t.id
        ORDER BY RANDOM()
        LIMIT $limit
    };

    return ($sql, @bind);
}

# Simple weighted pick without replacement from a small pool - plain
# Perl, no formulas, easy to follow and to adjust later.
#
# $wobble (0-100) is optional - callers that don't care about Wobble can
# simply omit it and get plain artist-only weighting (wobble defaults to
# 0, i.e. a no-op). The pool itself is always already hard-filtered by
# genre/artistBlock/cooldown/etc - wobble only ever reshuffles preference
# *within* that pool, it never lets anything outside it back in.
sub _weightedPick {
    my ($pool, $count, $preferredArtists, $preferredWeight, $lessPreferredArtists, $lessPreferredWeight, $wobble) = @_;

    $wobble = 0 unless defined $wobble;

    my %preferred     = map { lc($_) => 1 } @$preferredArtists;
    my %lessPreferred = map { lc($_) => 1 } @$lessPreferredArtists;

    my @remaining = @$pool;
    my @chosen;

    for (1 .. $count) {
        last unless @remaining;

        my @weights;
        my $totalWeight = 0;
        for my $row (@remaining) {
            my $artistKey = lc($row->{artist} // '');
            my $artistWeight = 1;
            # SugarCube's own weight scale (1-5), not a raw multiplier -
            # see the design note above this sub's header comment block.
            $artistWeight = $preferredWeight + 1            if $preferred{$artistKey};
            $artistWeight = 1 / ($lessPreferredWeight + 1)  if $lessPreferred{$artistKey};

            # Let wobble blend the weight back towards 1 (=no preference)
            # as wobble rises to 100.
            my $w = 1 + ($artistWeight - 1) * (1 - $wobble / 100);

            push @weights, $w;
            $totalWeight += $w;
        }

        my $r   = rand($totalWeight);
        my $cum = 0;
        my $pickIdx = $#remaining; # fallback: last item, in case of rounding
        for my $i (0 .. $#remaining) {
            $cum += $weights[$i];
            if ($r < $cum) {
                $pickIdx = $i;
                last;
            }
        }

        push @chosen, splice(@remaining, $pickIdx, 1);
    }

    return \@chosen;
}

1;

__END__
