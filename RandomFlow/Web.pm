package Plugins::RandomFlow::Web;

#
# Quickplay ("Start RandomFlow Mix" in the Extras menu) starts a mix,
# then renders live.html directly as the response - no splash page, no
# client-side redirect (Henk, 26-09-2026). Used to redirect from a
# separate quickplay.html after a delay, which caused Material Skin's
# own dialog/back-stack to sometimes re-enter that page and start a
# second mix when navigating back from Per Player/Global settings.
# Rendering live.html straight away avoids the extra navigation
# entirely. quickplay.html itself is no longer used by either handler
# below, but is left in place.
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
    # Henk, 24-09-2026: the resize-on-request convention itself (append "_WxH" to this plain
    # base path, Lyrion's Slim::Web::Graphics::artworkRequest resolves it back to our one real
    # file and resizes on the fly) is correct and matches SugarCube's own working mechanism - see
    # the full reasoning in the 26-09-2026 fix note below.
    #
    # Henk, 26-09-2026: pending confirmation above turned out to be the real bug, and it explained
    # the garbled/double-text "Snel afspelen" browse-menu entry Henk reported in Default skin -
    # a broken <img> shows its alt text overlapping the menu label, which is exactly what that
    # garbling was. Root cause: this base path used a lowercase "html/images" segment, but the
    # actual deployed images folder on Henk's server is "HTML/images" (capital) - confirmed by
    # Henk both by finding a 404 on the "_25x25" resize URL (SugarCube's equivalent URL, same
    # convention, loaded fine) and by checking the real folder name on disk. Debian's filesystem
    # is case-sensitive, so the mismatched case 404'd outright. This is unrelated to the separate
    # lowercase-"html/EN" skin-template question from earlier - this is specifically our own
    # plugin's images subfolder, which SugarCube itself has always spelled "HTML/images"
    # (capital) - we're now matching that same convention, and the local HTML/EN/plugins/
    # RandomFlow/ tree was renamed from html/images to HTML/images to match, so a fresh
    # install from this source tree deploys with the casing this path now expects. See
    # install.xml's <icon> - same fix applied there.
    #
    # Henk, 26-09-2026: this 'icons' registration only ever existed for QUICKPLAY - LIVE never
    # had one, so its browse-menu row fell back to a generic placeholder image (Henk spotted this
    # once Quickplay's own icon started rendering correctly and the contrast became obvious).
    # SugarCube registers 'icons' for BOTH its LV and QP entries, pointing at the same one
    # sugarcube.png - matching that pattern here rather than inventing a separate icon for LIVE.
    # Henk, 27-09-2026: the "?svg=RandomFlow" attempt was wrong - Material's
    # real convention (per Craig Drummond) is a "_svg.png" filename suffix,
    # which it auto-rewrites to the matching .svg. Image renamed to
    # randomflow_svg.png (see install.xml too); randomflow.svg supplies the
    # actual SVG Material swaps in. Other skins just use the .png as-is.
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
