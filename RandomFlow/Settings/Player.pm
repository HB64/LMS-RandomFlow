package Plugins::RandomFlow::Settings::Player;

#
# PER-PLAYER settings for the TrackSelector engine - every field
# selectTracks() accepts (see TrackSelector.pm's own criteria docs)
# EXCEPT playCountProvider, which is global (Settings/Basic.pm).
#
# Genre selection itself is no longer done here directly - genres are
# grouped into named FILTERS managed globally
# (Settings/Basic.pm, like MusicIP's filters), and a player just picks
# which filter it uses (activeFilterId) plus an optional quick
# comma-separated genreBlock to exclude specific genres from whichever
# filter is active, without touching the filter itself. The actual
# filter+block -> genre list resolution lives in
# Settings::Util::resolveFilterGenres(), so both this page and (later)
# the Live page can reuse it identically.
#
# Scalar prefs (activeFilterId, wobble "Wobble", poolSize "ask size",
# artistCooldownTracks, albumCooldownTracks, maxPlaycount, preferredWeight,
# lessPreferredWeight)
# are left to the base class's own
# handler() - see Slim::Web::Settings::handler - which reads pref_<name>
# from the form and stores it via the client-scoped prefs object. We
# only clamp the numeric ones' ranges first, same pattern as
# BlissMixer::Settings.
#
# Array-type prefs (genreBlock, excludeRatings, artistBlock,
# preferredArtists, lessPreferredArtists) are NOT left to the base
# handler - it only knows how to store a single scalar value per pref -
# so those are parsed and stored explicitly in our own handler() below,
# then deliberately excluded from the list passed to SUPER::handler.
#

use strict;
use warnings;

use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Utils::Log;

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.randomflow',
    'defaultLevel' => 'INFO',
});

my $prefs = preferences('plugin.randomflow');

# Mirrors TrackSelector.pm's own %criteria defaults - see the design
# notes at the top of that file. (genreGroup itself isn't stored here
# any more - it's resolved at mix time from activeFilterId + genreBlock,
# see the file header above.)
my %DEFAULTS = (
    mixMode              => 'songs',   # 'songs' (default) or 'albums'
    activeFilterId       => '',
    genreBlock           => [],
    artistBlock          => [],
    maxPlaycount         => undef,   # undef = no limit
    excludeRatings       => [],
    preferredArtists     => [],
    preferredWeight      => 5,
    lessPreferredArtists => [],
    lessPreferredWeight  => 1,
    artistCooldownTracks => 0,
    albumCooldownTracks  => 0,
    wobble               => 0,
    poolSize             => 300,
    batchSize            => 20,   # batch mode track count, clamped 10-100 (see handler())
);

# mixRunning ("Auto Mix") is deliberately NOT in %DEFAULTS above, and
# never will be: seeding a default here previously caused it to
# silently reset to disabled after every server restart (init() is
# supposed to leave an already-set value alone, but didn't for this
# one reliably across a restart - never fully root-caused, but
# omitting the default here entirely removes the only mechanism that
# could be doing it). It's set by MixRunner::startMix/
# stopMix/setAutoMix via the randomflow startmix/stopmix/setautomix
# JSON-RPC actions instead, and every place that reads it already
# treats "never set" the same as "off" (get('mixRunning') is falsy when
# undef), so it needs no default seeded here at all.

# Handed to the base class's own handler() - plain scalar values only.
my @SCALAR_PREFS = qw(
    mixMode
    activeFilterId
    maxPlaycount
    preferredWeight
    lessPreferredWeight
    artistCooldownTracks
    albumCooldownTracks
    wobble
    poolSize
    batchSize
);

sub name {
    return Slim::Web::HTTP::CSRF->protectName('PLUGIN_RANDOMFLOW_PLAYER_SETTINGS');
}

sub page {
    return Slim::Web::HTTP::CSRF->protectURI('plugins/RandomFlow/settings/player.html');
}

sub needsClient {
    return 1;
}

sub prefs {
    my ($class, $client) = @_;

    return unless defined $client;

    # init() only fills in a value that isn't already set, so this is
    # safe to call on every page load - it just seeds sane defaults the
    # first time a given player's settings are touched.
    $prefs->client($client)->init({ %DEFAULTS });

    return ($prefs->client($client), @SCALAR_PREFS);
}

