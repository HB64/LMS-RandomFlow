package Plugins::RandomFlow::MixRunner;

#
# Starts and sustains a continuous mix for a player - the missing piece
# between "TrackSelector.pm can pick tracks" and "Lyrion actually plays
# them". Modelled directly on SugarCube's own Chain Mode mechanism
# (Henk pointed to the SC-EXTMIP build's Plugin.pm/Breakout.pm,
# 20-09-2026) rather than invented from scratch:
#
#   - startMix($client) is SugarCube's AutoStartMix: clear the queue,
#     pick ONE track from the player's resolved filter (activeFilterId
#     + genreBlock, see Settings::Util::resolveFilterGenres) plus its
#     other settings, queue it and start playing. Sets the per-player
#     mixRunning flag.
#
#   - init() (called once from Plugin.pm's initPlugin) subscribes to
#     Lyrion's own request bus for 'playlist newsong' events - i.e.
#     every track change - exactly the way SugarCube's commandCallback
#     does. Each one arms a short one-shot timer (SUGAR_DELAY seconds -
#     the "load-bearing pause" SugarCube's own source comments insist
#     on: Lyrion has not finished updating its own playlist position at
#     the exact instant the event fires, so checking immediately sees
#     the OLD position and wrongly concludes nothing is needed).
#
#   - When that timer fires, _maybeQueueNext($client) is SugarCube's
#     kickoff: only proceeds if mixRunning is set for this player AND
#     the player is now on the LAST track of its own queue (checked the
#     same way SugarCube's Breakout::CheckPosition does: queue length
#     minus the currently-playing index). If so, exactly one more track
#     is picked and appended - always "current + 1 upcoming", never a
#     bulk fill. The just-finished track is passed as excludeUrls so it
#     can't be picked right back.
#
#   - stopMix($client) just clears the mixRunning flag - exactly like
#     switching SugarCube's Chain off, it does NOT touch whatever is
#     currently queued or playing, it only stops sustaining it.
#
# Deliberately NOT done (yet, same as SugarCube's own DSTM handling):
# no interaction with Lyrion's own "Don't Stop The Music" plugin. If
# that turns out to matter here too, SugarCube's own fix (flip that
# player's DSTM provider pref off when the mix starts, restore it when
# it stops) is a small, self-contained addition to layer on separately
# once this basic wrapper is confirmed working.
#
# SYNCED PLAYERS (e.g. a stereo-paired Boom Links/Boom Rechts, Henk's
# case, found 20-09-2026): Lyrion ALWAYS sends the 'playlist newsong'
# notification for the sync-group's MASTER player, never for whichever
# physical member is actually addressed (confirmed against the real
# slimserver source, Slim::Player::StreamingController::_Playing:
# "Slim::Control::Request::notifyFromArray($self->master(), ...)").
# Henk's two Booms show up as two SEPARATE entries on this plugin's own
# per-player settings page though, each with its own filter - and which
# one is master changes on every Lyrion restart. So:
#   - startMix($client) stores mixRunning AND which client's settings
#     were actually used (mixSourceClientId) under $client->master's own
#     prefs - that's the identity _maybeQueueNext will always be called
#     with, whichever Boom happens to be master today.
#   - _maybeQueueNext resolves mixSourceClientId back to the actual
#     client object (Slim::Player::Client::getClient) and uses THAT
#     one's filter/block settings, falling back to the notified client
#     itself if that lookup fails for any reason (player renamed,
#     disconnected, or a plain unsynced player where this is moot since
#     ->master just returns itself).
# Without this, a synced pair silently drops the mix after track 1
# whenever the "wrong" Boom happens to be master - no log line at all,
# since the very first check (mixRunning) already fails silently.
#

use strict;
use warnings;

use Slim::Control::Request;
use Slim::Player::Client;
use Slim::Player::Playlist;
use Slim::Player::Source;
use Slim::Music::Info;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Slim::Utils::Log;
use Time::HiRes;

