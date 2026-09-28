package Plugins::RandomFlow::Settings::Util;

#
# Small helpers shared between Settings/Basic.pm (global genre filters)
# and Settings/Player.pm (per-player filter choice + quick genre block).
# Nothing here is settings-page-specific - it's just the bits both pages
# need so they don't drift out of sync.
#

use strict;
use warnings;

use Exporter qw(import);
our @EXPORT_OK = qw(allGenres resolveFilterGenres resolveFilterArtists resolveFilterYears);

use Slim::Schema;
use Slim::Utils::Log;

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.randomflow',
    'defaultLevel' => 'INFO',
});

# All distinct genre names present in the library, alphabetically - used
# to build every genre checkbox list. Cheap enough to run on every page
# load and always reflects the current library, so there's no separate
# "rescan to refresh this list" step to remember.
sub allGenres {
    my $dbh = Slim::Schema->dbh;
    return [] unless $dbh;

    my $genres = eval {
        $dbh->selectcol_arrayref("SELECT name FROM genres ORDER BY name COLLATE NOCASE");
    };
    if ($@) {
        $log->error("RandomFlow::Settings::Util: could not fetch genre list: $@");
        return [];
    }

    return $genres || [];
}

# Resolves a player's chosen filter + its own quick-block list down to
# the final genre list TrackSelector.pm's genreGroup criterion should
# use.
#
#   $filters   - the global genreFilters arrayref, each { id, name, genres }
#   $filterId  - the player's chosen filter id (may be undef/'' if none
#                chosen yet)
#   $blockList - the player's own genreBlock arrayref (genre names to
#                exclude from whichever filter is active)
#
# Returns an empty arrayref if the filter id doesn't resolve to anything
# (none chosen, or the filter it pointed at was since deleted, or every
# genre in it got quick-blocked away).
#
# CALLERS MUST TREAT AN EMPTY RESULT AS "REFUSE TO MIX", NOT AS "NO
# CONSTRAINT" - this is not automatic. TrackSelector.pm's own genreGroup
# criterion treats an empty arrayref as "no genre WHERE clause at all",
# i.e. matches the ENTIRE library (that's documented there as
# deliberate: "pass all genres to effectively disable genre filtering").
# So a caller that hands an unresolved/empty result straight to
# selectTracks() would silently mix from the whole library instead of
# failing safe. See MixRunner.pm's startMix/_maybeQueueNext for the
# actual "refuse if empty" guard - that check lives there, not here.
sub resolveFilterGenres {
    my ($filters, $filterId, $blockList) = @_;

    return [] unless defined $filterId && length $filterId;

    my ($filter) = grep { $_->{id} eq $filterId } @{ $filters || [] };
    return [] unless $filter;

    my %blocked = map { lc($_) => 1 } @{ $blockList || [] };

    return [ grep { !$blocked{lc($_)} } @{ $filter->{genres} || [] } ];
}

# Resolves a player's chosen filter down to its artists list (added
# 20-09-2026) - the substrings TrackSelector.pm's filterArtists
# criterion should use. Unlike genres, there's no per-player quick-block
# equivalent for this (not asked for) - it's just the filter's own list,
# or [] if the filter id doesn't resolve to anything (none chosen, or
# deleted since).
#
# Same caller contract as resolveFilterGenres: an empty result here is
# NOT automatically "no constraint" once combined with genreGroup in
# MixRunner.pm's own has-a-filter check - see the design note there.
sub resolveFilterArtists {
    my ($filters, $filterId) = @_;

    return [] unless defined $filterId && length $filterId;

    my ($filter) = grep { $_->{id} eq $filterId } @{ $filters || [] };
    return [] unless $filter;

    return [ @{ $filter->{artists} || [] } ];
}

# Resolves a player's chosen filter down to its years list (added
# 25-09-2026) - the normalized "YYYY" / "YYYY-YYYY" entries
# TrackSelector.pm's yearRanges criterion should use. Same shape as
# resolveFilterArtists above (no per-player quick-block equivalent here
# either - Henk confirmed 25-09-2026 this stays filter-level only), just
# a different field. Unlike resolveFilterArtists though, an empty result
# here genuinely means "no year constraint" to TrackSelector.pm (years is
# a hard AND, not an OR-widener like filterArtists) - see the design
# notes on Settings/Basic.pm's `years` field and TrackSelector.pm's own
# criteria docs for the full reasoning.
sub resolveFilterYears {
    my ($filters, $filterId) = @_;

    return [] unless defined $filterId && length $filterId;

    my ($filter) = grep { $_->{id} eq $filterId } @{ $filters || [] };
    return [] unless $filter;

    return [ @{ $filter->{years} || [] } ];
}

1;

__END__
