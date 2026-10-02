package Plugins::RandomFlow::Plugin;

#
# THROWAWAY TEST HARNESS for TrackSelector.pm - the new SQL-based
# track-selection engine that replaces bliss-mixer/MixEngine.pm
# entirely. This plugin does NOT touch DSTM or playback at all - it
# only calls TrackSelector::selectTracks() directly and logs what
# comes back, so we can verify the hard constraints and the soft
# artist-weighting work correctly against the real library.db /
# persist.db before wiring this into an actual DSTM handler.
#
# INSTALL: put this file (as Plugin.pm), install.xml, strings.txt AND
# the copy of TrackSelector.pm that comes with this test together in
# one folder named "RandomFlow" inside Lyrion's Plugins
# directory, then restart Lyrion.
#
# WHERE TO LOOK: server log, lines starting "RandomFlow:".
#
# WHAT THIS TEST DOES:
#   TEST 1 (hard constraints): asks for 15 tracks from a deliberately
#   broad genre list (same 25-genre list as the earlier DSTM test),
#   with a modest playcount cap (<=5), and logs title/artist/
#   playCount/rating for each one, so the constraints can be checked
#   by eye.
#
#   TEST 2 (soft weighting): picks one real artist name out of TEST 1's
#   own results, then runs 20 independent single-track selections
#   twice - once with that artist given a high preferredWeight, once
#   with no preference at all (control) - and logs how many times that
#   artist was picked in each set of 20. The weighted run should show
#   that artist noticeably more often than the control run.
#
#   TEST 3 (artist cooldown): looks up which artists appear among the
#   200 most recently played tracks (per APC's lastPlayed), picks one of
#   them, then does 30 picks with and without a 200-track
#   artistCooldownTracks. That artist should never appear in the
#   "with cooldown" set, cooldown or no cooldown in the other.
#
#   TEST 4 (genre is always a hard filter): uses a single narrow genre
#   (Rock) instead of the broad 25-genre list, and checks that 0 of 30
#   picks land outside it. (This used to test a "Style"/genreStrictness
#   soft-genre mode - removed 20-09-2026, genre must always be hard.)
#
#   TEST 5 (Wobble): reuses TEST 2's test artist, and compares how
#   often that artist is picked over 30 single-track selections at
#   wobble=0 (Tight - configured weight counts fully) vs wobble=100
#   (Loose - weight should barely matter).
#
#   TEST 6 (ask size / poolSize): asks for poolSize=5, count=5 and
#   checks exactly 5 tracks come back - the pool itself is the limit.
#
#   TEST 7 (filter + quick-block resolution): pure-logic check of
#   Settings::Util::resolveFilterGenres() - the filter genres minus the
#   player's own quick-block list, case-insensitively, with a missing/
#   deleted filter id resolving to an empty list rather than "everything".
#   Doesn't touch the database or TrackSelector.pm at all.
#
# MixRunner.pm (added 20-09-2026, modelled on SugarCube's own Chain Mode
# mechanism) is the piece that actually starts/sustains a mix on a real
# player - see its own header comment for how. It is DELIBERATELY NOT
# exercised by the auto-running tests above: unlike every TEST here,
# starting a mix clears a player's queue and starts playback for real,
# which this passive, read-only test harness must never do on its own.
# It's covered instead by a local fake-client test suite (not shipped -
# see the session notes) that checked start/stop, the "keep one track
# ahead" top-up logic, the remote-stream guard, and the "no filter
# chosen -> refuse rather than mix the whole library" safety guard.
#
# To try it for real once you're ready: with a player selected/powered
# on, call the randomflow startmix / stopmix actions - either
# via the player's own request ID over CLI/JSON-RPC, e.g.
#   <playerid> randomflow startmix
#   <playerid> randomflow stopmix
# or (once the Live page exists) a button wired to the same two calls,
# exactly like SugarCube's own scStartChain.
#

use strict;
use warnings;

use File::Basename;
use lib dirname(__FILE__);

use TrackSelector;
use Plugins::RandomFlow::Settings::Basic;
use Plugins::RandomFlow::Settings::Player;
use Plugins::RandomFlow::Settings::Util qw(resolveFilterGenres);
use Plugins::RandomFlow::MixRunner;
use Plugins::RandomFlow::ProtocolHandler;
use Plugins::RandomFlow::Web;

use Slim::Schema;
use Slim::Utils::Alarm;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Time::HiRes;

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.randomflow',
    'defaultLevel' => 'INFO',
});

# Only global setting: which playCount/lastPlayed source to use. See
# Settings/Basic.pm for why nothing else lives here.
my $prefs = preferences('plugin.randomflow');
$prefs->init({ playCountProvider => 'both' });

# Same deliberately broad genre list as the earlier DSTM test, so
# genre filtering itself is not a limiting factor here.
my @TEST_GENRE_LIST = (
    'Alternative', 'Alternative Rock', 'Ambient', 'Classical', 'Country', 'Dance',
    'Electronic', 'Electronica', 'Electronisch', 'Film Soundtracks', 'Folk', 'Gothic',
    'Hard Rock', 'Heavy Metal', 'Metal', 'New Age', 'New Wave', 'Pop', 'Progressive Rock',
    'Rock', 'Symphonic Rock', 'Synthpop', 'Top 1500', 'Trance', 'Vocal',
);

