use strict;
use warnings;
use DynaLoader;

# usage: perl uv-nowplaying.pl <absolute path to libuvnowplaying.dylib>
# Reads lines on stdin: "get <n>" prints "seq=<n> " and then the Now Playing state as one JSON
# line, so a late answer to an earlier request can never be mistaken for the current one.
# "quit" or end of input exits. Runs under Apple's /usr/bin/perl, which MediaRemote still
# answers (see uv_nowplaying.c).
$| = 1;
my $library = shift or die "usage: uv-nowplaying.pl <library>\n";
my $handle = DynaLoader::dl_load_file($library, 0)
    or die "load failed: " . DynaLoader::dl_error() . "\n";
my $symbol = DynaLoader::dl_find_symbol($handle, "uv_nowplaying_get")
    or die "symbol not found\n";
my $get = DynaLoader::dl_install_xsub("main::uv_nowplaying_get", $symbol);

print "{\"ready\":1}\n";
while (my $line = <STDIN>) {
    $line =~ s/\s+$//;
    if ($line =~ /^get (\d+)$/) {
        print "seq=$1 ";
        &$get();
    } elsif ($line eq "quit") {
        last;
    }
}
