package Plugins::RandomFlow::Settings::Basic;

#
# GLOBAL (server-wide) settings for the TrackSelector engine.
#
# Two things live here:
#
#  1. playCountProvider - which play count/last-played source to use
#     (Lyrion / APC / both). Everything else criteria-wise is PER-PLAYER
#     - see Settings/Player.pm.
#
#  1b. historyLimit - how many ALREADY-PLAYED tracks a running mix keeps
#      in the queue before MixRunner.pm trims the oldest ones off the
#      front (added 20-09-2026, Henk - "voorkomt dat de wachtrij bij een
#      lange mix eindeloos doorgroeit"). Global, not per-player. Three
#      states, distinguished by Perl's own defined/length, not by
#      MixRunner.pm re-guessing intent:
#        - never saved (undef)   -> MixRunner.pm's own default (10)
#        - saved blank ('')      -> no limit at all (old, pre-this-
#                                    feature behaviour: queue just grows)
#        - saved as 0            -> no history at all - queue is always
#                                    exactly "now playing" + "up next"
#        - saved as N (>0)       -> keep the N most recent played tracks
#      See MixRunner.pm's _historyLimit()/_trimHistory() for where this
#      is actually applied - deleting old tracks via Lyrion's own
#      'playlist delete' command, confirmed safe against the real
#      slimserver source (Slim::Player::Playlist::removeTrack shifts the
#      playing index down rather than disturbing playback).
#
#  1c. historyDisplayCount - how many tracks the Live page's "History"
#      panel shows (added 25-09-2026, Henk). NOT the same setting as
#      historyLimit above - that one trims the running mix's own QUEUE;
#      this one only controls how many rows TrackSelector::
#      findRecentlyPlayed() reads back from Lyrion's own lastPlayed
#      tracking for display. Global, not per-player. Deliberately just
#      two states, not historyLimit's three - see the constants' own
#      comment in TrackSelector.pm for why "no limit" isn't offered
#      here at all:
#        - never saved / blank -> TrackSelector.pm's own default (20)
#        - saved as N          -> show the N most recently played
#                                  tracks (clamped server-side to
#                                  TrackSelector::MAX_HISTORY_DISPLAY_COUNT)
#
#  2. genreFilters - the named genre filters (like MusicIP's filters):
#     each is { id, name, genres, artists, years }. `artists` (added
#     20-09-2026, Henk) is a plain comma-separated text field, not a
#     checkbox list like genres - a track matching any of these artists
#     (partial, case-insensitive) is included regardless of genre; see
#     TrackSelector.pm's design notes for exactly how it combines with
#     genres. `years` (added 25-09-2026, Henk - a gap noticed while
#     discussing the Live page: this had been discussed before but never
#     actually built) is ALSO a plain comma-separated text field, but
#     behaves entirely differently from `artists`: each entry is either a
#     single year ("1985") or an inclusive range ("1980-1989"), and a
#     track must match at least one of the given entries - but unlike
#     `artists` (which WIDENS the genre match with an OR), a non-empty
#     `years` is a second, independent HARD AND requirement on top of the
#     genre/artists match (Henk confirmed 25-09-2026: "AND klinkt het
#     meest logisch"). Blank/empty means no year restriction at all, same
#     "absent = no constraint" convention every other criterion here
#     uses. Malformed entries (anything not a bare 4-digit year or a
#     4-digit-dash-4-digit range) are silently dropped at save time by
#     _parseYears() below, same tolerant approach _parseArtists() already
#     takes. See TrackSelector.pm's design notes for exactly how this
#     turns into SQL. Deliberately filter-level only, not also a
#     per-player quick-override like genreBlock - Henk confirmed
#     25-09-2026 he didn't want that, the full filter editor here is
#     always reachable from both the player settings page and the Live
#     page if a player needs something different. Managed here, chosen
#     per-player on the player settings page, and (later) switchable from
#     the Live page. `id` is a stable identifier assigned once at
#     creation (nextFilterId counter below) and never reused or
#     recomputed from the name, so renaming a filter never breaks a
#     player's reference to it (Henk confirmed 20-09-2026).
#
#     genreFilters is an array-type pref, so - same reasoning as the
#     array-type prefs in Settings/Player.pm - it's handled explicitly
#     in our own handler() below rather than left to the base class's
#     single-scalar-per-pref handler(), and deliberately excluded from
#     the list passed to SUPER::handler.
#
#     UI pattern: one row per existing filter, plus one permanently
#     blank trailing row for adding a new filter. Saving a blank name on
#     an existing row deletes that filter; saving a name on the
#     trailing row creates a new one. This avoids needing any
#     JS-driven "add another row" widget - the base Settings framework
#     is a plain full-page POST+reload, and this fits that model
#     directly.
#

use strict;
use warnings;

use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

use Plugins::RandomFlow::Settings::Util qw(allGenres);

my $prefs = preferences('plugin.randomflow');

