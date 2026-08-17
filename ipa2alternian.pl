#!/usr/bin/env perl
# Usage:  ./ipa2alternian.pl 'ˈkɑːɹkæt'
#         ./ipa2alternian.pl --verbose 'stɹɛŋθ'
#         echo 'ˈvɹɪskə' | ./ipa2alternian.pl
#         ./ipa2alternian.pl            # interactive prompt
#
use strict;
use warnings;
use utf8;
use open qw(:std :encoding(UTF-8));
use Unicode::Normalize qw(NFD NFC);
use Encode qw(decode_utf8);
use Getopt::Long qw(:config bundling no_auto_abbrev);

our $VERSION = '1.0';

#############################################################################
# 1. THE TARGET SYSTEM 
#############################################################################

# Alternian phoneme -> canonical romanization.
# Internally /ɡ/ is written 'g' to avoid U+0261 / U+0067 confusion.
my %SPELL = (
    # vowels
    'a'  => 'a',   'aː' => 'aa',  'æ'  => 'ae',  'ɒ'  => 'ao',
    'e'  => 'e',   'ɛ'  => 'ea',  'ɔ'  => 'eo',  'ɔː' => 'eoo',
    'i'  => 'i',   'iː' => 'ii',  'o'  => 'o',   'u'  => 'u',
    'ɪ'  => 'y',
    # consonants
    'p'  => 'p',   't'  => 't',   'd'  => 'd',   'k'  => 'c',   'g'  => 'g',
    'm'  => 'm',   'n'  => 'n',   'r'  => 'r',   'rː' => 'rr',
    'f'  => 'f',   'v'  => 'v',   's'  => 's',   'z'  => 'z',
    'ʃ'  => 'x',   'h'  => 'h',   'l'  => 'l',
);

# Phonemes that have more than one legal letter.
my %POLY = ( 'k' => '(c/k/q)', 'v' => '(b/v)' );

# For pretty-printing internal phonemes as real IPA.
my %AS_IPA = ( 'g' => 'ɡ' );

my %IS_VOWEL = map { $_ => 1 } qw(a aː æ ɒ e ɛ ɔ ɔː i iː o u ɪ);

# Letters -> phoneme, for re-reading a spelling (used to detect ambiguity).
my %LETTER = (
    a=>'a', b=>'v', c=>'k', d=>'d', e=>'e', f=>'f', g=>'g', h=>'h', i=>'i',
    j=>'',  k=>'k', l=>'l', m=>'m', n=>'n', o=>'o', p=>'p', q=>'k', r=>'r',
    s=>'s', t=>'t', u=>'u', v=>'v', w=>'',  x=>'ʃ', y=>'ɪ', z=>'z',
);
# Multigraphs, longest first (greedy reading).
my @MULTIGRAPH = (
    ['eoo','ɔː'], ['aa','aː'], ['ae','æ'], ['ao','ɒ'],
    ['ea','ɛ'],   ['eo','ɔ'],  ['ii','iː'], ['rr','rː'],
);

# Vowel harmony (rounding). Counterparts pair by height/length where possible.
my %ROUNDED     = map { $_ => 1 } qw(u o ɔ ɔː ɒ);
my %TO_UNROUNDED = ( 'u'=>'i', 'o'=>'e', 'ɔ'=>'ɛ', 'ɔː'=>'aː', 'ɒ'=>'a' );
my %TO_ROUNDED   = ( 'i'=>'u', 'iː'=>'u', 'ɪ'=>'u', 'e'=>'o',
                     'ɛ'=>'ɔ', 'æ'=>'ɒ',  'a'=>'ɒ', 'aː'=>'ɔː' );

# The four attested diphthongs are ai, eɪ, ou, ia. A coerced vowel sequence
# that is one offglide away from one of them is snapped onto it.
my @DIPHTHONG_SNAP = (
    [ { 'a' => 1, 'aː' => 1 }, 'ɪ', 'i' ],   # a + /ɪ/ -> ai
    [ { 'e' => 1 },            'i', 'ɪ' ],   # e + /i/ -> ey
);

