#!/usr/bin/env perl
# Relocates a conda prefix extracted by rules_mise.
#
# Usage: perl conda_relocate.pl <conda-prefix-dir> <outer-dir> <stable-prefix>
#
# <outer-dir> contains one subdirectory per package, each with
# `info/has_prefix` listing (placeholder, mode, path) triples in conda's
# format. Every placeholder is replaced with <stable-prefix> in the files
# under <conda-prefix-dir>:
# - text files: plain string replacement (size may change).
# - binary files: conda's null-padded replacement, which matches each
#   null-terminated string containing the placeholder, swaps the placeholder
#   for the shorter stable prefix, and pads with nulls after the terminator
#   so the file size and all subsequent offsets stay identical.
#
# The stable prefix is a short deterministic path (e.g. /tmp/mise_conda_123).
# At tool runtime the wrapper symlinks it to the real CONDA_PREFIX, so the
# patched binaries resolve their baked-in absolute paths (notably postgres'
# --with-system-tzdata .../share/zoneinfo) without copying the prefix.
use strict;
use warnings;

binmode STDOUT, ":utf8";

my ($fs_root, $outer_root, $stable) = @ARGV;
die "usage: $0 <conda-prefix-dir> <outer-dir> <stable-prefix>\n"
  unless defined $fs_root && defined $outer_root && defined $stable;

my @manifests = glob("$outer_root/*/info/has_prefix");
my @entries;
my %placeholders;

for my $mf (@manifests) {
    open(my $fh, "<", $mf) or die "cannot open $mf: $!\n";
    binmode $fh;
    while (my $line = <$fh>) {
        chomp $line;
        $line =~ s/\r$//;
        next if $line =~ /^\s*$/;
        my ($placeholder, $mode, $path);
        my @parts = split(/ /, $line, 3);
        if (@parts == 3) {
            ($placeholder, $mode, $path) = @parts;
        } elsif (@parts == 1) {
            # Legacy single-field format: path only, default placeholder.
            $placeholder = "/opt/anaconda1anaconda2anaconda3";
            $mode = "text";
            $path = $parts[0];
        } else {
            die "cannot parse has_prefix line in $mf: $line\n";
        }
        # Strip surrounding quotes (Windows format, unsupported but harmless).
        for ($placeholder, $path) {
            if (/^"(.*)"$/) { $_ = $1; }
        }
        die "unknown mode '$mode' in $mf: $line\n"
          unless $mode eq "text" || $mode eq "binary";
        push @entries, {
            placeholder => $placeholder,
            mode => $mode,
            path => $path,
        };
        $placeholders{$placeholder} = 1;
    }
    close($fh);
}

if (!@entries) {
    print "conda_relocate: no has_prefix entries, nothing to patch\n";
    exit 0;
}

# The stable prefix must fit inside every binary placeholder (padding with
# nulls keeps the file size). Text entries could be longer, but all
# conda-forge placeholders are ~255 chars, far longer than our ~24 char
# stable prefix, so require it uniformly for a clear error otherwise.
for my $ph (keys %placeholders) {
    if (length($stable) > length($ph)) {
        die sprintf(
            "conda_relocate: stable prefix '%s' (%d) longer than placeholder '%s...' (%d)\n",
            $stable, length($stable), substr($ph, 0, 40), length($ph));
    }
}

my $patched = 0;
my $files = 0;
for my $e (@entries) {
    my $rel = $e->{path};
    my $file = "$fs_root/$rel";
    next if -l $file;  # symlink: target is patched via its own entry if needed
    unless (-f $file) {
        warn "conda_relocate: skipping missing file $rel\n";
        next;
    }
    open(my $fh, "<", $file) or die "cannot open $file: $!\n";
    binmode $fh;
    my $data = do { local $/; <$fh> };
    close($fh);
    my $orig = $data;
    if ($e->{mode} eq "text") {
        my $q = quotemeta($e->{placeholder});
        $data =~ s/$q/$stable/g;
    } else {
        $data = binary_replace($data, $e->{placeholder}, $stable);
    }
    next if $data eq $orig;
    open(my $out, ">", $file) or die "cannot write $file: $!\n";
    binmode $out;
    print $out $data;
    close($out);
    $patched++;
    $files++;
}

print "conda_relocate: patched $patched file(s) to $stable\n";
exit 0;

sub binary_replace {
    my ($data, $search, $repl) = @_;
    my $q = quotemeta($search);
    $data =~ s{$q([^\0]*?)\0}{
        my $body = $1;
        my $full = $search . $body;
        my $cnt = () = $full =~ /$q/g;
        (my $new_full = $full) =~ s/$q/$repl/g;
        my $pad = (length($search) - length($repl)) * $cnt;
        die "stable prefix longer than placeholder\n" if $pad < 0;
        $new_full . ("\0" x $pad) . "\0";
    }ge;
    return $data;
}
