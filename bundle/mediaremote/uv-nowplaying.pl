use strict;
use warnings;
use DynaLoader;

# usage: perl uv-nowplaying.pl <path to libuvnowplaying.dylib>
# Reads lines on stdin: "get" prints the Now Playing state as one JSON line, "quit" or end of
# input exits. Runs under Apple's /usr/bin/perl, which MediaRemote still answers (see
# uv_nowplaying.c).
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
    if ($line eq "get") {
        &$get();
    } elsif ($line eq "quit") {
        last;
    }
}