# Alternian vowels as feature vectors: height(0..60), backness(0..20),
# rounded(0/1), long(0/1).  Order matters: ties resolve to the earlier entry,
# so unrounded (Terezi's harmonic set) wins a coin flip.
my @ALT_VOWELS = (
    ['i',   0, 0,0,0], ['iː',  0, 0,0,1], ['ɪ',  10, 5,0,0],
    ['e',  20, 0,0,0], ['ɛ',  40, 0,0,0], ['æ',  50, 0,0,0],
    ['a',  60, 0,0,0], ['aː', 60, 0,0,1],
    ['u',   0,20,1,0], ['o',  20,20,1,0], ['ɔ',  40,20,1,0],
    ['ɔː', 40,20,1,1], ['ɒ',  60,20,1,0],
);

#############################################################################
# 2. THE SOURCE SYSTEM  (all of IPA)
#############################################################################

# Every IPA vowel letter -> height, backness, rounding.
my %VOWEL = (
    'i'=>[ 0, 0,0], 'y'=>[ 0, 0,1], 'ɨ'=>[ 0,10,0], 'ʉ'=>[ 0,10,1],
    'ɯ'=>[ 0,20,0], 'u'=>[ 0,20,1],
    'ɪ'=>[10, 5,0], 'ʏ'=>[10, 5,1], 'ʊ'=>[10,15,1], 'ᵻ'=>[10,10,0],
    'ᵿ'=>[10,10,1],
    'e'=>[20, 0,0], 'ø'=>[20, 0,1], 'ɘ'=>[20,10,0], 'ɵ'=>[20,10,1],
    'ɤ'=>[20,20,0], 'o'=>[20,20,1],
    'ə'=>[30,10,0], 'ɚ'=>[30,10,0],
    'ɛ'=>[40, 0,0], 'œ'=>[40, 0,1], 'ɜ'=>[40,10,0], 'ɝ'=>[40,10,0],
    'ɞ'=>[40,10,1], 'ʌ'=>[40,20,0], 'ɔ'=>[40,20,1],
    'æ'=>[50, 0,0], 'ɐ'=>[50,10,0],
    'a'=>[60, 0,0], 'ɶ'=>[60, 0,1], 'ɑ'=>[60,20,0], 'ɒ'=>[60,20,1],
);
# Vowels that carry an inherent /r/ (rhotacised).
my %RHOTIC_VOWEL = ( 'ɚ'=>1, 'ɝ'=>1 );

# Every IPA consonant letter -> nearest Alternian consonant.
my %CONS = (
    # plosives
    'p'=>'p', 'b'=>'v', 't'=>'t', 'd'=>'d', 'ʈ'=>'t', 'ɖ'=>'d',
    'c'=>'k', 'ɟ'=>'g', 'k'=>'k', 'g'=>'g', 'ɡ'=>'g', 'q'=>'k',
    'ɢ'=>'g', 'ʔ'=>'h',
    # nasals
    'm'=>'m', 'ɱ'=>'m', 'n'=>'n', 'ɳ'=>'n', 'ɲ'=>'n', 'ŋ'=>'n', 'ɴ'=>'n',
    # trills, taps, flaps
    'ʙ'=>'r', 'r'=>'r', 'ʀ'=>'r', 'ɾ'=>'r', 'ɽ'=>'r', 'ⱱ'=>'v', 'ɺ'=>'l',
    # fricatives
    'ɸ'=>'f', 'β'=>'v', 'f'=>'f', 'v'=>'v', 'θ'=>'s', 'ð'=>'z',
    's'=>'s', 'z'=>'z', 'ʃ'=>'ʃ', 'ʒ'=>'ʃ', 'ʂ'=>'ʃ', 'ʐ'=>'ʃ',
    'ɕ'=>'ʃ', 'ʑ'=>'ʃ', 'ç'=>'ʃ', 'ʝ'=>'ʃ', 'ɧ'=>'ʃ',
    'x'=>'h', 'ɣ'=>'g', 'χ'=>'h', 'ʁ'=>'r', 'ħ'=>'h', 'ʕ'=>'h',
    'h'=>'h', 'ɦ'=>'h', 'ʜ'=>'h', 'ʢ'=>'h', 'ʡ'=>'h',
    # laterals
    'ɬ'=>'l', 'ɮ'=>'l', 'l'=>'l', 'ɭ'=>'l', 'ʎ'=>'l', 'ʟ'=>'l', 'ɫ'=>'l',
    # approximants
    'ʋ'=>'v', 'ɹ'=>'r', 'ɻ'=>'r', 'ɰ'=>'g', 'ʍ'=>'f',
    # implosives / ejective stops
    'ɓ'=>'v', 'ɗ'=>'d', 'ʄ'=>'g', 'ɠ'=>'g', 'ʛ'=>'g',
    # clicks
    'ʘ'=>'p', 'ǀ'=>'t', 'ǃ'=>'k', 'ǂ'=>'k', 'ǁ'=>'l',
);