sub initPlugin {
    my $class = shift;

    if ( main::WEBUI ) {
        Plugins::RandomFlow::Settings::Basic->new;
        Plugins::RandomFlow::Settings::Player->new;

        # Quickplay's browse/Extras menu entries (Henk, 23-09-2026).
        # NOT done via a separate webPages() class method, even though
        # that's the usual mechanism (see the removed sub's own comment
        # below, kept as a warning) - webPages() is only ever invoked
        # FROM WITHIN Slim::Plugin::Base's own initPlugin
        # ($class->can('webPages') && $class->webPages, confirmed against
        # the real Lyrion source, 24-09-2026). This throwaway Plugin.pm
        # doesn't inherit Slim::Plugin::Base (same reason ProtocolHandler.pm's
        # own header flags _pluginDataFor('icon') as unsafe here), so that
        # method body was simply dead code - nothing ever called it, which
        # is exactly why Quickplay registered nothing and never showed up
        # anywhere (not Material's Extras, not Classic's browse menu
        # either). Calling it directly here, the same way the two Settings
        # pages just above already register themselves, actually works.
        Plugins::RandomFlow::Web::registerPages();
    }

    # startmix/stopmix - reachable as plain slim.request calls (same
    # JSON-RPC shape SugarCube's own scStartChain uses for its "Start
    # New Chain" button), so a future Live page never needs a full page
    # navigation just to start or stop a player's mix.
    Slim::Control::Request::addDispatch(['randomflow', 'startmix'], [1, 0, 0, \&_handleStartMix]);
    Slim::Control::Request::addDispatch(['randomflow', 'stopmix'],  [1, 0, 0, \&_handleStopMix]);
    # setautomix - Henk, 26-09-2026: NOT the same as startmix/stopmix
    # above. He found that flipping the new Auto Mix toggle mid-song was
    # reusing 'startmix', which deliberately clears the queue and jumps
    # to a fresh pick right away (that's the right behaviour for the
    # dedicated "Start New Mix" icon button, which exists specifically to
    # do that) - but it meant enabling Auto Mix while enjoying a track
    # threw that track away. This action just arms/disarms the mixRunning
    # pref without ever touching current playback - see
    # MixRunner::setAutoMix's own comment for exactly what it does
    # instead. Reached the same JSON-RPC way as startmix/stopmix, and
    # still fires Plugin.pm's setChange watcher on mixRunning (below)
    # exactly the same, since that watcher reacts to the pref changing
    # however it changed.
    Slim::Control::Request::addDispatch(['randomflow', 'setautomix', '_value'], [1, 0, 0, \&_handleSetAutoMix]);
    # Settings entry for Jive clients (e.g. Squeezeclient); Auto Mix reuses setautomix above.
    Slim::Control::Jive::registerPluginMenu([{
        text    => Slim::Utils::Strings::string('PLUGIN_RANDOMFLOW_GLOBAL_SETTINGS'),
        id      => 'pluginRandomFlowSettings',
        weight  => 20,
        actions => { go => { player => 0, cmd => ['randomflow', 'menu'] } },
        window  => { titleStyle => 'settings' },
    }], 'settings');
    Slim::Control::Request::addDispatch(['randomflow', 'menu'], [0, 0, 1, \&_handleJiveMenu]);
    # "Start mix" entry in the track info menu (same mechanism as SugarCube's "mix from here")
    Slim::Menu::TrackInfo->registerInfoProvider(
        randomflow => (
            before => 'playitem',
            func   => \&_trackInfoStartMix,
        )
    );
    # replacenext - Henk, 25-09-2026: RandomFlow's own equivalent of
    # SC-EXTMIP's "Replace Track" ('sugarcube replacenext'/scReplaceNext) -
    # same JSON-RPC shape, so the Live page's "Replace Track" icon button
    # never needs a full page navigation either. See MixRunner::replaceNext
    # for why this one needs no sc_can_act-style gate: unlike SugarCube's
    # chain/batch modes, this plugin's queue only ever holds the current
    # track plus at most ONE upcoming track, so "exactly one queued" is
    # always the actual state whenever there IS anything to replace at all.
    Slim::Control::Request::addDispatch(['randomflow', 'replacenext'], [1, 0, 0, \&_handleReplaceNext]);
    # startbatch/topup - Henk, 28-09-2026: SC-EXTMIP's Start Batch/"top
    # up" pair (Live page, under Current Track / Next Track). Both take
    # the batch size from the player's own "batchSize" setting (Settings/
    # Player.pm) - see MixRunner::startBatch/topUpQueue.
    Slim::Control::Request::addDispatch(['randomflow', 'startbatch'], [1, 0, 0, \&_handleStartBatch]);
    Slim::Control::Request::addDispatch(['randomflow', 'topup'],      [1, 0, 0, \&_handleTopUp]);
    # rejectedtracks - Henk, 25-09-2026: backs the Live page's "Afgewezen
    # tracks" panel. Resolves this player's (or its synced source
    # player's - see MixRunner::resolveCriteria) filter the same way a
    # real pick would, then asks TrackSelector::findRejectedTracks() for
    # up to REJECTED_LIST_CAP tracks that filter would actually exclude,
    # with why. Read-only - unlike startmix/stopmix/replacenext this
    # dispatch itself never touches the queue.
    Slim::Control::Request::addDispatch(['randomflow', 'rejectedtracks'], [1, 0, 0, \&_handleRejectedTracks]);
    # queuetrack - Henk, 25-09-2026: the "Afgewezen tracks" panel's own
    # "queue as next" button. '_trackid' is a positional param, exactly
    # SC-EXTMIP's own 'sugarcube replacesel _trackid' pattern (Plugin.pm/
    # scReplaceSelection there) - a numeric Track id, resolved to a URL
    # here via Slim::Schema->find, not a raw URL sent over the wire. Same
    # reason SC does it that way: a rescan between listing the panel and
    # clicking a row changes track ids library-wide, so this can fail
    # gracefully ("no longer in the library") instead of half-matching a
    # stale URL.
    Slim::Control::Request::addDispatch(['randomflow', 'queuetrack', '_trackid'], [1, 0, 0, \&_handleQueueTrack]);
    # historytracks - Henk, 25-09-2026: backs the Live page's "History"
    # panel. Deliberately NOT scoped to this player's mix criteria the
    # way rejectedtracks is - see TrackSelector::findRecentlyPlayed's own
    # comment for why this is a genuine "what did I actually just
    # listen to" list (Lyrion's own lastPlayed tracking), not a mix-
    # criteria query. Its "queue as next" button reuses the SAME
    # queuetrack action above - a track id resolves to a URL to queue
    # the same way regardless of which panel it came from.
    Slim::Control::Request::addDispatch(['randomflow', 'historytracks'], [1, 0, 0, \&_handleHistoryTracks]);
    # trackstats - Henk, 25-09-2026, THIRD round: backs the new Now
    # Playing/Up Next stat lines' "Last Played" field. Genre/rating/
    # playcount all ride along on the page's own cometd status push
    # (Lyrion's own g/R/O track tags) - lastPlayed has no tag at all
    # (confirmed against the real LMS source, see TrackSelector::
    # lastPlayedForTracks' own comment), so it needs this own small
    # lookup instead. '_trackids' is a comma-separated string, not a
    # single positional id like '_trackid' elsewhere - this is called
    # with one or two ids at once (current + next track).
    Slim::Control::Request::addDispatch(['randomflow', 'trackstats', '_trackids'], [1, 0, 0, \&_handleTrackStats]);
    # mixsettings/setfilter/setwobble/setmaxplaycount/setartistcooldown/
    # setalbumcooldown - Henk, 25-09-2026: back the Live page's "Mix
    # Settings" section. Started with just the filter switcher (same
    # round); THIRD round (Henk: "ratings hoeft er niet bij, de rest mag
    # je bouwen") adds Wobble, Max Playcount, Artist Cooldown and Album
    # Cooldown - the rest of the 25-09-2026 "good candidates" list except
    # exclude-ratings, which Henk explicitly said to skip.
    #
    # mixsettings() is read-only - was 'filters' (read-only, filters +
    # activeFilterId only) until this round, renamed since it now returns
    # this whole section's initial state in one call: the global
    # genreFilters list (id/name only, same shape Settings/Player.pm's
    # own dropdown uses), plus this player's current activeFilterId,
    # wobble, maxPlaycount, artistCooldownTracks and albumCooldownTracks -
    # the exact same per-player prefs Settings/Player.pm's own sliders
    # read/write (see that page's own DEFAULTS/@SCALAR_PREFS for the
    # underlying pref names and default values this mirrors).
    #
    # Each setX() action saves ONE of those prefs and, same as
    # setfilter() does (see _handleSetFilter's own comment for the full
    # reasoning - "ik wissel nu, dus de volgende track moet ook meteen
    # kloppen"), immediately replaces the already-queued upcoming track
    # via MixRunner::replaceNext() so the change is felt right away, not
    # only once the current upcoming track finishes playing. Wobble/
    # Artist Cooldown/Album Cooldown are clamped 0-100 server-side, same
    # range Settings/Player.pm's own sliderInput_0_100 fields enforce.
    # Max Playcount has no fixed range (it's a playcount ceiling, not a
    # percentage) - blank/non-numeric means "no limit" (stored as undef,
    # never an empty string - same convention Settings/Player.pm's own
    # handler() uses for this exact pref).
    Slim::Control::Request::addDispatch(['randomflow', 'mixsettings'], [1, 0, 0, \&_handleMixSettings]);
    Slim::Control::Request::addDispatch(['randomflow', 'setfilter', '_filterid'], [1, 0, 0, \&_handleSetFilter]);
    Slim::Control::Request::addDispatch(['randomflow', 'setmixmode', '_value'], [1, 0, 0, \&_handleSetMixMode]);
    Slim::Control::Request::addDispatch(['randomflow', 'setwobble', '_value'], [1, 0, 0, \&_handleSetWobble]);
    Slim::Control::Request::addDispatch(['randomflow', 'setbatchsize', '_value'], [1, 0, 0, \&_handleSetBatchSize]);
    Slim::Control::Request::addDispatch(['randomflow', 'setmaxplaycount', '_value'], [1, 0, 0, \&_handleSetMaxPlaycount]);
    Slim::Control::Request::addDispatch(['randomflow', 'setartistcooldown', '_value'], [1, 0, 0, \&_handleSetArtistCooldown]);
    Slim::Control::Request::addDispatch(['randomflow', 'setalbumcooldown', '_value'], [1, 0, 0, \&_handleSetAlbumCooldown]);

    # Auto Mix <-> DSTM clash - no longer auto-resolved (removed 30-09-2026,
    # Henk: caused a real race, DSTM's own check consistently beat Auto
    # Mix's own top-up timer whenever DSTM was set to a RandomFlow provider).
    # The Live page's Auto Mix info popover now just warns that the two
    # shouldn't both be active for the same player - the user picks one.

    Plugins::RandomFlow::MixRunner::init();

    # Alarm support (Henk, 20-09-2026 - uses SugarCube's alarm option as
    # his actual wake-up alarm today, wants the same here). Same
    # mechanism as SugarCube: register a placeholder URL scheme with
    # Lyrion's native Alarm Clock, then intercept it in
    # ProtocolHandler::overridePlayback and hand off to MixRunner's own
    # startMix - see ProtocolHandler.pm's header for the full chain.
    Slim::Player::ProtocolHandlers->registerHandler(
        randomflow => 'Plugins::RandomFlow::ProtocolHandler');
    getAlarmPlaylists();

    # This self-test used to log at ERROR level, which shows regardless
    # of this category's configured log level - meaning it printed on
    # every single plugin load/server restart whether anyone wanted it
    # or not. Since 24-09-2026 (Henk's request) it only logs (now at
    # DEBUG level) AND only runs at all when this category's log level
    # is actually set to Debug - no wasted diagnostic DB queries on a
    # normal startup either, not just a quieter log.
    if ($log->is_debug) {
        Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 5, \&_runTest);
    }

    return 1;
}