use TrackSelector;
use Plugins::RandomFlow::Settings::Util qw(resolveFilterGenres resolveFilterArtists resolveFilterYears);

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.randomflow',
    'defaultLevel' => 'INFO',
});

my $prefs = preferences('plugin.randomflow');

# Same floor SugarCube enforces on its own delay, for the same reason -
# see the design note above. Never 0.
use constant SUGAR_DELAY => 1;

# Default "Play history" setting (see Settings/Basic.pm's design note)
# for a fresh install where historyLimit was never explicitly saved -
# distinct from an explicitly-blanked field, which means "no limit"
# (see _historyLimit() below).
use constant DEFAULT_HISTORY_LIMIT => 10;

sub init {
    Slim::Control::Request::subscribe(\&_onNewSong, [['playlist']]);
}

sub startMix {
    my ($client) = @_;
    return unless $client;

    # See the SYNCED PLAYERS design note above - the newsong notification
    # that drives top-up always arrives for the sync-group master, so
    # that's where mixRunning has to live too, whichever specific player
    # this call was actually made for.
    my $master = $client->can('master') ? $client->master : $client;

    # Henk, 26-09-2026: found that clicking the "Start New Mix" button on the Live page while
    # Auto Mix was explicitly set to Disabled started a mix anyway - startMix() always did, since
    # it predates the separate Auto Mix toggle (setAutoMix, above) and never checked mixRunning at
    # all, it just sets it to 1 unconditionally once a track is queued (see below). With Auto Mix
    # now the dedicated master on/off switch for mixing on a player, that's backwards: Auto Mix
    # off has to mean mixing is off, full stop, not "off until someone clicks the other button".
    # Refuse here the same way a missing filter is refused - Start New Mix now only acts as
    # "give me a fresh pick right now" WHILE Auto Mix is already on; turning mixing on at all is
    # Auto Mix's job alone.
    if (!$prefs->client($master)->get('mixRunning')) {
        $log->warn("RandomFlow::MixRunner: startMix refused for " . $client->name . " - Auto Mix is disabled for this player. Enable Auto Mix first.");
        _warnAutoMixOff($client);
        return 0;
    }

    # Henk's real case (20-09-2026): a stereo-paired Boom shows up as two
    # separately-addressable players, but he only wants to configure a
    # filter once for the pair - and Lyrion's alarm clock always fires
    # for whichever one happens to be sync master today, which may be
    # the one he never got around to setting up. So: use this player's
    # own filter if it has one, otherwise fall back to the first synced
    # sibling that does, rather than refusing outright.
    my ($sourceClient, $criteria) = _resolveSource($client);

    # An empty genreGroup here means "no filter chosen anywhere in this
    # sync group (or the chosen filter has no genres left after the
    # quick-block list)" - see the warning in
    # Settings::Util::resolveFilterGenres: TrackSelector.pm itself
    # treats an empty genreGroup as NO constraint at all, i.e. the
    # entire library. Refuse rather than silently mixing from
    # everything the player never asked for.
    if (!_hasFilter($criteria)) {
        $log->warn("RandomFlow::MixRunner: startMix refused for " . $client->name . " - no filter chosen for this player (or any player it's synced with), or the chosen filter has no genres/artists left after the quick-block list. Pick a filter on one of their settings pages first.");
        _warnNoFilter($client);
        return 0;
    }

    $client->execute(['playlist', 'clear']);

    my $picked = TrackSelector::selectTracks(%$criteria, count => 1);
    if (!@$picked) {
        $log->warn("RandomFlow::MixRunner: startMix - no track found for " . $client->name . " (check the player's filter/block settings, or the library/database - see the log above this line for the actual reason).");
        $prefs->client($master)->set('mixRunning', 0);
        _warnNoTrack($client);
        return 0;
    }

    $client->execute(['playlist', 'add', $picked->[0]{url}]);
    $client->execute(['play']);
    $prefs->client($master)->set('mixRunning', 1);
    $prefs->client($master)->set('mixSourceClientId', $sourceClient->id);
    $log->info("RandomFlow::MixRunner: mix started for " . $client->name . " - queued '" . $picked->[0]{title} . "' by '" . ($picked->[0]{artist} // '?') . "'.");
    return 1;
}

sub stopMix {
    my ($client) = @_;
    return unless $client;

    my $master = $client->can('master') ? $client->master : $client;
    $prefs->client($master)->set('mixRunning', 0);
    $log->info("RandomFlow::MixRunner: mix stopped for " . $client->name . " (queue left as-is).");
}

# The Live page's "Auto Mix: Enabled/Disabled" toggle (Henk, 26-09-2026)
# calls THIS, not startMix()/stopMix() above - on purpose. Henk found that
# reusing startmix for "Enabled" was throwing away whatever track he was
# actually enjoying at the moment he flipped the toggle, because startMix
# always does 'playlist clear' + queues and jumps to a fresh pick right
# away - correct for the dedicated "Start New Mix" button (that's the
# whole point of that button), wrong for a toggle that's meant to just
# arm/disarm continuous mixing from wherever playback already is. Modelled
# on how SC-EXTMIP's own Chain toggle behaves: scLvSetStatus (liveview.html)
# just flips the sugarcube_status pref directly, it never touches the
# queue or calls AutoStartMix itself.
#
# - Enabling: same filter check/refusal as startMix (see its own comment),
#   then just sets mixRunning (and mixSourceClientId, for the same synced-
#   player reason startMix sets it) directly - no clear, no immediate
#   'play'. Current playback is left completely alone.
# - Because we're not clearing anything, there's a gap startMix doesn't
#   have: if the player happens to already be down to its last queued
#   track (or has nothing queued after the current one at all) right when
#   this is called, no 'playlist newsong' event is coming to trigger
#   _maybeQueueNext's usual top-up - if nothing is queued next, playback
#   would just stop once the current track ends, with mixRunning sitting
#   on TRUE and nobody the wiser. So: call _maybeQueueNext once, right
#   here, synchronously - it's the exact same "am I on the last queued
#   track?" check the newsong timer itself runs, just invoked immediately
#   instead of waiting for an event that might never come. If something
#   is already queued after the current track, this is a no-op (correct -
#   the existing queue plays out first, top-up resumes normally from the
#   next newsong event).
# - Disabling: identical to stopMix() (queue left as-is) - kept as a
#   separate branch here rather than calling stopMix() so both directions
#   of this toggle live together in one place, matching scLvSetStatus's
#   own shape (single function, single pref, no queue side effects either
#   way).
sub setAutoMix {
    my ($client, $value) = @_;
    return unless $client;

    # Henk, 26-09-2026: wrapped the whole body in eval - every attempt to
    # reproduce the "Empty reply from server" crash (confirmed via curl,
    # bypassing the browser entirely, so this is a real server-side crash,
    # not a network/browser issue) has produced NOTHING in Lyrion's own
    # log, not even an ERROR line, which normally would appear if Lyrion's
    # own dispatcher caught a die() here. That silence is itself the clue -
    # something in this call chain (this function, or the mixRunning
    # setChange watcher in Plugin.pm's initPlugin, which fires
    # SYNCHRONOUSLY from the $prefs->client($master)->set('mixRunning', ...)
    # call below) is dying in a way that isn't getting logged anywhere.
    # This eval is a safety net specifically to CATCH that and log it
    # explicitly, so the next test finally shows the real error instead of
    # silence.
    my $ok = eval {
        my $master = $client->can('master') ? $client->master : $client;

        if (!$value) {
            $prefs->client($master)->set('mixRunning', 0);
            $log->info("RandomFlow::MixRunner: Auto Mix disabled for " . $client->name . " (queue left as-is).");
            return 1;
        }

        my ($sourceClient, $criteria) = _resolveSource($client);
        if (!_hasFilter($criteria)) {
            $log->warn("RandomFlow::MixRunner: Auto Mix refused for " . $client->name . " - no filter chosen for this player (or any player it's synced with), or the chosen filter has no genres/artists left after the quick-block list. Pick a filter on one of their settings pages first.");
            _warnNoFilter($client);
            return 0;
        }

        $prefs->client($master)->set('mixSourceClientId', $sourceClient->id);
        $prefs->client($master)->set('mixRunning', 1);
        $log->info("RandomFlow::MixRunner: Auto Mix enabled for " . $client->name . " - current playback left untouched, queue will be topped up as needed.");

        _maybeQueueNext($master);
        return 1;
    };
    if ($@) {
        $log->error("RandomFlow::MixRunner: setAutoMix CRASHED for " . $client->name . " - " . $@);
        return 0;
    }
    return $ok;
}

# SC-EXTMIP's own "Replace Track" (scReplaceNext/SugarCubeReplaceNext)
# deletes just the single upcoming track and re-runs its kickoff()
# picker, but SC-EXTMIP itself keeps that gated behind sc_can_act
# (chain mode only, not mid-batch) because kickoff() only ever queues
# anything when CheckPosition==1 - exactly one track left - and a
# batch can leave SEVERAL tracks queued ahead, which would make
# "Replace Track" silently delete the next batch track with no
# replacement (see SC-EXTMIP's own comment on this, quoted in
# live.html's markup comment on the button). RandomFlow has no
# batch/chain duality at all: startMix always seeds exactly one track,
# and _maybeQueueNext only ever tops up exactly one more once down to
# the last queued track (see the design note at the top of this
# file) - so this plugin's queue can only ever be at "0 upcoming" or
# "1 upcoming", never more. That makes the same "exactly one queued"
# check SC-EXTMIP relies on always true here whenever there IS
# anything to replace at all, so no separate gate is needed - checked
# explicitly below anyway (rather than assumed) so a future change to
# that invariant fails loudly (silently does nothing) instead of ever
# deleting the wrong track.
sub replaceNext {
    my ($client) = @_;
    return unless $client;

    my $master = $client->can('master') ? $client->master : $client;
    return unless $prefs->client($master)->get('mixRunning');

    my $listLength   = Slim::Player::Playlist::count($master);
    my $playingIndex = Slim::Player::Source::playingSongIndex($master);
    return unless ($listLength - $playingIndex) == 2;   # exactly one track queued after the current one

    # 'playlist delete' addresses the queue by plain index, not URL -
    # no need to look up the upcoming track's own URL just to remove
    # it. Since it's always the LAST entry in this plugin's queue
    # (never more than current+1, see the comment above), the
    # 'playlist add' below - which always appends - lands it right
    # back in the same "next up" slot once the fresh pick is queued.
    my $nextIndex = $playingIndex + 1;
    $master->execute(['playlist', 'delete', $nextIndex]);

    # Same sync-group source resolution as startMix/_maybeQueueNext -
    # see the SYNCED PLAYERS design note at the top of this file.
    my $sourceId     = $prefs->client($master)->get('mixSourceClientId');
    my $sourceClient = (defined $sourceId && Slim::Player::Client::getClient($sourceId)) || $master;
    my $criteria     = _criteriaFor($sourceClient);

    if (!_hasFilter($criteria)) {
        $log->warn("RandomFlow::MixRunner: replaceNext refused for " . $master->name . " - no filter chosen any more, stopping the mix.");
        $prefs->client($master)->set('mixRunning', 0);
        _warnNoFilter($master);
        return;
    }

    # Exclude the currently playing track so the replacement can't
    # come back as an immediate repeat of it - same excludeUrls use as
    # _maybeQueueNext.
    my $curUrl = Slim::Player::Playlist::url($master) || '';
    $criteria->{excludeUrls} = [$curUrl];

    my $picked = TrackSelector::selectTracks(%$criteria, count => 1);
    if (!@$picked) {
        $log->warn("RandomFlow::MixRunner: replaceNext - no track found for " . $master->name . " (see the log above this line for the actual reason) - the upcoming slot is now empty, will retry on the next track change.");
        _warnNoTrack($master);
        return;
    }

    $master->execute(['playlist', 'add', $picked->[0]{url}]);
    $log->info("RandomFlow::MixRunner: replaced the upcoming track with '" . $picked->[0]{title} . "' by '" . ($picked->[0]{artist} // '?') . "' for " . $master->name . ".");
}

# Batch mode (Henk, 28-09-2026, modelled on SC-EXTMIP's Start Batch/
# "top up" pair): unlike startMix/_maybeQueueNext, which only ever keep
# "current + 1 upcoming" queued, these two queue several tracks at
# once - how many is the player's own "batchSize" setting (Settings/
# Player.pm, 10-100), read via _criteriaFor/resolveCriteria like any
# other per-player setting. _maybeQueueNext's own "only top up when
# exactly 1 left" guard already leaves a multi-track queue alone until
# it plays down to its last track, so no separate batch-active flag is
# needed - Auto Mix top-up resumes on its own once the batch runs out.
sub startBatch {
    my ($client) = @_;
    return unless $client;

    my $master = $client->can('master') ? $client->master : $client;
    if (!$prefs->client($master)->get('mixRunning')) {
        $log->warn("RandomFlow::MixRunner: startBatch refused for " . $client->name . " - Auto Mix is disabled for this player. Enable Auto Mix first.");
        _warnAutoMixOff($client);
        return 0;
    }

    my ($sourceClient, $criteria) = _resolveSource($client);
    if (!_hasFilter($criteria)) {
        $log->warn("RandomFlow::MixRunner: startBatch refused for " . $client->name . " - no filter chosen for this player (or any player it's synced with).");
        _warnNoFilter($client);
        return 0;
    }

    my $count  = $criteria->{batchSize} || 20;
    my $picked = TrackSelector::selectTracks(%$criteria, count => $count);
    if (!@$picked) {
        $log->warn("RandomFlow::MixRunner: startBatch - no track found for " . $client->name . ".");
        _warnNoTrack($client);
        return 0;
    }

    $client->execute(['playlist', 'clear']);
    $client->execute(['playlist', 'add', $_->{url}]) for @$picked;
    $client->execute(['play']);
    $prefs->client($master)->set('mixRunning', 1);
    $prefs->client($master)->set('mixSourceClientId', $sourceClient->id);
    $log->info("RandomFlow::MixRunner: batch of " . scalar(@$picked) . " track(s) started for " . $client->name . ".");
    return 1;
}

# Appends $count more tracks to whatever is already queued (a batch or
# a running mix) - the Live page's "top up" button under Next Track.
# Only excludes the currently playing track, not the rest of the
# existing queue (selectTracks itself only guarantees no duplicates
# within one call) - a rare repeat against an already-queued track is
# possible but not worth the extra query for a first version.
sub topUpQueue {
    my ($client) = @_;
    return unless $client;

    my $master = $client->can('master') ? $client->master : $client;
    return unless $prefs->client($master)->get('mixRunning');

    my $sourceId     = $prefs->client($master)->get('mixSourceClientId');
    my $sourceClient = (defined $sourceId && Slim::Player::Client::getClient($sourceId)) || $master;
    my $criteria     = _criteriaFor($sourceClient);

    if (!_hasFilter($criteria)) {
        $log->warn("RandomFlow::MixRunner: topUpQueue refused for " . $master->name . " - no filter chosen any more.");
        _warnNoFilter($master);
        return 0;
    }

    my $curUrl = Slim::Player::Playlist::url($master) || '';
    $criteria->{excludeUrls} = [$curUrl];

    my $count  = $criteria->{batchSize} || 20;
    my $picked = TrackSelector::selectTracks(%$criteria, count => $count);
    if (!@$picked) {
        $log->warn("RandomFlow::MixRunner: topUpQueue - no track found for " . $master->name . ".");
        _warnNoTrack($master);
        return 0;
    }

    $master->execute(['playlist', 'add', $_->{url}]) for @$picked;
    $log->info("RandomFlow::MixRunner: topped up " . scalar(@$picked) . " track(s) for " . $master->name . ".");
    return 1;
}

# The "Afgewezen tracks" panel's own "queue as next" action (Henk,
# 25-09-2026) - queues a SPECIFIC, caller-chosen track as the upcoming
# one, rather than letting TrackSelector pick randomly like replaceNext()
# above does. Deliberately contradictory with the whole point of the
# "Afgewezen" list (a track that got excluded can still be added back in
# manually) - confirmed as intentional by Henk, same as SugarCube's own
# "Use as Next" on its MIP Response list works the same way.
#
# Same "current + at most 1 upcoming" invariant as replaceNext() (see its
# own comment above) - but unlike replaceNext(), this can legitimately be
# called when there's NOT yet an upcoming track queued (e.g. right after
# startMix, before the first _maybeQueueNext top-up has run, or right
# after a previous replaceNext/queueSpecificTrack found nothing) - so it
# only deletes an existing upcoming slot when there actually is one,
# rather than refusing outright the way replaceNext() does.
sub queueSpecificTrack {
    my ($client, $url) = @_;
    return unless $client && defined $url && length $url;

    my $master = $client->can('master') ? $client->master : $client;
    return unless $prefs->client($master)->get('mixRunning');

    my $listLength   = Slim::Player::Playlist::count($master);
    my $playingIndex = Slim::Player::Source::playingSongIndex($master);
    my $upcoming     = $listLength - $playingIndex - 1;

    # Refuse on anything outside the known invariant (0 or 1 upcoming)
    # rather than guessing which index to touch - see the design note
    # above and replaceNext()'s own comment for why this should never
    # legitimately happen.
    return unless $upcoming == 0 || $upcoming == 1;

    if ($upcoming == 1) {
        my $nextIndex = $playingIndex + 1;
        $master->execute(['playlist', 'delete', $nextIndex]);
    }

    $master->execute(['playlist', 'add', $url]);
    $log->info("RandomFlow::MixRunner: queued a manually chosen track ('$url') as the upcoming track for " . $master->name . " (from the Afgewezen tracks panel).");
}

# A filter now "counts" if EITHER its genre group or its artists list
# (added 20-09-2026, additive - see TrackSelector.pm's design notes) is
# non-empty - a player picking a filter that's artists-only, no genres
# at all, must not be refused as "no filter chosen".
sub _hasFilter {
    my ($criteria) = @_;
    return @{ $criteria->{genreGroup} || [] } || @{ $criteria->{filterArtists} || [] };
}

# On-screen warning for the OTHER way a mix can fail to (keep) running:
# a filter WAS chosen, but selectTracks() still came back with nothing -
# an unexpectedly narrow filter, everything excluded by
# cooldown/playcount/rating, or (added 21-09-2026, after Henk hit this
# for real - a Lyrion upgrade briefly left persist.db without one of its
# tables) an underlying database error. Without this, that failure was
# only ever visible in the log - easy to miss, especially when it's an
# alarm firing while nobody's looking at the log.
sub _warnNoTrack {
    my ($client) = @_;
    return unless $client;

    $client->showBriefly(
        { 'line1' => $client->string('RANDOMFLOW'),
          'line2' => $client->string('PLUGIN_RANDOMFLOW_NOTRACK_WARNING') },
        { 'duration' => 5, 'block' => 0 }
    );
}

# On-screen warning shown in the Material web skin (and on the player's
# own display) whenever a mix refuses to start or continue because no
# filter is chosen - a log line alone is easy to miss. Mirrors
# SugarCube's own AutoStartMix pattern exactly.
sub _warnNoFilter {
    my ($client) = @_;
    return unless $client;

    $client->showBriefly(
        { 'line1' => $client->string('RANDOMFLOW'),
          'line2' => $client->string('PLUGIN_RANDOMFLOW_NOFILTER_WARNING') },
        { 'duration' => 5, 'block' => 0 }
    );
}

# On-screen warning shown whenever "Start New Mix" is refused because Auto Mix is currently
# disabled for this player - see the 26-09-2026 comment on startMix() for why. Same pattern as
# _warnNoFilter/_warnNoTrack above.
sub _warnAutoMixOff {
    my ($client) = @_;
    return unless $client;

    $client->showBriefly(
        { 'line1' => $client->string('RANDOMFLOW'),
          'line2' => $client->string('PLUGIN_RANDOMFLOW_AUTOMIXOFF_WARNING') },
        { 'duration' => 5, 'block' => 0 }
    );
}

sub _onNewSong {
    my $request = shift;
    my $client = $request->client();
    return unless $client;

    return unless $request->isCommand([['playlist'], ['newsong']]);

    Slim::Utils::Timers::killTimers($client, \&_maybeQueueNextTimer);
    Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + SUGAR_DELAY, \&_maybeQueueNextTimer);
}

# Timer callbacks in Lyrion are called as ($client, @args) - this thin
# wrapper exists only so _maybeQueueNext itself has a plain, directly
# testable ($client) signature.
sub _maybeQueueNextTimer {
    my ($client) = @_;
    _maybeQueueNext($client);
}

sub _maybeQueueNext {
    my ($client) = @_;
    return unless $client;

    return unless $prefs->client($client)->get('mixRunning');

    my $url = Slim::Player::Playlist::url($client) || '';
    return if $url eq '' || Slim::Music::Info::isRemoteURL($url);

    my $listLength   = Slim::Player::Playlist::count($client);
    my $playingIndex = Slim::Player::Source::playingSongIndex($client);
    return unless ($listLength - $playingIndex) == 1;   # only on the last queued track

    # $client here is always the sync-group master (see the SYNCED
    # PLAYERS design note above) - resolve back to whichever specific
    # player's filter/block settings startMix() actually used, since
    # that may be a different physical player and its settings live
    # under its own id, not the master's.
    my $sourceId     = $prefs->client($client)->get('mixSourceClientId');
    my $sourceClient = (defined $sourceId && Slim::Player::Client::getClient($sourceId)) || $client;

    my $criteria = _criteriaFor($sourceClient);

    # Same refusal as startMix - see the comment there.
    if (!_hasFilter($criteria)) {
        $log->warn("RandomFlow::MixRunner: maybeQueueNext refused for " . $client->name . " - no filter chosen any more, stopping the mix.");
        $prefs->client($client)->set('mixRunning', 0);
        _warnNoFilter($client);
        return;
    }

    $criteria->{excludeUrls} = [$url];

    my $picked = TrackSelector::selectTracks(%$criteria, count => 1);
    if (!@$picked) {
        $log->warn("RandomFlow::MixRunner: maybeQueueNext - no track found for " . $client->name . " (see the log above this line for the actual reason). Mix keeps running - will retry on the next track change.");
        _warnNoTrack($client);
        return;
    }

    $client->execute(['playlist', 'add', $picked->[0]{url}]);
    $log->info("RandomFlow::MixRunner: queued '" . $picked->[0]{title} . "' by '" . ($picked->[0]{artist} // '?') . "' for " . $client->name . ".");

    _trimHistory($client, _historyLimit());
}

# Resolves the global "Play history" setting (Settings/Basic.pm) to an
# actual limit: undef (never saved) falls back to DEFAULT_HISTORY_LIMIT,
# '' (explicitly saved blank) means "no limit" (undef, i.e. _trimHistory
# below is a no-op), and anything else is used as-is. Kept as its own
# sub, rather than inlined, so the three-states logic lives in exactly
# one place (see the design note in Settings/Basic.pm).
sub _historyLimit {
    my $raw = $prefs->get('historyLimit');
    return DEFAULT_HISTORY_LIMIT unless defined $raw;
    return undef unless length $raw;
    return $raw;
}

# Trims already-played tracks off the FRONT of $client's queue so at
# most $limit of them remain ahead of the currently playing track - a
# no-op if $limit is undef (no limit configured) or the queue hasn't
# grown past it yet. Uses Lyrion's own 'playlist delete' command, always
# on index 0 - confirmed against the real slimserver source
# (Slim::Player::Playlist::removeTrack) that removing an
# already-played track this way is safe and does not touch playback,
# it just shifts the playing index down by one each time.
sub _trimHistory {
    my ($client, $limit) = @_;
    return unless $client && defined $limit;

    my $playingIndex = Slim::Player::Source::playingSongIndex($client);
    my $excess = $playingIndex - $limit;
    return unless $excess > 0;

    for (1 .. $excess) {
        $client->execute(['playlist', 'delete', 0]);
    }
    $log->info("RandomFlow::MixRunner: trimmed $excess already-played track(s) from the queue for " . $client->name . " (history limit: $limit).");
}

# Picks which player's settings should actually govern a mix being
# started for $client: its own, if a filter is chosen there, otherwise
# the first synced sibling (in either direction - master or slave, see
# the SYNCED PLAYERS design note above) that has one. Returns
# ($theChosenClient, $itsCriteria) - if nobody in the sync group (or
# $client itself, if unsynced) has a filter, returns $client and its own
# (empty-genreGroup) criteria unchanged, so the caller's existing
# no-filter refusal still applies exactly as before.
# Public wrapper around _resolveSource() below, for callers outside this
# module that just want "the criteria this player's mix would actually
# use right now" - the same filter/block resolution a real startMix or
# _maybeQueueNext pick would use, sync-group fallback included (see the
# SYNCED PLAYERS design note at the top of this file). Plugin.pm's
# rejectedtracks dispatch handler (Henk, 25-09-2026 - "Afgewezen tracks"
# panel) is the first caller: what it reports as rejected has to be
# resolved exactly the same way, or it could show reasons for a
# different player's filter than the one actually mixing.
sub resolveCriteria {
    my ($client) = @_;
    return unless $client;

    my (undef, $criteria) = _resolveSource($client);
    return $criteria;
}

sub _resolveSource {
    my ($client) = @_;

    my $criteria = _criteriaFor($client);
    return ($client, $criteria) if _hasFilter($criteria);

    if ($client->can('syncedWith')) {
        for my $sibling ($client->syncedWith) {
            my $siblingCriteria = _criteriaFor($sibling);
            return ($sibling, $siblingCriteria) if _hasFilter($siblingCriteria);
        }
    }

    return ($client, $criteria);
}

# Builds the full TrackSelector::selectTracks() criteria hash from this
# player's stored settings - the filter+block resolution (see
# Settings::Util::resolveFilterGenres) plus every other per-player field
# from Settings/Player.pm, and the global playCountProvider.
sub _criteriaFor {
    my ($client) = @_;

    my $clientPrefs    = $prefs->client($client);
    my $filters        = $prefs->get('genreFilters') || [];
    my $activeFilterId = $clientPrefs->get('activeFilterId');
    my $genreBlock     = $clientPrefs->get('genreBlock') || [];

    return {
        genreGroup           => resolveFilterGenres($filters, $activeFilterId, $genreBlock),
        filterArtists        => resolveFilterArtists($filters, $activeFilterId),
        yearRanges           => resolveFilterYears($filters, $activeFilterId),
        artistBlock          => $clientPrefs->get('artistBlock')          || [],
        artistCooldownTracks => $clientPrefs->get('artistCooldownTracks') || 0,
        albumCooldownTracks  => $clientPrefs->get('albumCooldownTracks')  || 0,
        maxPlaycount         => $clientPrefs->get('maxPlaycount'),
        playCountProvider    => $prefs->get('playCountProvider')          || 'both',
        excludeRatings       => $clientPrefs->get('excludeRatings')       || [],
        preferredArtists     => $clientPrefs->get('preferredArtists')     || [],
        preferredWeight      => $clientPrefs->get('preferredWeight')      || 1,
        lessPreferredArtists => $clientPrefs->get('lessPreferredArtists') || [],
        lessPreferredWeight  => $clientPrefs->get('lessPreferredWeight')  || 1,
        wobble               => $clientPrefs->get('wobble')               || 0,
        poolSize             => $clientPrefs->get('poolSize'),
        batchSize            => $clientPrefs->get('batchSize')            || 20,
    };
}

1;

__END__
