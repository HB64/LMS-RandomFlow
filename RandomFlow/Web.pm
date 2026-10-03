package Plugins::RandomFlow::Web;

#
# Quickplay ("Start RandomFlow Mix" in the Extras menu) starts a mix,
# then renders live.html directly as the response - no splash page, no
# client-side redirect. Redirecting from a separate quickplay.html after
# a delay let Material Skin's own dialog/back-stack re-enter that page
# and start a second mix when navigating back from Per Player/Global
# settings. Rendering live.html straight away avoids the extra
# navigation entirely. quickplay.html itself is no longer used by either
# handler below, but is left in place.
#

use strict;
use warnings;

use Slim::Web::Pages;
use Slim::Web::HTTP;
use Slim::Player::Client;
use Slim::Utils::Log;

use Plugins::RandomFlow::MixRunner;

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.randomflow',
    'defaultLevel' => 'INFO',
});

my $urlBase   = 'plugins/RandomFlow/settings';
my $qpPath    = "$urlBase/quickplay.html";
my $livePath  = "$urlBase/live.html";

sub registerPages {
    # "browse" = Classic/Default skin's browse menu, "browseiPeng" =
    # Material Skin's own "Extras" menu. Both Quickplay and Live are
    # registered under the quickplay.html/live.html URLs (unchanged),
    # even though their menu labels now read "Start RandomFlow Mix" and
    # "RandomFlow" - see strings.txt.
    Slim::Web::Pages->addPageLinks('browse',      { 'PLUGIN_RANDOMFLOW_QUICKPLAY' => $qpPath });
    Slim::Web::Pages->addPageLinks('browseiPeng', { 'PLUGIN_RANDOMFLOW_QUICKPLAY' => $qpPath });
    Slim::Web::Pages->addPageLinks('browse',      { 'PLUGIN_RANDOMFLOW_LIVE' => $livePath });
    Slim::Web::Pages->addPageLinks('browseiPeng', { 'PLUGIN_RANDOMFLOW_LIVE' => $livePath });
    # The resize-on-request convention (append "_WxH" to this plain base
    # path; Lyrion's Slim::Web::Graphics::artworkRequest resolves it back
    # to the real file and resizes on the fly) matches SugarCube's own
    # mechanism. The path must use "HTML/images" (capital) to match the
    # actual deployed folder name - Debian's filesystem is case-sensitive,
    # so a lowercase "html/images" 404s, and a broken <img> then shows its
    # alt text overlapping the browse-menu label instead of the icon.
    # install.xml's <icon> uses the same capitalized path for the same
    # reason.
    #
    # 'icons' is registered for both QUICKPLAY and LIVE, both pointing at
    # the same randomflow_svg.png, matching SugarCube's pattern of
    # registering 'icons' for both its LV and QP entries rather than
    # leaving LIVE to fall back to a generic placeholder image.
    #
    # Material Skin's convention for an SVG icon is a "_svg.png" filename
    # suffix (not a "?svg=..." query param), which it auto-rewrites to
    # the matching .svg; randomflow.svg supplies the actual SVG Material
    # swaps in, while other skins just use the .png as-is.
    Slim::Web::Pages->addPageLinks('icons',       { 'PLUGIN_RANDOMFLOW_QUICKPLAY' => 'plugins/RandomFlow/HTML/images/randomflow_svg.png' });
    Slim::Web::Pages->addPageLinks('icons',       { 'PLUGIN_RANDOMFLOW_LIVE' => 'plugins/RandomFlow/HTML/images/randomflow_svg.png' });

    Slim::Web::Pages->addPageFunction($qpPath, \&handleWebQP);
    Slim::Web::HTTP::CSRF->protectURI($qpPath);

    Slim::Web::Pages->addPageFunction($livePath, \&handleWebLive);
    # No CSRF::protectURI here - handleWebLive itself has no side effect
    # (unlike handleWebQP, which starts a mix).
}

sub handleWebQP {
    my ($client, $params) = @_;

    $client = Slim::Player::Client::getClient($params->{player}) unless $client;

    if ($client) {
        $log->info("RandomFlow::Web: quickplay - starting mix for " . $client->name . ".");
        # startMix() already logs + shows its own on-player warning on
        # failure (no filter chosen, or no track found) - see
        # MixRunner.pm. Nothing further to check here.
        Plugins::RandomFlow::MixRunner::startMix($client);
    }

    return handleWebLive($client, $params);
}

sub handleWebLive {
    my ($client, $params) = @_;

    $client = Slim::Player::Client::getClient($params->{player}) unless $client;

    if (!$client) {
        $log->warn("RandomFlow::Web: live.html reached with no resolvable player (params->{player}='" . (defined $params->{player} ? $params->{player} : '') . "') - showing the page with nothing to connect to.");
        $params->{tstNoPlayer} = 1;
    } else {
        # $client->id is the player's own id (its MAC address, same as
        # every other player-targeted CLI/cometd request uses) - this is
        # what live.html's JS puts as the first element of the "request"
        # array it sends to /slim/subscribe, so the status push comes
        # back for THIS player and not whichever one happens to be
        # "current" server-side.
        $params->{tstPlayerId}   = $client->id;
        $params->{tstPlayerName} = $client->name;
    }

    return Slim::Web::HTTP::filltemplatefile($livePath, $params);
}

1;

__END__