# Registers RandomFlow as a selectable "Don't Stop The Music" provider
# (Henk, 30-09-2026) - a second, independent entry point into the same
# picks Start Mix/Auto Mix already use, for players that prefer DSTM's
# own on/off switch. Runs in postinitPlugin (after every plugin's own
# initPlugin has completed) and only registers if DSTM itself is
# actually enabled - same pattern real DSTM providers use (e.g.
# CDrummond's MIPMixer), confirmed against that source rather than
# guessed. See MixRunner::dstmHandler for the actual pick logic.
sub postinitPlugin {
    my $class = shift;

    require Slim::Utils::PluginManager;
    if (Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin')) {
        require Slim::Plugin::DontStopTheMusic::Plugin;
        Slim::Plugin::DontStopTheMusic::Plugin->registerHandler(
            'PLUGIN_RANDOMFLOW_DSTM', \&Plugins::RandomFlow::MixRunner::dstmHandler);
        Slim::Plugin::DontStopTheMusic::Plugin->registerHandler(
            'PLUGIN_RANDOMFLOW_DSTM_BATCH', \&Plugins::RandomFlow::MixRunner::dstmHandlerBatch);
        $log->info('RandomFlow: registered as a Don\'t Stop The Music provider (Mix + Batch).');
    }
}


sub getAlarmPlaylists {
    # The first arg is used BOTH as the internal registration key AND,
    # crucially, as a string() lookup for the group heading shown in
    # Lyrion's alarm playlist selector (see Slim::Utils::Alarm::
    # getPlaylists - it calls cstring($client, $type) whenever $type is
    # all-uppercase). It must match a REAL strings.txt token exactly -
    # SugarCube's own registration uses 'PLUGIN_SUGARCUBE', which is a
    # real token in their strings.txt. This used to say
    # 'PLUGIN_RANDOMFLOW' here, which is NOT a token we define
    # (only the unprefixed 'RANDOMFLOW' is) - cstring() silently
    # returns undef for an unknown token (no error, no fallback text),
    # which is almost certainly why the whole group failed to show up
    # in Henk's alarm sound list at all (20-09-2026).
    Slim::Utils::Alarm->addPlaylists(
        'RANDOMFLOW',
        [
            {
                title => '{PLUGIN_RANDOMFLOW_ALARM}',
                url   => 'randomflow:mix',
            },
        ]
    );
}

sub _handleStartMix {
    my $request = shift;
    my $client = $request->client();
    return unless $client;

    Plugins::RandomFlow::MixRunner::startMix($client);

    $request->setStatusDone();
    return;
}

sub _handleStopMix {
    my $request = shift;
    my $client = $request->client();
    return unless $client;

    Plugins::RandomFlow::MixRunner::stopMix($client);

    $request->setStatusDone();
    return;
}

sub _handleSetAutoMix {
    my $request = shift;
    my $client = $request->client();
    return unless $client;

    my $value = $request->getParam('_value');
    Plugins::RandomFlow::MixRunner::setAutoMix($client, $value ? 1 : 0);

    $request->setStatusDone();
    return;
}

sub _trackInfoStartMix {
    my ($client) = @_;
    return unless $client;

    return {
        type      => 'redirect',
        name      => Slim::Utils::Strings::string('PLUGIN_RANDOMFLOW_QUICKPLAY'),
        favorites => 0,
        jive      => { actions => { go => {
            player     => 0,
            cmd        => ['randomflow', 'startmix'],
            nextWindow => 'nowPlaying',
        } } },
    };
}