sub handler {
    my ($class, $client, $paramRef) = @_;

    return $class->SUPER::handler($client, $paramRef) unless defined $client;

    my $clientPrefs = $prefs->client($client);
    $clientPrefs->init({ %DEFAULTS });

    if ($paramRef->{'saveSettings'}) {

        # Clamp the numeric sliders into sane ranges before the base
        # handler stores them - same pattern as BlissMixer::Settings.
        for my $setting (
            ['pref_wobble',              0,   100],
            ['pref_artistCooldownTracks',0,   100],   # matches SugarCube's "Block Artist Repeating for x Tracks" max
            ['pref_albumCooldownTracks', 0,   100],   # matches SugarCube's "Block Album Repeating for x Tracks" max
            ['pref_poolSize',            1,  5000],
            ['pref_batchSize',          10,   100],
            ['pref_preferredWeight',     0,     5],   # matches SugarCube's "Preferred Artist Weight" max
            ['pref_lessPreferredWeight', 0,     5],   # same scale as preferredWeight above
        ) {
            my ($name, $min, $max) = @$setting;
            next unless defined $paramRef->{$name} && $paramRef->{$name} ne '';
            my $value = int($paramRef->{$name});
            $value = $min if $value < $min;
            $value = $max if $value > $max;
            $paramRef->{$name} = $value;
        }

        # maxPlaycount: blank or non-numeric means "no limit" -> undef,
        # never an empty string (TrackSelector.pm treats "defined" as
        # "apply this limit", so an empty string would wrongly turn into
        # a real SQL comparison against '').
        my $maxPlaycountRaw = $paramRef->{'pref_maxPlaycount'};
        if (!defined $maxPlaycountRaw || $maxPlaycountRaw !~ /^\d+$/) {
            $clientPrefs->set('maxPlaycount', undef);
            delete $paramRef->{'pref_maxPlaycount'};
        }

        # --- array-type prefs, handled here instead of the base handler ---

        # Quick genre block: comma-separated, blank entries ignored,
        # surrounding whitespace trimmed per entry - matched
        # case-insensitively against the active filter's genres at mix
        # time (see Settings::Util::resolveFilterGenres).
        my $genreBlockRaw = $paramRef->{'pref_genreBlock'};
        if (defined $genreBlockRaw) {
            my @blocked = grep { length $_ }
                          map  { my $s = $_; $s =~ s/^\s+|\s+$//g; $s }
                          split /,/, $genreBlockRaw;
            $clientPrefs->set('genreBlock', \@blocked);
        }

        my @selectedRatings;
        for my $r (1 .. 5) {
            push @selectedRatings, $r if $paramRef->{"pref_rating_$r"};
        }
        $clientPrefs->set('excludeRatings', \@selectedRatings);

        # Free-text artist lists: one name per line, blank lines
        # ignored, surrounding whitespace trimmed.
        for my $field (qw(artistBlock preferredArtists lessPreferredArtists)) {
            my $raw = $paramRef->{"pref_$field"};
            next unless defined $raw;
            my @names = grep { length $_ }
                        map  { my $s = $_; $s =~ s/^\s+|\s+$//g; $s }
                        split /\r?\n/, $raw;
            $clientPrefs->set($field, \@names);
        }
    }

    # Always (re)build what the template needs, whether or not this was
    # a save - so a plain page load shows the currently stored values.
    my $excludeRatings = $clientPrefs->get('excludeRatings') || [];

    $paramRef->{'prefs'}->{'pref_genreBlock'}           = join(', ', @{ $clientPrefs->get('genreBlock') || [] });
    $paramRef->{'prefs'}->{'pref_excludeRatings'}       = $excludeRatings;
    $paramRef->{'prefs'}->{'pref_artistBlock'}          = join("\n", @{ $clientPrefs->get('artistBlock')          || [] });
    $paramRef->{'prefs'}->{'pref_preferredArtists'}     = join("\n", @{ $clientPrefs->get('preferredArtists')     || [] });
    $paramRef->{'prefs'}->{'pref_lessPreferredArtists'} = join("\n", @{ $clientPrefs->get('lessPreferredArtists') || [] });

    # The global filter list, for the "which filter does this player
    # use" dropdown - id/name only is all the template needs.
    $paramRef->{'filters'}              = $prefs->get('genreFilters') || [];
    $paramRef->{'selectedRatingLookup'} = { map { $_ => 1 } @$excludeRatings };

    # For the Start/Stop mix buttons - set only by MixRunner itself (see
    # the DEFAULTS comment above), never by this settings page's own
    # save, so this always reflects the real current state.
    $paramRef->{'mixRunning'} = $clientPrefs->get('mixRunning') ? 1 : 0;

    return $class->SUPER::handler($client, $paramRef);
}

1;

__END__