sub name {
    return Slim::Web::HTTP::CSRF->protectName('PLUGIN_RANDOMFLOW_GLOBAL_SETTINGS');
}

sub page {
    return Slim::Web::HTTP::CSRF->protectURI('plugins/RandomFlow/settings/basic.html');
}

sub prefs {
    return ($prefs, qw(playCountProvider historyLimit historyDisplayCount));
}

sub handler {
    my ($class, $client, $paramRef) = @_;

    my $allGenres = allGenres();
    my $filters   = $prefs->get('genreFilters') || [];

    if ($paramRef->{'saveSettings'}) {
        my @updated;

        for my $filter (@$filters) {
            my $id      = $filter->{id};
            my $nameRaw = $paramRef->{"filter_name_$id"};
            next unless defined $nameRaw;

            my $name = $nameRaw;
            $name =~ s/^\s+|\s+$//g;
            next unless length $name;   # blank name = delete this filter

            my @genres;
            for my $i (0 .. $#$allGenres) {
                push @genres, $allGenres->[$i] if $paramRef->{"filter_genre_${id}_$i"};
            }

            my @artists = _parseArtists($paramRef->{"filter_artists_$id"});
            my @years   = _parseYears($paramRef->{"filter_years_$id"});

            push @updated, { id => $id, name => $name, genres => \@genres, artists => \@artists, years => \@years };
        }

        # The trailing blank "new filter" row - only becomes a real
        # filter if a name was actually typed into it.
        my $newNameRaw = $paramRef->{'filter_name_new'};
        if (defined $newNameRaw) {
            my $newName = $newNameRaw;
            $newName =~ s/^\s+|\s+$//g;

            if (length $newName) {
                my $nextId = $prefs->get('nextFilterId') || 1;

                my @genres;
                for my $i (0 .. $#$allGenres) {
                    push @genres, $allGenres->[$i] if $paramRef->{"filter_genre_new_$i"};
                }

                my @artists = _parseArtists($paramRef->{'filter_artists_new'});
                my @years   = _parseYears($paramRef->{'filter_years_new'});

                push @updated, { id => "f$nextId", name => $newName, genres => \@genres, artists => \@artists, years => \@years };
                $prefs->set('nextFilterId', $nextId + 1);
            }
        }

        $prefs->set('genreFilters', \@updated);
        $filters = \@updated;
    }

    # Always (re)build what the template needs, whether or not this was
    # a save - so a plain page load shows the currently stored filters.
    my @filterRows;
    for my $filter (@$filters) {
        push @filterRows, {
            id                  => $filter->{id},
            name                => $filter->{name},
            selectedGenreLookup => { map { $_ => 1 } @{ $filter->{genres} || [] } },
            artistsText         => join(', ', @{ $filter->{artists} || [] }),
            yearsText           => join(', ', @{ $filter->{years}   || [] }),
        };
    }
    push @filterRows, { id => 'new', name => '', selectedGenreLookup => {}, artistsText => '', yearsText => '' };

    $paramRef->{'filterRows'} = \@filterRows;
    $paramRef->{'allGenres'}  = $allGenres;

    return $class->SUPER::handler($client, $paramRef);
}

# Turns the comma-separated "Artists" text field into a clean list -
# trimmed, empties dropped. Deliberately plain text rather than a
# checkbox list like genres: the artist list isn't drawn from a known,
# bounded set the way genres are (Slim::Schema has no equivalent "all
# artists" picker here), and Henk explicitly wants it as free text.
sub _parseArtists {
    my ($raw) = @_;
    return () unless defined $raw && length $raw;

    return grep { length $_ } map {
        my $a = $_;
        $a =~ s/^\s+|\s+$//g;
        $a;
    } split /,/, $raw;
}

# Turns the comma-separated "Years" text field into a clean list of
# normalized entries - each either a bare 4-digit year ("1985") or a
# 4-digit-dash-4-digit inclusive range ("1980-1989"), whitespace around
# the dash allowed on input but not kept on output. A range given
# backwards (e.g. "1989-1980") is silently swapped into order. Anything
# else (blank, non-numeric, a 3-digit or 5-digit number, more than one
# dash, etc.) is silently dropped, same tolerant "just skip what doesn't
# parse" approach _parseArtists() takes above - see TrackSelector.pm's
# design notes for how the surviving entries turn into SQL.
sub _parseYears {
    my ($raw) = @_;
    return () unless defined $raw && length $raw;

    my @out;
    for my $entry (split /,/, $raw) {
        $entry =~ s/^\s+|\s+$//g;
        next unless length $entry;

        if ($entry =~ /^(\d{4})$/) {
            push @out, $1;
        }
        elsif ($entry =~ /^(\d{4})\s*-\s*(\d{4})$/) {
            my ($a, $b) = ($1, $2);
            ($a, $b) = ($b, $a) if $a > $b;
            push @out, "$a-$b";
        }
        # else: doesn't parse - dropped
    }

    return @out;
}

1;

__END__