sub _handleJiveMenu {
    my $request = shift;
    my $client = $request->client();
    if (!$client) {
        $request->setStatusNeedsClient();
        return;
    }

    # Auto Mix state lives on the sync-group master (see _handleMixSettings)
    my $mixMaster = $client->can('master') ? $client->master : $client;
    my $running = $prefs->client($mixMaster)->get('mixRunning') ? 1 : 0;

    my @items = ({
        text          => Slim::Utils::Strings::string('PLUGIN_RANDOMFLOW_JIVE_AUTOMIX'),
        choiceStrings => [ ucfirst(Slim::Utils::Strings::string('OFF')), ucfirst(Slim::Utils::Strings::string('ON')) ],
        selectedIndex => $running + 1,
        actions       => { do => { choices => [
            { player => 0, cmd => ['randomflow', 'setautomix', '0'] },
            { player => 0, cmd => ['randomflow', 'setautomix', '1'] },
        ] } },
    }, {
        text          => Slim::Utils::Strings::string('PLUGIN_RANDOMFLOW_MIXMODE'),
        choiceStrings => [ Slim::Utils::Strings::string('PLUGIN_RANDOMFLOW_MIXMODE_SONGS'), Slim::Utils::Strings::string('PLUGIN_RANDOMFLOW_MIXMODE_ALBUMS') ],
        selectedIndex => (($prefs->client($client)->get('mixMode') || 'songs') eq 'albums' ? 2 : 1),
        actions       => { do => { choices => [
            { player => 0, cmd => ['randomflow', 'setmixmode', 'songs'] },
            { player => 0, cmd => ['randomflow', 'setmixmode', 'albums'] },
        ] } },
    });

    # Filter choice: "no filter" plus every defined filter ('' = no filter, see _handleSetFilter)
    my $filters = $prefs->get('genreFilters') || [];
    if (@$filters) {
        my $active = $prefs->client($client)->get('activeFilterId') || '';
        my @ids    = ('', map { $_->{id} } @$filters);
        my @names  = (Slim::Utils::Strings::string('PLUGIN_RANDOMFLOW_JIVE_NOFILTER'), map { $_->{name} } @$filters);
        my ($sel)  = grep { $ids[$_] eq $active } 0 .. $#ids;
        push @items, {
            text          => Slim::Utils::Strings::string('PLUGIN_RANDOMFLOW_ACTIVEFILTER'),
            choiceStrings => \@names,
            selectedIndex => ($sel // 0) + 1,
            actions       => { do => { choices => [
                map { +{ player => 0, cmd => ['randomflow', 'setfilter', $_] } } @ids
            ] } },
        };
    }

    # Wobble in steps of 10 (0-100); an in-between value selects the nearest step
    my @wobbleSteps = map { $_ * 10 } 0 .. 10;
    my $wobble = $prefs->client($client)->get('wobble') || 0;
    push @items, {
        text          => Slim::Utils::Strings::string('PLUGIN_RANDOMFLOW_WOBBLE'),
        choiceStrings => [ map { "$_" } @wobbleSteps ],
        selectedIndex => int($wobble / 10 + 0.5) + 1,
        actions       => { do => { choices => [
            map { +{ player => 0, cmd => ['randomflow', 'setwobble', $_] } } @wobbleSteps
        ] } },
    };

    # Batch size (10-100, steps of 10) only matters in Songs mode
    if (($prefs->client($client)->get('mixMode') || 'songs') ne 'albums') {
        my @batchSteps = map { $_ * 10 } 1 .. 10;
        my $batch = $prefs->client($client)->get('batchSize') || 20;
        push @items, {
            text          => Slim::Utils::Strings::string('PLUGIN_RANDOMFLOW_BATCHSIZE'),
            choiceStrings => [ map { "$_" } @batchSteps ],
            selectedIndex => (sort { $a <=> $b } (1, int($batch / 10 + 0.5), 10))[1],
            actions       => { do => { choices => [
                map { +{ player => 0, cmd => ['randomflow', 'setbatchsize', $_] } } @batchSteps
            ] } },
        };
    }

    # Max play count: "no limit" (sent as 'none') plus a fixed set; a current value outside
    # the set is added as an extra choice so it is never lost
    my $maxPlays = $prefs->client($client)->get('maxPlaycount');
    my %playSet  = map { $_ => 1 } (0 .. 5, 10, 15, 20);
    $playSet{$maxPlays} = 1 if defined $maxPlays && $maxPlays =~ /^\d+$/;
    my @playSteps = sort { $a <=> $b } keys %playSet;
    my ($playSel) = defined $maxPlays ? (grep { $playSteps[$_] == $maxPlays } 0 .. $#playSteps) : ();
    push @items, {
        text          => Slim::Utils::Strings::string('PLUGIN_RANDOMFLOW_MAXPLAYCOUNT'),
        choiceStrings => [ Slim::Utils::Strings::string('PLUGIN_RANDOMFLOW_NOLIMIT'), map { "$_" } @playSteps ],
        selectedIndex => defined $playSel ? $playSel + 2 : 1,
        actions       => { do => { choices => [
            { player => 0, cmd => ['randomflow', 'setmaxplaycount', 'none'] },
            map { +{ player => 0, cmd => ['randomflow', 'setmaxplaycount', $_] } } @playSteps
        ] } },
    };

    # Artist cooldown (tracks): fixed set, a current value outside it is added as an extra choice
    my $artistCd  = $prefs->client($client)->get('artistCooldownTracks') || 0;
    my %artistSet = map { $_ => 1 } (0, 5, 10, 15, 20, 25, 30, 40, 50, 75, 100);
    $artistSet{$artistCd} = 1;
    my @artistSteps = sort { $a <=> $b } keys %artistSet;
    my ($artistSel) = grep { $artistSteps[$_] == $artistCd } 0 .. $#artistSteps;
    push @items, {
        text          => Slim::Utils::Strings::string('PLUGIN_RANDOMFLOW_ARTISTCOOLDOWNTRACKS'),
        choiceStrings => [ map { "$_" } @artistSteps ],
        selectedIndex => $artistSel + 1,
        actions       => { do => { choices => [
            map { +{ player => 0, cmd => ['randomflow', 'setartistcooldown', $_] } } @artistSteps
        ] } },
    };

    # Album cooldown (tracks): same shape as artist cooldown above
    my $albumCd  = $prefs->client($client)->get('albumCooldownTracks') || 0;
    my %albumSet = map { $_ => 1 } (0, 5, 10, 15, 20, 25, 30, 40, 50, 75, 100);
    $albumSet{$albumCd} = 1;
    my @albumSteps = sort { $a <=> $b } keys %albumSet;
    my ($albumSel) = grep { $albumSteps[$_] == $albumCd } 0 .. $#albumSteps;
    push @items, {
        text          => Slim::Utils::Strings::string('PLUGIN_RANDOMFLOW_ALBUMCOOLDOWNTRACKS'),
        choiceStrings => [ map { "$_" } @albumSteps ],
        selectedIndex => $albumSel + 1,
        actions       => { do => { choices => [
            map { +{ player => 0, cmd => ['randomflow', 'setalbumcooldown', $_] } } @albumSteps
        ] } },
    };

    my $cnt = 0;
    $request->setResultLoopHash('item_loop', $cnt++, $_) for @items;
    $request->addResult('offset', 0);
    $request->addResult('count', scalar(@items));
    $request->setStatusDone();
    return;
}

sub _handleReplaceNext {
    my $request = shift;
    my $client = $request->client();
    return unless $client;

    Plugins::RandomFlow::MixRunner::replaceNext($client);

    $request->setStatusDone();
    return;
}

sub _handleStartBatch {
    my $request = shift;
    my $client = $request->client();
    return unless $client;

    Plugins::RandomFlow::MixRunner::startBatch($client);

    $request->setStatusDone();
    return;
}

sub _handleTopUp {
    my $request = shift;
    my $client = $request->client();
    return unless $client;

    Plugins::RandomFlow::MixRunner::topUpQueue($client);

    $request->setStatusDone();
    return;
}

sub _handleRejectedTracks {
    my $request = shift;
    my $client = $request->client();
    return unless $client;

    my $criteria = Plugins::RandomFlow::MixRunner::resolveCriteria($client);
    my $result   = TrackSelector::findRejectedTracks(%$criteria);

    # Plain arrayref of small hashrefs - no rating/playCount/albumId
    # passed through, the Live page only needs enough to show a row and
    # let the user queue it - reasons are the whole point of this panel,
    # so those always come along. trackId (not the raw url) is what the
    # "queue this instead" button sends back to the queuetrack action
    # below - same numeric-id convention SC-EXTMIP's own "Use as Next"
    # uses (Slim::Schema->find('Track', $id)), which degrades gracefully
    # ("no longer in library") if a rescan happened between listing and
    # clicking, rather than trying to re-match a raw URL string. coverId
    # (25-09-2026, Henk's request) may legitimately come back undef - see
    # TrackSelector::findRejectedTracks' own comment on why - live.html
    # already knows how to show a plain placeholder for that, same as it
    # already does for the Queue panel's own rows.
    my @tracks = map {
        {
            trackId => $_->{trackId},
            title   => $_->{title},
            artist  => $_->{artist},
            coverId => $_->{coverId},
            reasons => $_->{reasons},
        }
    } @{ $result->{tracks} };

    $request->addResult('tracks', \@tracks);
    $request->addResult('totalCount', $result->{totalCount});
    $request->setStatusDone();
    return;
}

sub _handleQueueTrack {
    my $request = shift;
    my $client = $request->client();
    return unless $client;

    my $trackId = $request->getParam('_trackid');
    if (!defined $trackId || $trackId eq '') {
        $log->warn("RandomFlow: queuetrack called with no track id.");
        $request->setStatusBadParams();
        return;
    }

    my $track = Slim::Schema->find('Track', $trackId);
    if (!$track || !$track->url) {
        # Most likely a rescan since the Afgewezen tracks list was built -
        # track ids change library-wide on a clear-and-rescan, same as
        # SC-EXTMIP's own scReplaceSelection has to allow for.
        $log->warn("RandomFlow: queuetrack - no track found for id $trackId (library rescanned since the panel was opened?).");
        $request->setStatusDone();
        return;
    }

    Plugins::RandomFlow::MixRunner::queueSpecificTrack($client, $track->url);

    $request->setStatusDone();
    return;
}

# Resolves the global "History panel track count" setting (Settings/
# Basic.pm's historyDisplayCount pref) to an actual limit. Only two
# states, not historyLimit's three (see that pref's own design note in
# Settings/Basic.pm for why "no limit" isn't offered here) - undef/blank
# falls back to TrackSelector::DEFAULT_HISTORY_DISPLAY_COUNT, anything
# else is passed through as-is and clamped server-side in
# TrackSelector::findRecentlyPlayed itself (MAX_HISTORY_DISPLAY_COUNT).
sub _historyDisplayCount {
    my $raw = $prefs->get('historyDisplayCount');
    return undef unless defined $raw && length $raw;
    return $raw;
}

sub _handleHistoryTracks {
    my $request = shift;
    my $client = $request->client();
    return unless $client;

    my $result = TrackSelector::findRecentlyPlayed(limit => _historyDisplayCount());

    # Same trimmed-down shape as _handleRejectedTracks above, plus the
    # album/lastPlayed fields that panel doesn't need - History's rows
    # show a bit more (album/year, when it last played), same richness
    # as the Queue panel's own rows.
    my @tracks = map {
        {
            trackId    => $_->{trackId},
            title      => $_->{title},
            artist     => $_->{artist},
            albumTitle => $_->{albumTitle},
            albumYear  => $_->{albumYear},
            coverId    => $_->{coverId},
            lastPlayed => $_->{lastPlayed},
            rating     => $_->{rating},
        }
    } @{ $result->{tracks} };

    $request->addResult('tracks', \@tracks);
    $request->addResult('totalCount', $result->{totalCount});
    $request->addResult('unavailable', $result->{unavailable});
    $request->setStatusDone();
    return;
}

sub _handleTrackStats {
    my $request = shift;

    my $idsRaw = $request->getParam('_trackids');
    my @ids = grep { /^\d+$/ } split(/,/, $idsRaw || '');

    my $stats = @ids ? TrackSelector::lastPlayedForTracks(@ids) : {};

    $request->addResult('stats', $stats);
    $request->setStatusDone();
    return;
}

sub _handleMixSettings {
    my $request = shift;
    my $client = $request->client();
    return unless $client;

    my $filters = $prefs->get('genreFilters') || [];
    my @filterList = map { { id => $_->{id}, name => $_->{name} } } @$filters;

    my $clientPrefs = $prefs->client($client);

    $request->addResult('filters', \@filterList);
    $request->addResult('activeFilterId', $clientPrefs->get('activeFilterId') || '');
    # Album Mix mode (Henk, 29-09-2026) - read once at page load, same as
    # the rest of this call's fields; live.html uses it to hide the
    # Songs-only Start Batch/Top Up buttons and switch Replace Track's
    # behaviour, see MixRunner.pm's own design notes.
    $request->addResult('mixMode', $clientPrefs->get('mixMode') || 'songs');
    # mixRunning ("Auto Mix": Henk, 26-09-2026) is stored on the sync-group
    # MASTER, not necessarily this exact player (see MixRunner.pm's own
    # startMix/stopMix comment on why) - read it from there, same as the
    # new Auto Mix<->DSTM watcher in initPlugin does, so a synced slave's
    # own Live page still shows the right state rather than always "off".
    my $mixMaster = $client->can('master') ? $client->master : $client;
    $request->addResult('mixRunning', $prefs->client($mixMaster)->get('mixRunning') || 0);
    # Same defaults as Settings/Player.pm's own DEFAULTS hash - a player
    # that has never opened that settings page (so its own init() never
    # ran) still gets sane values here rather than undef/blank, exactly
    # matching what that page itself would show on a first visit.
    $request->addResult('wobble', $clientPrefs->get('wobble') || 0);
    # maxPlaycount is deliberately passed through AS-IS, undef included -
    # JSON encodes that as null, which live.html reads as "no limit" the
    # same way an empty input does (see tstMixSettingsRender). Never
    # defaulted to 0 here - 0 would mean something completely different
    # (exclude every track that's ever been played even once).
    $request->addResult('maxPlaycount', $clientPrefs->get('maxPlaycount'));
    $request->addResult('artistCooldownTracks', $clientPrefs->get('artistCooldownTracks') || 0);
    $request->addResult('albumCooldownTracks', $clientPrefs->get('albumCooldownTracks') || 0);
    $request->setStatusDone();
    return;
}

sub _handleSetFilter {
    my $request = shift;
    my $client = $request->client();
    return unless $client;

    my $filterId = $request->getParam('_filterid');
    $filterId = '' unless defined $filterId;

    # '' is the deliberate "no filter" choice (same convention as
    # Settings/Player.pm's own <select> - see this dispatch's own
    # registration comment) - only reject a NON-empty id that doesn't
    # actually resolve to one of the current filters (e.g. stale
    # dropdown data from before a filter was deleted elsewhere).
    if (length $filterId) {
        my $filters = $prefs->get('genreFilters') || [];
        my ($match) = grep { $_->{id} eq $filterId } @$filters;
        if (!$match) {
            $log->warn("RandomFlow: setfilter - unknown filter id '$filterId', ignoring.");
            $request->setStatusBadParams();
            return;
        }
    }

    $prefs->client($client)->set('activeFilterId', $filterId);

    # Henk, 25-09-2026, second round: switching filters on the Live page
    # should feel immediate - "ik wissel nu, dus de volgende track moet
    # ook meteen kloppen" - not wait for the ALREADY-queued upcoming
    # track (picked under the OLD filter before this call) to finish
    # playing first. Reuses the exact same replaceNext() MixRunner
    # already uses for the "Replace Track" button - it re-reads
    # activeFilterId fresh (this save just changed it) and no-ops
    # harmlessly if no mix is running or nothing is actually queued yet
    # (see replaceNext's own comment for its "exactly one upcoming"
    # guard), so this is safe to call unconditionally here rather than
    # re-checking that state ourselves.
    Plugins::RandomFlow::MixRunner::replaceNext($client);

    $request->setStatusDone();
    return;
}

# Clamps a raw request param to a plain non-negative integer within
# [0, 100] - shared by setwobble/setartistcooldown/setalbumcooldown
# below, same range Settings/Player.pm's own sliderInput_0_100 fields
# enforce (see that page's own handler() clamp block). Anything that
# isn't a bare non-negative integer (missing, blank, negative sign,
# decimal point, non-numeric) falls back to 0 rather than erroring -
# a slider's own min/max already keeps the UI itself in range, this is
# just defense against a hand-crafted or stale request.
sub _clamp0to100 {
    my ($raw) = @_;
    return 0 unless defined $raw && $raw =~ /^\d+$/;
    my $value = int($raw);
    $value = 100 if $value > 100;
    return $value;
}

sub _handleSetBatchSize {
    my $request = shift;
    my $client = $request->client();
    return unless $client;

    my $raw = $request->getParam('_value');
    if (defined $raw && $raw =~ /^\d+$/) {
        my $size = int($raw);
        $size = 10  if $size < 10;
        $size = 100 if $size > 100;
        $prefs->client($client)->set('batchSize', $size);
    }

    $request->setStatusDone();
    return;
}

sub _handleSetMixMode {
    my $request = shift;
    my $client = $request->client();
    return unless $client;

    my $mode = ($request->getParam('_value') || '') eq 'albums' ? 'albums' : 'songs';
    $prefs->client($client)->set('mixMode', $mode);

    $request->setStatusDone();
    return;
}

sub _handleSetWobble {
    my $request = shift;
    my $client = $request->client();
    return unless $client;

    $prefs->client($client)->set('wobble', _clamp0to100($request->getParam('_value')));

    # Same "feel immediate" reasoning as setfilter() - see
    # _handleSetFilter's own comment.
    Plugins::RandomFlow::MixRunner::replaceNext($client);

    $request->setStatusDone();
    return;
}

sub _handleSetMaxPlaycount {
    my $request = shift;
    my $client = $request->client();
    return unless $client;

    my $raw = $request->getParam('_value');

    # Blank/non-numeric means "no limit" - stored as undef, never an
    # empty string, same convention Settings/Player.pm's own handler()
    # uses for this exact pref (see that page's own comment on
    # pref_maxPlaycount - an empty string would wrongly turn into a real
    # SQL comparison against '' inside TrackSelector.pm's query).
    if (!defined $raw || $raw eq '' || $raw !~ /^\d+$/) {
        $prefs->client($client)->set('maxPlaycount', undef);
    }
    else {
        $prefs->client($client)->set('maxPlaycount', int($raw));
    }

    Plugins::RandomFlow::MixRunner::replaceNext($client);

    $request->setStatusDone();
    return;
}

sub _handleSetArtistCooldown {
    my $request = shift;
    my $client = $request->client();
    return unless $client;

    $prefs->client($client)->set('artistCooldownTracks', _clamp0to100($request->getParam('_value')));

    Plugins::RandomFlow::MixRunner::replaceNext($client);

    $request->setStatusDone();
    return;
}

sub _handleSetAlbumCooldown {
    my $request = shift;
    my $client = $request->client();
    return unless $client;

    $prefs->client($client)->set('albumCooldownTracks', _clamp0to100($request->getParam('_value')));

    Plugins::RandomFlow::MixRunner::replaceNext($client);

    $request->setStatusDone();
    return;
}

sub _runTest {
    $log->debug("RandomFlow: starting test ...");

    my $pool = TrackSelector::selectTracks(
        genreGroup   => \@TEST_GENRE_LIST,
        maxPlaycount => 5,
        count        => 15,
    );

    if (!@$pool) {
        $log->debug("RandomFlow: TEST 1 FAILED - selectTracks() returned no tracks at all.");
        return;
    }

    $log->debug("RandomFlow: TEST 1 (hard constraints) - " . scalar(@$pool) . " tracks picked:");
    for my $t (@$pool) {
        $log->debug(sprintf("RandomFlow:   %-40s | artist=%-25s | playCount=%s | rating=%s",
            $t->{title}    // '?',
            $t->{artist}   // '?',
            defined $t->{playCount} ? $t->{playCount} : 'NULL',
            defined $t->{rating}    ? $t->{rating}    : 'NULL',
        ));
    }

    # Pick a real artist out of TEST 1's own results to use for the
    # weighting test, so we don't have to guess a name from your library.
    my ($testArtist) = grep { defined $_ && $_ ne '' } map { $_->{artist} } @$pool;
    if (!$testArtist) {
        $log->debug("RandomFlow: TEST 2 SKIPPED - none of TEST 1's results had an artist name to test with.");
        return;
    }

    $log->debug("RandomFlow: TEST 2 (soft weighting) - using artist '$testArtist' as the preferred artist.");

    my $weightedCount = _countArtistOverRuns($testArtist, 10, 20);
    # weight 0 -> multiplier 0+1 = 1 = truly neutral, since 24-09-2026's
    # SugarCube-matching (weight+1) formula - weight 1 is no longer a
    # no-op (it's already ~2x), see _countArtistOverRuns's own comment.
    my $controlCount  = _countArtistOverRuns($testArtist, 0, 20);

    $log->debug("RandomFlow: TEST 2 - '$testArtist' picked $weightedCount/20 times WITH preferredWeight=10");
    $log->debug("RandomFlow: TEST 2 - '$testArtist' picked $controlCount/20 times WITHOUT any weighting (control)");
    $log->debug("RandomFlow: TEST 2 - the weighted count should be noticeably higher than the control count.");

    _runCooldownTest();
    _runGenreHardFilterTest();
    _runWobbleTest($testArtist);
    _runPoolSizeTest();
    _runFilterResolutionTest();

    $log->debug("RandomFlow: done.");
}

sub _runFilterResolutionTest {
    $log->debug("RandomFlow: TEST 7 (filter + quick-block resolution) starting ...");

    my @filters = (
        { id => 'f1', name => 'Rock Night', genres => ['Rock', 'Hard Rock', 'Metal'] },
        { id => 'f2', name => 'Chill',      genres => ['Ambient', 'New Age'] },
    );

    my $ok = 1;

    # Plain resolve, no block list.
    my $r1 = resolveFilterGenres(\@filters, 'f1', []);
    $ok = 0 unless _sameSet($r1, ['Rock', 'Hard Rock', 'Metal']);

    # Block list removes one entry, case-insensitively.
    my $r2 = resolveFilterGenres(\@filters, 'f1', ['metal']);
    $ok = 0 unless _sameSet($r2, ['Rock', 'Hard Rock']);

    # Unknown/deleted filter id -> empty, not "everything".
    my $r3 = resolveFilterGenres(\@filters, 'f9-does-not-exist', []);
    $ok = 0 unless @$r3 == 0;

    # No filter chosen at all -> empty.
    my $r4 = resolveFilterGenres(\@filters, '', []);
    $ok = 0 unless @$r4 == 0;

    $log->debug("RandomFlow: TEST 7 - " . ($ok ? "all checks passed." : "FAILED - see TrackSelector.pm/Settings/Util.pm for resolveFilterGenres()."));
}

sub _sameSet {
    my ($got, $expected) = @_;
    my %gotLc      = map { lc($_) => 1 } @$got;
    my %expectedLc = map { lc($_) => 1 } @$expected;
    return 0 unless scalar(keys %gotLc) == scalar(keys %expectedLc);
    for my $k (keys %expectedLc) {
        return 0 unless $gotLc{$k};
    }
    return 1;
}

# TEST 4 used to check three Style/genreStrictness variants (Strict/50/0).
# Style was removed 20-09-2026 - Henk confirmed genre must ALWAYS be a
# hard filter, no soft mode - so this now just confirms that's still
# true: a narrow genre selection should never leak a track from outside it.
sub _runGenreHardFilterTest {
    $log->debug("RandomFlow: TEST 4 (genre is always a hard filter) starting ...");

    my @narrowGenre = ('Rock');
    my $dbh = Slim::Schema->dbh;

    my $picked = TrackSelector::selectTracks(genreGroup => \@narrowGenre, poolSize => 300, count => 30);
    my $outside = grep { !_isInGenre($dbh, $_->{url}, \@narrowGenre) } @$picked;
    $log->debug("RandomFlow: TEST 4 - $outside/" . scalar(@$picked) . " picks were outside Rock (should always be 0).");
}

sub _isInGenre {
    my ($dbh, $url, $genreList) = @_;

    my $sql = q{
        SELECT COUNT(*) FROM tracks t
        JOIN genre_track gt ON gt.track = t.id
        JOIN genres g ON g.id = gt.genre
        WHERE t.url = ? AND g.name IN (} . join(',', ('?') x @$genreList) . q{)
    };
    my ($count) = eval { $dbh->selectrow_array($sql, undef, $url, @$genreList) };
    return $count && $count > 0;
}

sub _runWobbleTest {
    my ($artist) = @_;

    $log->debug("RandomFlow: TEST 5 (Wobble) starting ...");

    if (!$artist) {
        $log->debug("RandomFlow: TEST 5 SKIPPED - no test artist available from TEST 1.");
        return;
    }

    my $tight = _countArtistOverRunsWobble($artist, 10, 0, 30);
    my $loose = _countArtistOverRunsWobble($artist, 10, 100, 30);

    $log->debug("RandomFlow: TEST 5 - '$artist' picked $tight/30 times with wobble=0 (Tight, preferredWeight=10).");
    $log->debug("RandomFlow: TEST 5 - '$artist' picked $loose/30 times with wobble=100 (Loose, same weight - should be noticeably lower).");
}

sub _countArtistOverRunsWobble {
    my ($artist, $weight, $wobble, $runs) = @_;

    my $hits = 0;
    for (1 .. $runs) {
        my $picked = TrackSelector::selectTracks(
            genreGroup       => \@TEST_GENRE_LIST,
            maxPlaycount     => 5,
            preferredArtists => [$artist],
            preferredWeight  => $weight,
            wobble           => $wobble,
            count            => 1,
        );
        next unless @$picked;
        $hits++ if lc($picked->[0]{artist} // '') eq lc($artist);
    }

    return $hits;
}

sub _runPoolSizeTest {
    $log->debug("RandomFlow: TEST 6 (ask size / poolSize) starting ...");

    my $small = TrackSelector::selectTracks(genreGroup => \@TEST_GENRE_LIST, poolSize => 5, count => 5);
    $log->debug("RandomFlow: TEST 6 - poolSize=5, count=5 -> " . scalar(@$small) . " tracks picked (expect exactly 5).");
}

sub _runCooldownTest {
    $log->debug("RandomFlow: TEST 3 (artist cooldown) starting ...");

    my $dbh = Slim::Schema->dbh;

    # DIAGNOSTIC (added 20-09-2026 after 'both' unexpectedly returned 0
    # where 'apc' alone used to return 369): compare all three providers
    # directly, so we can see exactly where the count drops to 0 instead
    # of guessing at the SQL.
    for my $provider ('lyrion', 'apc', 'both') {
        my $recent = TrackSelector::_recentlyPlayedArtists($dbh, 30, $provider);
        $log->debug("RandomFlow: TEST 3 DIAGNOSTIC - provider='$provider': " . scalar(@$recent) . " artist(s) played in the last 30 days.");
    }

    # Also dump the raw tp.lastPlayed / apc.lastPlayed values for a
    # handful of tracks with a non-trivial APC playCount, so we can see
    # the actual shape of the data (NULL vs 0 vs a real epoch value).
    my $sampleSql = q{
        SELECT t.title, c.name AS artist, tp.lastPlayed AS tpLastPlayed, apc.lastPlayed AS apcLastPlayed, apc.playCount AS apcPlayCount
        FROM tracks t
        LEFT JOIN contributors c ON c.id = t.primary_artist
        LEFT JOIN p.alternativeplaycount apc ON apc.urlmd5 = t.urlmd5
        LEFT JOIN p.tracks_persistent tp ON tp.urlmd5 = t.urlmd5
        WHERE apc.playCount IS NOT NULL AND apc.playCount > 0
        ORDER BY apc.playCount DESC
        LIMIT 10
    };
    my $sampleRows = eval { $dbh->selectall_arrayref($sampleSql, { Slice => {} }) };
    if ($@) {
        $log->debug("RandomFlow: TEST 3 DIAGNOSTIC - sample query failed: $@");
    } else {
        $log->debug("RandomFlow: TEST 3 DIAGNOSTIC - raw lastPlayed values for 10 tracks with APC plays:");
        for my $row (@$sampleRows) {
            $log->debug(sprintf("RandomFlow:   %-30s | artist=%-20s | tp.lastPlayed=%s | apc.lastPlayed=%s | apc.playCount=%s",
                $row->{title}    // '?',
                $row->{artist}   // '?',
                defined $row->{tpLastPlayed}  ? $row->{tpLastPlayed}  : 'NULL',
                defined $row->{apcLastPlayed} ? $row->{apcLastPlayed} : 'NULL',
                defined $row->{apcPlayCount}  ? $row->{apcPlayCount}  : 'NULL',
            ));
        }
    }

    # This reaches into TrackSelector's own "private" helper on purpose -
    # this is a throwaway test harness, not production code, and it's
    # the most direct way to check the cooldown lookup itself works.
    #
    # 200 tracks (not days, since the 24-09-2026 change) - an arbitrary
    # but reasonable window for this diagnostic run.
    my $cooldownWindow = 200;
    my $recentN = TrackSelector::_recentlyPlayedArtists($dbh, $cooldownWindow, 'both');
    $log->debug("RandomFlow: TEST 3 - " . scalar(@$recentN) . " artist(s) among the last $cooldownWindow played tracks (provider=both).");

    if (!@$recentN) {
        $log->debug("RandomFlow: TEST 3 - none via 'both' - see the DIAGNOSTIC lines above for which provider(s) actually have data.");
        return;
    }

    # Diagnostic: which of those artists actually own the most tracks?
    # If this list is dominated by one or two huge outliers (e.g. a
    # "Various Artists"-style collective name), that would explain an
    # oversized drop below as an over-broad match rather than genuine
    # per-artist cooldown behaviour.
    my $topSql = q{
        SELECT c.name, COUNT(DISTINCT t.id) AS trackCount
        FROM tracks t
        JOIN contributors c ON c.id = t.primary_artist
        WHERE c.name IN (} . join(',', ('?') x @$recentN) . q{)
        GROUP BY c.name
        ORDER BY trackCount DESC
        LIMIT 15
    };
    my $topRows = eval { $dbh->selectall_arrayref($topSql, { Slice => {} }, @$recentN) };
    if ($@) {
        $log->debug("RandomFlow: TEST 3 - top-artist query failed: $@");
    } else {
        $log->debug("RandomFlow: TEST 3 - top 15 recently-played artists by track count:");
        for my $row (@$topRows) {
            $log->debug(sprintf("RandomFlow:   %-40s | %d tracks", $row->{name} // '?', $row->{trackCount}));
        }
    }

    # Deterministic check, not dependent on a specific artist's luck of
    # being drawn into a random sample: count how many tracks match the
    # broad genre filter in total, with and without the recently played
    # artists excluded. The "with cooldown" count must be lower.
    my $totalWithoutCooldown = _countMatching($dbh, []);
    my $totalWithCooldown    = _countMatching($dbh, $recentN);

    $log->debug("RandomFlow: TEST 3 - total matching tracks WITHOUT cooldown: $totalWithoutCooldown");
    $log->debug("RandomFlow: TEST 3 - total matching tracks WITH $cooldownWindow-track cooldown: $totalWithCooldown (should be lower)");

    # Anecdotal, best-effort extra check on one specific artist - can
    # legitimately show 0/0 by chance even when everything works, since
    # it only looks at one small 30-track random sample either way.
    my $cooldownArtist = $recentN->[0];
    my $withoutCooldown = TrackSelector::selectTracks(genreGroup => \@TEST_GENRE_LIST, count => 30);
    my $withCooldown    = TrackSelector::selectTracks(genreGroup => \@TEST_GENRE_LIST, artistCooldownTracks => $cooldownWindow, count => 30);
    my $seenWithout = grep { lc($_->{artist} // '') eq lc($cooldownArtist) } @$withoutCooldown;
    my $seenWith    = grep { lc($_->{artist} // '') eq lc($cooldownArtist) } @$withCooldown;
    $log->debug("RandomFlow: TEST 3 - (anecdotal) '$cooldownArtist' appeared $seenWithout/30 without cooldown, $seenWith/30 with cooldown.");
}

# Direct count of tracks matching the broad genre filter, optionally
# excluding a given list of artist names - used to prove the cooldown
# mechanism narrows the candidate set, without relying on a random
# sample happening to include (or exclude) any one artist.
sub _countMatching {
    my ($dbh, $excludeArtists) = @_;

    my @where = ('t.audio = 1', 'g.name IN (' . join(',', ('?') x @TEST_GENRE_LIST) . ')');
    my @bind  = @TEST_GENRE_LIST;

    if (@$excludeArtists) {
        push @where, '(c.name IS NULL OR c.name NOT IN (' . join(',', ('?') x @$excludeArtists) . '))';
        push @bind, @$excludeArtists;
    }

    my $sql = q{
        SELECT COUNT(DISTINCT t.id)
        FROM tracks t
        JOIN genre_track gt ON gt.track = t.id
        JOIN genres g ON g.id = gt.genre
        LEFT JOIN contributors c ON c.id = t.primary_artist
        WHERE } . join(' AND ', @where);

    my ($count) = eval { $dbh->selectrow_array($sql, undef, @bind) };
    if ($@) {
        $log->debug("RandomFlow: TEST 3 - count query failed: $@");
        return -1;
    }

    return $count;
}

# Runs selectTracks() $runs times, each picking exactly 1 track, with
# $artist given $weight as preferredWeight. Since 24-09-2026 this uses
# SugarCube's own (weight+1) multiplier - weight 0 = no preference (the
# control run), weight 1 = ~2x as likely, weight 5 = ~6x as likely.
# Returns how many of those runs picked $artist.
sub _countArtistOverRuns {
    my ($artist, $weight, $runs) = @_;

    my $hits = 0;
    for (1 .. $runs) {
        my $picked = TrackSelector::selectTracks(
            genreGroup       => \@TEST_GENRE_LIST,
            maxPlaycount     => 5,
            preferredArtists => [$artist],
            preferredWeight  => $weight,
            count            => 1,
        );
        next unless @$picked;
        $hits++ if lc($picked->[0]{artist} // '') eq lc($artist);
    }

    return $hits;
}

1;

__END__
