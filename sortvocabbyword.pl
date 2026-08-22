#!/usr/bin/perl
# Sort VOCABULARY.csv in place alphabetically by word
use strict;
use warnings;
use Text::CSV;
use File::Temp qw(tempfile);
use File::Copy qw(move);

my $file = shift // 'VOCABULARY.csv';

my $csv = Text::CSV->new({ binary => 1, auto_diag => 2, eol => "\r\n", quote_space => 0, quote_binary => 0 });

open my $in, '<:encoding(UTF-8)', $file or die "$0: cannot read $file: $!\n";
my $header = $csv->getline($in) or die "$0: $file is empty\n";
my @rows;
while (my $row = $csv->getline($in)) {
    next unless grep { defined && length } @$row;    # skip blank lines
    push @rows, $row;
}
close $in;

@rows = sort { lc($a->[0] // q()) cmp lc($b->[0] // q()) } @rows;

my ($fh, $tmp) = tempfile("$file.XXXXXX");
binmode $fh, ':encoding(UTF-8)';
$csv->print($fh, $header);
$csv->print($fh, $_) for @rows;
close $fh or die "$0: cannot write $tmp: $!\n";
chmod 0644 & ~umask(), $tmp;
move($tmp, $file) or die "$0: cannot replace $file: $!\n";