# Modifier letters that bind to the preceding segment.
my %MODIFIER = map { $_ => 1 } (
    'ː', 'ˑ', ':', 'ʰ', 'ʱ', 'ʲ', 'ʷ', 'ʸ', 'ʳ', 'ʴ', 'ˠ', 'ˤ', 'ˀ', 'ˁ',
    'ʼ', '˞', 'ⁿ', 'ˡ', 'ᵊ', 'ᵐ', 'ᵑ', 'ᶿ', 'ˢ',
);
# Punctuation / prosody we simply drop.
my %IGNORE = map { $_ => 1 } (
    'ˈ', 'ˌ', "'", '"', '`', '.', ',', ';', '|', '‖', '‿', '/', '[', ']',
    '(', ')', '⟨', '⟩', '-', '‑', '–', '—', '_', '=', '!', '?', '˥', '˦',
    '˧', '˨', '˩', '↗', '↘', '↑', '↓', '↑', '¯', '‾',
);

#############################################################################
# 3. OPTIONS
#############################################################################

@ARGV = map { decode_utf8($_) } @ARGV;

my %opt = (
    harmony    => 'auto',
    epenthesis => 'ɪ',
    w          => 'v',
    case       => 'lower',
    plain      => 0,
    verbose    => 0,
);
GetOptions(
    'p|plain'        => \$opt{plain},
    'v|verbose'      => \$opt{verbose},
    'y|harmony=s'    => \$opt{harmony},
    'r|rounded'      => sub { $opt{harmony} = 'rounded'   },
    'u|unrounded'    => sub { $opt{harmony} = 'unrounded' },
    'H|no-harmony'   => sub { $opt{harmony} = 'off'       },
    'e|epenthesis=s' => \$opt{epenthesis},
    'w|w-as=s'       => \$opt{w},
    'c|case=s'       => \$opt{case},
    'd|demo'         => \$opt{demo},
    'h|help'         => sub { usage(); exit 0 },
    'version'        => sub { print "ipa2alternian $VERSION\n"; exit 0 },
) or do { usage(); exit 2 };

$opt{harmony} = lc $opt{harmony};
$opt{harmony} = 'rounded'   if $opt{harmony} eq 'round';
$opt{harmony} = 'unrounded' if $opt{harmony} eq 'unround' or $opt{harmony} eq 'flat';
$opt{harmony} = 'off'       if $opt{harmony} =~ /^(none|no|n)$/;
usage_die("--harmony must be auto, rounded, unrounded or off")
    unless $opt{harmony} =~ /^(auto|rounded|unrounded|off)$/;

$opt{w} = ($opt{w} =~ /^u/i) ? 'u' : 'v';
$opt{case} = lc $opt{case};
usage_die("--case must be lower, upper or mixed")
    unless $opt{case} =~ /^(lower|upper|mixed)$/;

