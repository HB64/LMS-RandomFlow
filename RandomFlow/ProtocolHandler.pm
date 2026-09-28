package Plugins::RandomFlow::ProtocolHandler;

#
# Lets RandomFlow's mix be picked as what Lyrion's own native
# Alarm Clock plays - Henk uses SugarCube's own alarm option as his
# actual wake-up alarm today and asked for the equivalent here
# (20-09-2026). Modelled directly on SugarCube's own ProtocolHandler.pm
# (SC-EXTMIP build):
#
#   - Plugin.pm's getAlarmPlaylists() registers a placeholder URL,
#     'randomflow:mix', with Lyrion's own
#     Slim::Utils::Alarm->addPlaylists() - this is what makes
#     "TrackSelector Test" show up as a choosable option in Lyrion's
#     native alarm settings, right alongside its built-in "Random Mix".
#   - When the alarm fires, Lyrion just tries to "play" that placeholder
#     URL like any other track. Because Plugin.pm's initPlugin registers
#     this class for the 'randomflow' URL scheme, Lyrion asks it
#     first via overridePlayback() instead of actually trying to stream
#     it.
#   - overridePlayback() arms a short one-shot timer (same 1-second
#     pattern SugarCube uses) that calls MixRunner::startMix($client) -
#     our own existing "start a mix" logic, completely unchanged.
#     startMix clears the queue, picks one real track from the player's
#     own active filter, and starts playing it - and because it also
#     sets the mixRunning flag, the mix keeps auto-topping-up from there
#     exactly like a manually-started one (MixRunner's own newsong
#     subscription takes over). No separate "alarm" code path is needed
#     anywhere else.
#   - Returning 1 from overridePlayback tells Lyrion "handled, don't try
#     to stream this yourself."
#
# NOT done (yet): SugarCube also lets the alarm use a DIFFERENT filter
# than the player's everyday one (its scalarm_filter pref, falling back
# to the player's own filter if unset). This uses only the player's own
# active filter for now - a separate alarm-only filter override can be
# added later the same way if Henk wants that distinction.
#

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Timers;
use Time::HiRes;

use Plugins::RandomFlow::MixRunner;

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.randomflow',
    'defaultLevel' => 'INFO',
});

sub overridePlayback {
    my ($class, $client, $url) = @_;

    return undef unless defined $url && $url =~ m{^randomflow:};
    return undef unless $client;

    $log->info("RandomFlow::ProtocolHandler: alarm fired for " . $client->name . " - starting mix.");

    # Same 1-second "load-bearing pause" SugarCube's own alarm/Chain
    # handling relies on - not strictly needed here (unlike the
    # newsong-driven top-up timer, there's no stale playlist-position
    # read to wait out), but kept for consistency and so this always
    # runs slightly after Lyrion's own alarm bookkeeping for this play
    # command has settled.
    Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 1, \&Plugins::RandomFlow::MixRunner::startMix);

    return 1;
}

sub canDirectStream { return 0; }
sub contentType     { return 'randomflow'; }
sub isRemote        { return 0; }

# SugarCube's own version of this calls _pluginDataFor('icon') on its
# Plugin.pm, but that method only exists because SugarCube's Plugin.pm
# inherits from Slim::Plugin::Base - this throwaway Plugin.pm doesn't,
# and install.xml doesn't declare an icon either, so that call would die
# with "Can't locate object method _pluginDataFor" the moment Lyrion
# asks for an icon while trying to play a randomflow: URL -
# aborting the whole play attempt with no obvious symptom other than
# "nothing happens". No icon is fine; returning undef here is what a
# protocol handler with no icon of its own is supposed to do.
sub getIcon { return undef; }

1;

__END__
