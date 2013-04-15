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
    
    my $POINT_RE = qr/(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)/;
    
    my @paths = ();
    foreach my $d (@{ $handler->{_paths} }) {
        my $path = [];
        my $last_pos = [0,0];  # If a relative moveto (m) appears as the first element of the path, then it is treated as a pair of absolute coordinates.
        
        # enforce a space after commands
        $d =~ s/([a-z])([0-9-])/$1 $2/gi;
        
        my @tokens = split /\s+/, $d;
        while (defined (my $token = shift @tokens)) {
            if ($token eq 'M' || $token eq 'm') {  # moveto
                my $point = [ split /,/, shift @tokens ];
                if ($token eq 'm') {
                    $point->[$_] += $last_pos->[$_] for X,Y;
                }
                push @$path, $point;
                $last_pos = $point;
                if (@tokens && $tokens[0] =~ /^$POINT_RE$/) {
                    # If a moveto is followed by multiple pairs of coordinates, the subsequent pairs are treated as implicit lineto commands.
                    unshift @tokens, $token eq 'M' ? 'L' : 'l';
                }
            } elsif ($token eq 'Z' || $token eq 'z') {  # closepath
                push @$path, $path->[0];
                $last_pos = $paths[-2][0];
            } elsif ($token eq 'L' || $token eq 'l') {  # lineto
                while (@tokens && $tokens[0] =~ /^$POINT_RE$/) {
                    my $point = [ split /,/, shift @tokens ];
                    if ($token eq 'l') {
                        $point->[$_] += $last_pos->[$_] for X,Y;
                    }
                    push @$path, $point;
                    $last_pos = $point;
                }
            } elsif ($token =~ /[CcSs]/) {  # curveto
                my @points = ();
                push @points, shift @tokens while @tokens && $tokens[0] =~ /^$POINT_RE$/;
                die "Invalid arguments for $token command in $d\n" if @points % 3 != 0;
                @points = map $points[3*$_-1], 1 .. @points / 3;
                foreach my $point (map [ split /,/ ], @points) {
                    if ($token =~ /[cs]/) {
                        $point->[$_] += $last_pos->[$_] for X,Y;
                    }
                    push @$path, $point;
                    $last_pos = $point;
                }
            } else {
                die "Unimplemented path command $token in $d\n";
            }
        }
        push @paths, $path;
#            use XXX; XXX $d, $path;
    }
    die "Unable to parse the input file\n" if !map @$_, @paths;
    
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
        next if !@$path;
        print  $fh "\n";
        print  $fh "G0 Z90.0 ; pen up\n";
        printf $fh "G1 X%.4f Y%.4f\n", @$_ for shift @$path;
        print  $fh "G1 Z10.0 ; pen down\n";
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