# --epenthesis accepts either a phoneme (ɪ, u) or a letter (y, u)
{
    my $e = $opt{epenthesis};
    unless ($IS_VOWEL{$e}) {
        my @p = parse_spelling(lc $e);
        usage_die("--epenthesis: '$e' is not an Alternian vowel")
            unless @p == 1 && $IS_VOWEL{$p[0]};
        $opt{epenthesis} = $p[0];
    }
}

#############################################################################
# 4. MAIN
#############################################################################

if ($opt{demo}) { run_demo(); exit 0 }

if (@ARGV) {
    report($_) for @ARGV;
}
elsif (-t STDIN) {
    print "IPA to Alternian.  Enter an IPA word (blank line or ^D to quit).\n";
    while (1) {
        print "IPA> ";
        my $line = <STDIN>;
        last unless defined $line;
        chomp $line;
        last if $line =~ /^\s*(q|quit|exit)?\s*$/i;
        report($line);
    }
}
else {
    while (my $line = <STDIN>) {
        chomp $line;
        next unless $line =~ /\S/;
        report($line);
    }
}
exit 0;

#############################################################################
# 5. PIPELINE
#############################################################################

# Split an IPA string into segments, coerce each to an Alternian phoneme.
sub coerce_segments {
    my ($text) = @_;
    my (@seg, @out);                  # @seg = source IPA, @out = phonemes

    my @ch = split //, NFD($text);
    my $i = 0;
    while ($i < @ch) {
        my $base = $ch[$i++];
        next if $base =~ /\p{M}/;     # orphaned diacritic
        next if $IGNORE{$base};
        next if $base =~ /\s/;

        # gather combining marks + modifier letters belonging to this segment
        my @marks;
        while ($i < @ch and ($ch[$i] =~ /\p{M}/ or $MODIFIER{$ch[$i]})) {
            push @marks, $ch[$i++];
        }

        # recompose things like c + cedilla -> ç
        my $comb = join '', grep { /\p{M}/ } @marks;
        if (length $comb) {
            my $comp = NFC($base . $comb);
            if (length($comp) == 1 and ($CONS{$comp} or $VOWEL{$comp})) {
                $base  = $comp;
                @marks = grep { !/\p{M}/ } @marks;
            }
        }

        $base = '@' eq $base ? 'ə' : $base;
        $base = lc $base if !$CONS{$base} && !$VOWEL{$base} && $base =~ /\p{L}/;

        my $long     = grep { $_ eq 'ː' or $_ eq 'ˑ' or $_ eq ':' } @marks;
        my $nasal    = grep { $_ eq "\x{0303}" } @marks;            # ◌̃
        my $syllabic = grep { $_ eq "\x{0329}" or $_ eq "\x{030D}" } @marks;
        my $rcolour  = grep { $_ eq '˞' } @marks;
        my $nrelease = grep { $_ eq 'ⁿ' } @marks;
        my $lrelease = grep { $_ eq 'ˡ' } @marks;

        my @add;                       # phonemes this segment produces
        if ($base eq 'j') {                       # no /j/: becomes /i/
            @add = ('i');
        }
        elsif ($base eq 'w' or $base eq 'ɥ') {    # no /w/ (README, note 3)
            @add = ($opt{w});
        }
        elsif (exists $VOWEL{$base}) {
            my ($h, $b, $r) = @{ $VOWEL{$base} };
            @add = (nearest_vowel($h, $b, $r, $long ? 1 : 0));
            push @add, 'r' if $RHOTIC_VOWEL{$base};
        }
        elsif (exists $CONS{$base}) {
            my $c = $CONS{$base};
            $c .= 'ː' if $long and $c eq 'r';      # only /rː/ is writable
            unshift @add, $opt{epenthesis} if $syllabic;
            push @add, $c;
        }
        else {
            next;                                  # unknown symbol: skip
        }

        push @add, 'n' if $nasal   and exists $VOWEL{$base};
        push @add, 'r' if $rcolour and !$RHOTIC_VOWEL{$base};
        push @add, 'n' if $nrelease;
        push @add, 'l' if $lrelease;

        push @seg, $base . join('', @marks);
        push @out, @add;
    }
    return (\@seg, \@out);
}

