#!/usr/bin/perl -w

use strict;
use warnings;

use Getopt::Long;
use List::Util qw(min max);
use XML::SAX;

my %opt = ();
GetOptions(
    'help'                  => sub { usage() },
    'speed=f'               => \$opt{speed},
    'scale=f'               => \$opt{scale},
    'center=s'              => \$opt{center},
) or usage(1);

use constant X => 0;
use constant Y => 1;

{
    my $file = $ARGV[0] or usage(1);
    die "Input file does not exist\n" if !-e $file;
    
    my $output_file = $file;
    $output_file =~ s/\.svg/.gcode/i;
    
    my $parser = XML::SAX::ParserFactory->parser(
        Handler => (my $handler = Plott3r::SVGParser->new),
    );
    $parser->parse_uri($file);
    
    open my $fh, '>', $output_file or die "Failed to open output file $output_file\n";
    print  $fh "G21 ; set units to millimeters\n";
    print  $fh "G90 ; use absolute coordinates\n";
    printf $fh "G1 F%d\n", $opt{speed} * 60 if $opt{speed};
    
    my @paths = ([]);
    foreach my $path (@{ $handler->{_paths} }) {
        $path =~ s/[Mz]//g;
        while ($path =~ s/^\s*(\d+(?:\.\d+))\s+(\d+(?:\.\d+))//) {
            push @{$paths[-1]}, [$1, $2];
        }
    }
    
    if ($opt{scale} && $opt{scale} != 1) {
        $_->[X] *= $opt{scale} for map @$_, @paths;
        $_->[Y] *= $opt{scale} for map @$_, @paths;
    }
    
    my $min_x = min(map $_->[X], map @$_, @paths);
    my $max_x = max(map $_->[X], map @$_, @paths);
    my $min_y = min(map $_->[Y], map @$_, @paths);
    my $max_y = max(map $_->[Y], map @$_, @paths);
    
    # reverse Y
    $_->[Y] = $min_y + ($max_y - $_->[Y]) for map @$_, @paths;
    
    if ($opt{center}) {
        my $center = [ split /[x,]/, $opt{center} ];
        my @shift = (
            -$min_x -($max_x - $min_x)/2 + $center->[X],
            -$min_y -($max_y - $min_y)/2 + $center->[Y],
        );
        $_->[X] += $shift[X] for map @$_, @paths;
        $_->[Y] += $shift[Y] for map @$_, @paths;
        $min_x += $shift[X];
        $max_x += $shift[X];
        $min_y += $shift[Y];
        $max_y += $shift[Y];
    }
    
    printf "Print spans from X = %s to X = %s and from Y = %s to Y = %s\n",
        $min_x, $max_x, $min_y, $max_y;
    printf "  (total size: %s, %s)\n", ($max_x - $min_x), ($max_y - $min_y);
    
    foreach my $path (@paths) {
        printf $fh "G1 X%.4f Y%.4f\n", @$_ for @$path;
    }
    
    close $fh;
}

sub usage {
    my ($exit_code) = @_;
    
    print <<"EOF";
plott3r is a SVG-to-GCODE translator
written by Alessandro Ranellucci <alessandro\@unterwelt.it> - http://slic3r.org/

Usage: plott3r.pl [ OPTIONS ] file.svg

    --help              Output this usage screen and exit
    --speed SPEED       Speed in mm/s (default: none)
    --scale FACTOR      Scale factor (default: 1)
    --center X,Y        Point to center print around (default: none)

EOF
    exit ($exit_code || 0);
}

package Plott3r::SVGParser;
use base qw(XML::SAX::Base);

sub new {
    my $self = shift->SUPER::new(@_);
    $self->{_paths} = [];
    $self;
}

sub start_element {
    my ($self, $el) = @_;
    if ($el->{LocalName} eq 'path') {
        push @{$self->{_paths}}, $el->{Attributes}{'{}d'}{Value};
    }
}

__END__