# Nearest Alternian vowel by feature distance. Rounding is weighted heavily
# because rounding is the axis vowel harmony runs on.
sub nearest_vowel {
    my ($h, $b, $r, $long) = @_;
    my ($best, $score);
    for my $v (@ALT_VOWELS) {
        my ($p, $vh, $vb, $vr, $vl) = @$v;
        my $d = abs($h - $vh) + abs($b - $vb)
              + 20 * abs($r - $vr) + 5 * ($long == $vl ? 0 : 1);
        if (!defined $score or $d < $score) { ($score, $best) = ($d, $p) }
    }
    return $best;
}

# Collapse identical neighbours: VV -> Vː where a long vowel exists,
# CC -> Cː for /r/ only, otherwise just drop the duplicate.
sub degeminate {
    my ($ph, $notes) = @_;
    my @out;
    for my $p (@$ph) {
        if (@out and $out[-1] eq $p) {
            if (exists $SPELL{ $p . 'ː' }) {
                $out[-1] = $p . 'ː';
                push @$notes, "/$p$p/ -> /$p" . "ː/";
            }
            else {
                push @$notes, "degeminated /$p$p/ -> /$p/";
            }
            next;
        }
        push @out, $p;
    }
    return @out;
}

# Enforce (C)(C)V(ː)(V)(C(ː))(C) by inserting epenthetic vowels.
sub fix_structure {
    my ($ph, $notes) = @_;
    my @in = @$ph;
    return () unless @in;

    unless (grep { $IS_VOWEL{$_} } @in) {
        push @in, $opt{epenthesis};
        push @$notes, "no vowel: added /$opt{epenthesis}/";
    }

    my @out;
    my $i = 0;
    while ($i < @in) {
        if ($IS_VOWEL{ $in[$i] }) { push @out, $in[$i++]; next }
        my $at_start = ($i == 0);
        my @run;
        push @run, $in[$i++] while $i < @in and !$IS_VOWEL{ $in[$i] };
        my $left  = $at_start        ? 0 : 2;   # coda slots available
        my $right = ($i < @in)       ? 2 : 0;   # onset slots available
        push @out, break_cluster(\@run, $left, $right, $notes);
    }
    return @out;
}

sub break_cluster {
    my ($run, $left, $right, $notes) = @_;
    my @r = @$run;
    my @out;
    while (@r > $left + $right) {
        my $take = $left > 0 ? $left : (@r % 2 ? 1 : 2);
        push @out, splice(@r, 0, $take), $opt{epenthesis};
        push @$notes, "epenthetic /$opt{epenthesis}/ breaks a cluster";
        $left = 2;
    }
    push @out, @r;
    return @out;
}

# Rounding harmony, triggered by the first (= stressed) vowel of the word.
sub harmonise {
    my ($ph, $class) = @_;
    my $map = $class eq 'rounded' ? \%TO_ROUNDED : \%TO_UNROUNDED;
    return map { $IS_VOWEL{$_} ? ($map->{$_} // $_) : $_ } @$ph;
}

sub snap_diphthongs {
    my ($ph) = @_;
    my @p = @$ph;
    for my $i (1 .. $#p) {
        next unless $IS_VOWEL{ $p[$i] } and $IS_VOWEL{ $p[$i-1] };
        for my $s (@DIPHTHONG_SNAP) {
            next unless $s->[0]{ $p[$i-1] } and $p[$i] eq $s->[1];
            $p[$i] = $s->[2];
            last;
        }
    }
    return @p;
}

# Spell a phoneme list. Inserts the silent letter j where two spellings would
# otherwise fuse into a digraph (e.g. /e/+/a/ would read back as /ɛ/).
sub spell {
    my ($ph) = @_;
    my (@canon, @disp, @so_far);
    for my $p (@$ph) {
        my $c = $SPELL{$p};
        next unless defined $c;
        push @so_far, $p;
        push @canon, $c;
        push @disp, ($POLY{$p} // $c);
        for my $filler ('j', 'w') {
            last if list_eq([ parse_spelling(join '', @canon) ], \@so_far);
            splice @canon, -1, 0, $filler;
            splice @disp,  -1, 0, $filler;
        }
    }
    return (join('', @canon), join('', @disp));
}

# Read a romanized string back into phonemes (greedy longest match).
sub parse_spelling {
    my ($s) = @_;
    my @out;
  CHAR: while (length $s) {
        for my $m (@MULTIGRAPH) {
            if (index($s, $m->[0]) == 0) {
                push @out, $m->[1];
                substr($s, 0, length $m->[0], '');
                next CHAR;
            }
        }
        my $ch = substr($s, 0, 1, '');
        my $p  = $LETTER{$ch};
        push @out, $p if defined $p and $p ne '';
    }
    return @out;
}

# Rough syllabification, for display only.
sub syllabify {
    my (@ph) = @_;
    my (@syl, @cur, $seen_nucleus, $nvowels);
    for (my $i = 0; $i < @ph; $i++) {
        my $p = $ph[$i];
        if ($IS_VOWEL{$p}) {
            if ($seen_nucleus and $nvowels >= 2) {
                push @syl, [@cur]; @cur = (); $nvowels = 0;
            }
            push @cur, $p;
            $seen_nucleus = 1;
            $nvowels++;
            next;
        }
        # consonant: how many follow before the next vowel?
        my $j = $i;
        $j++ while $j < @ph and !$IS_VOWEL{ $ph[$j] };
        my $run = $j - $i;
        my $more = ($j < @ph);
        if ($seen_nucleus) {
            my $onset = $more ? ($run > 2 ? 2 : $run) : 0;
            my $coda  = $run - $onset;
            push @cur, @ph[ $i .. $i + $coda - 1 ] if $coda > 0;
            push @syl, [@cur]; @cur = (); $seen_nucleus = 0; $nvowels = 0;
            push @cur, @ph[ $i + $coda .. $j - 1 ] if $onset > 0;
        }
        else {
            push @cur, @ph[ $i .. $j - 1 ];
        }
        $i = $j - 1;
    }
    push @syl, [@cur] if @cur;
    return join '.', map { join '', map { ipa($_) } @$_ } @syl;
}

sub transliterate {
    my ($word) = @_;
    my @notes;
    my ($seg, $ph) = coerce_segments($word);
    return undef unless @$ph;

    my @p = degeminate($ph, \@notes);

    my ($first) = grep { $IS_VOWEL{$_} } @p;
    my $auto  = (defined $first and $ROUNDED{$first}) ? 'rounded' : 'unrounded';
    my $class = ($opt{harmony} eq 'auto' or $opt{harmony} eq 'off')
              ? $auto : $opt{harmony};
    my $why   = $opt{harmony} eq 'off'  ? 'not applied (--harmony off)'
              : $opt{harmony} eq 'auto' ? 'set by the stressed first vowel'
              : 'forced by --harmony';

    @p = fix_structure(\@p, \@notes);
    if ($opt{harmony} ne 'off') {
        push @notes, "harmony forced to $class" if $opt{harmony} ne 'auto'
                                                and $class ne $auto;
        @p = harmonise(\@p, $class);
    }
    @p = degeminate(\@p, \@notes);
    @p = snap_diphthongs(\@p);

    my ($canon, $disp) = spell(\@p);
    $canon = recase($canon);
    $disp  = recase($disp);

    return {
        segments  => $seg,
        coerced   => $ph,
        phonemes  => \@p,
        class     => $class,
        class_why => $why,
        syllables => scalar syllabify(@p),
        plain     => $canon,
        display   => $disp,
        variants  => scalar(grep { $POLY{$_} } @p),
        notes     => \@notes,
    };
}

#############################################################################
# 6. OUTPUT
#############################################################################

sub report {
    my ($line) = @_;
    my @words = grep { /\S/ } split /\s+/, $line;
    my @res   = grep { defined } map { transliterate($_) } @words;
    unless (@res) { print "(nothing transliterable)\n"; return }

    if ($opt{plain}) {
        print join(' ', map { $_->{plain} } @res), "\n";
        return;
    }
    if (!$opt{verbose}) {
        printf "%s  ->  %s   [%s]\n", $line,
            join(' ', map { $_->{display} } @res),
            join(' ', map { $_->{plain}   } @res);
        return;
    }
    for my $r (@res) {
        my $n = 1;
        $n *= 3 for grep { $_ eq 'k' } @{ $r->{phonemes} };
        $n *= 2 for grep { $_ eq 'v' } @{ $r->{phonemes} };
        print  "  IPA in      : ", join(' ', @{ $r->{segments} }), "\n";
        print  "  coerced     : ", join(' ', map { ipa($_) } @{ $r->{coerced} }), "\n";
        print  "  harmony     : $r->{class} ($r->{class_why})\n";
        print  "  repaired    : ", join(' ', map { ipa($_) } @{ $r->{phonemes} }), "\n";
        print  "  syllables   : $r->{syllables}\n";
        print  "  Alternian   : $r->{display}\n";
        print  "  one spelling: $r->{plain}";
        print  "   (of $n possible)" if $n > 1;
        print  "\n";
        print  "  notes       : $_\n" for @{ $r->{notes} };
        print  "\n";
    }
}

sub recase {
    my ($s) = @_;
    return uc $s if $opt{case} eq 'upper';
    return $s    if $opt{case} eq 'lower';
    my ($up, $depth, $out) = (0, 0, '');          # EiThEr CaSe
    for my $ch (split //, $s) {
        $depth++ if $ch eq '(';
        $depth-- if $ch eq ')';
        # letters inside (c/k/q) are left alone
        if (!$depth and $ch ne ')' and $ch =~ /\p{L}/) {
            $up ^= 1;
            $ch = $up ? uc $ch : lc $ch;
        }
        $out .= $ch;
    }
    return $out;
}

sub ipa      { my $p = shift; return $AS_IPA{$p} // $p }
sub list_eq  {
    my ($a, $b) = @_;
    return 0 unless @$a == @$b;
    $a->[$_] eq $b->[$_] or return 0 for 0 .. $#$a;
    return 1;
}
sub usage_die { print STDERR "ipa2alternian: $_[0]\n"; exit 2 }

sub run_demo {
    my @d = (
        ['ˈkɑːɹkæt',      'Karkat'],
        ['ˈvɹɪskə',       'Vriska'],
        ['ˈtɛɹəzi',       'Terezi'],
        ['ɛˈɹiːdæn',      'Eridan'],
        ['ˈstɹɛŋθ',       'English "strength" - 3-consonant onset'],
        ['ˈbjuːtɪfəl',    'English "beautiful" - /j/ becomes /i/'],
        ['ˈwɔːtəɹ',       'English "water" - /w/ and rounded harmony'],
        ['t͡ʃɜːt͡ʃ',        'English "church" - affricates'],
        ['ˈtoːkʲoː',      'Tokyo'],
        ['bɔ̃ʒuʁ',         'French "bonjour" - nasal vowel'],
        ['ˈʃtʁaːsə',      'German "Straße"'],
        ['n̩ˈdɛlɛ',        'syllabic nasal'],
    );
    for my $d (@d) {
        my $r = transliterate($d->[0]);
        printf "  %-14s %-22s %-26s %s\n",
            $d->[0], $r->{display}, "[$r->{plain}]", $d->[1];
    }
}

sub usage {
    print <<"END";
ipa2alternian $VERSION - IPA to Alternian romanization

USAGE
  ipa2alternian.pl [options] 'IPA' ['IPA' ...]
  ipa2alternian.pl [options] < wordlist
  ipa2alternian.pl                       (interactive)

OPTIONS
  -v, --verbose        show the whole derivation
  -p, --plain          print only one concrete spelling, no (c/k/q) brackets
  -y, --harmony H      which harmonic set the word is coerced into:
                         auto      (default) whichever set the first vowel is in
                         rounded   force the rounded set  (u o eo eoo ao)
                         unrounded force the unrounded set (i ii y e ea ae a aa)
                         off       no harmony; leave each vowel as coerced
  -r, --rounded        short for --harmony rounded
  -u, --unrounded      short for --harmony unrounded
  -H, --no-harmony     short for --harmony off
  -e, --epenthesis V   vowel used to break illegal clusters (default y = /ɪ/;
                       it is still subject to harmony, so it surfaces as u in
                       a rounded word)
  -w, --w-as v|u       what /w/ becomes (default v; u gives a diphthong)
  -c, --case C         lower (default), upper, or mixed (EiThEr CaSe)
  -d, --demo           transliterate a set of example words
  -h, --help           this text

HOW IT WORKS
  1. The IPA is segmented; stress marks, tone marks and most diacritics are
     dropped. Length (: or the length mark), nasalization, syllabicity and
     rhoticity are kept.
  2. Every segment is coerced to its nearest Alternian phoneme. Vowels use
     feature distance (height, backness, rounding, length) with rounding
     weighted heavily, since rounding is what harmony runs on. Consonants use
     a fixed table covering the whole IPA chart, e.g.
        b bʱ ɓ β ʋ -> v      θ -> s        ð -> z       ʒ ʂ ç ɕ -> x
        ŋ ɲ ɳ ɴ    -> n      x χ ʔ ħ -> h  ɣ -> g       ɹ ɾ ʁ ʀ -> r
        j -> /i/            w ɥ -> /v/ (Alternian has no /w/ - README note 3)
     Affricates fall out as clusters: t͡ʃ -> tx, d͡ʒ -> dx, t͡s -> ts.
  3. Doubled segments collapse: VV -> a long vowel where one exists, and
     rr -> /rː/. Other geminates simplify.
  4. Syllable structure (C)(C)V(:)(V)(C(:))(C) is enforced by inserting an
     epenthetic vowel wherever a consonant cluster is too big.
  5. Rounding harmony is applied across the word, triggered by the first
     vowel, because stress is word-initial. This is also what fixes foreign
     diphthongs: /aʊ/ has an unrounded first element, so the /u/ unrounds
     and you get the attested /ai/. Use --harmony to pick the set yourself
     instead: the pairings are i/ii/y-u, e-o, ea-eo, ae/a-ao, aa-eoo.
  6. Vowel sequences one offglide away from an attested diphthong snap onto
     it: /aɪ/ -> ai, /ei/ -> ey.
  7. The result is spelled. Where a spelling boundary would create an
     accidental digraph (e.g. /e/+/a/ reading back as "ea" = /ɛ/), the silent
     letter j is inserted, which is what the silent letters are for.

OUTPUT
  Sounds with several possible letters are shown as alternatives:
     /k/ -> (c/k/q)      /v/ -> (b/v)
  The bracketed form is the real answer; the form in [square brackets] is one
  arbitrary concrete spelling of it.

EXAMPLES
  \$ ipa2alternian.pl 'ˈkɑːɹkæt' 'paɪɹoʊp'
  ˈkɑːɹkæt paɪɹoʊp  ->  (c/k/q)aar(c/k/q)aet paireyp   [caarcaet paireyp]

  \$ ipa2alternian.pl --rounded 'ˈkɑːɹkæt'
  ˈkɑːɹkæt  ->  (c/k/q)eoor(c/k/q)aot   [ceoorcaot]

  \$ ipa2alternian.pl --verbose 'ˈstɹɛŋθ'
  \$ ipa2alternian.pl --demo
END
}
