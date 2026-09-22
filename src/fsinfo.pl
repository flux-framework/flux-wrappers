#!/usr/bin/perl

use warnings;
use strict;

sub print_usage(){
    print "Usage: $0 [-R] [-h|--noheader] [-s|--summarize]\n";
    print " Display information about resource status.\n\n";
    print " Options:\n";
    print "  -R              display information about drained nodes\n";
    print "  -h|--noheader   do not print a header line\n";
    print "  -s|--summarize  display summary information\n";
    print "  -v|--verbose    show underlying flux command\n";
    exit 1;
}

sub print_warn($){
    my ($eargs) = @_;
    $eargs =~ s/^\s+//;
    print "Warning: $0 is a wrapper script and does not have all Slurm options implemented.\n";
    print "'$eargs' were ignored.\n";
    print "See '$0 --help' for supported options.\n\n";
}

sub categorize_state {
    my ($state) = @_;
    if( $state =~ /^(alloc|mix|comp|resv)$/ ){
        return 'A';
    }elsif( $state eq 'idle' ){
        return 'I';
    }else{
        return 'O';
    }
}

sub run_drain{
    #my ($h,$v) = @_;
    my %params = @_;
    open CMD, "flux resource drain |" or die "$0 couldn't run 'flux resource drain'.\n";
    if( $params{verbose} ){
        print "#running : flux resource drain"
    }
    if( $params{header} ){
        print "REASON               USER      TIMESTAMP           NODELIST\n";
    }
    <CMD>;
    while( <CMD> ){
        my @line = split;
        my $timestamp = shift @line;
        my $state = shift @line;
        my $rank = shift @line;
        my $nodelist = pop @line;
        my $reason = join( ' ', @line );
        printf( "%-20.20s %-9.9s %-19.19s %s\n", $reason, "root", $timestamp, $nodelist);
    }
    close CMD;
}

sub run_list{
    #my ($h,$v) = @_;
    my %params = @_;
    my %line = ();
    my %avail = ();
    my %timelimit = ();
    open CMD, "flux queue list -o '{queue} {limits.timelimit!H}' |" or die "$0 couldn't run 'flux queue list'.\n";
    if( $params{verbose} ){
        print "#running: flux queue list\n";
    }
    <CMD>;
    while( <CMD> ){
        my @line = split;
        $line[0] =~ s/\*//;
        if( $line[1] =~/^\d+$/ ){
            $line[1] = $line[1]."-00:00:00";
        }
        $timelimit{$line[0]} = $line[1];
    }
    close CMD;
    open CMD, "flux queue status |" or die "$0 couldn't run 'flux queue status'.\n";
    if( $params{verbose} ){
        print "# running: flux queue status\n";
    }
    my $submission = my $scheduling = "";
    while( <CMD> ){
        my $queue = "";
        /(\w+)\: Job submission is (\w+)/ and $queue = $1, $submission = $2;
        if( /(\w+)\: Scheduling is (\w+)/ and $queue = $1, $scheduling = $2 ){
            if( $submission eq "enabled" and $scheduling eq "started" ){
                $avail{$queue} = "up";
            }else{
                $avail{$queue} = "down";
            }
        }
    }
    close CMD;
    open CMD, "flux resource list -o '{queue} {nnodes} {state} {nodelist}'|" or die "$0 couldn't run 'flux resource list'.\n";
    if( $params{verbose} ){
        print "#running : flux resource list\n";
    }
    if( $params{header} ){
        if( $params{summarize} ){
            print "PARTITION AVAIL  TIMELIMIT   NODES(A/I/O/T) NODELIST\n";
        }else{
            print "PARTITION AVAIL  TIMELIMIT  NODES  STATE NODELIST\n";
        }
    }
    my %summary = ();
    <CMD>;
    while( <CMD> ){
        my( $queuestr, $nnodes, $state, $nodelist );
        if( /^\s+/ ){
            ( $nnodes, $state, $nodelist ) = split;
            $queuestr = 'default';
        }else{
            ( $queuestr, $nnodes, $state, $nodelist ) = split;
        }
        if( $state =~ /free/ ){
            $state = 'idle';
        }elsif( $state =~ /alloc/ ){
            $state = 'alloc';
        }
        if( $params{summarize} ){
            my $category = categorize_state( $state );
            foreach my $queue ( split /,/, $queuestr ){
                if( defined $avail{$queue} ){
                    $summary{$queue}{total_count} += $nnodes;
                    if( $category eq 'A' ){
                        $summary{$queue}{alloc_count} += $nnodes;
                    }elsif( $category eq 'I' ){
                        $summary{$queue}{idle_count} += $nnodes;
                    }elsif( $category eq 'O' ){
                        $summary{$queue}{other_count} += $nnodes;
                    }
                    push @{ $summary{$queue}{nodelists} }, $nodelist;
                }
            }
        }else{
            foreach my $queue ( split /,/, $queuestr ){
                if( defined $avail{$queue} ){
                    push @{ $line{$queue} }, sprintf( "%-10s %4s %10s   %4d %6.6s %s\n", $queue, $avail{$queue}, $timelimit{$queue}, $nnodes, $state, $nodelist );
                }
            }
        }
    }
    close CMD;
    if( $params{summarize} ){
        foreach my $q ( sort {$a cmp $b} keys %summary ){
            my $s = $summary{$q};
            my $alloc = $s->{alloc_count} || 0;
            my $idle = $s->{idle_count} || 0;
            my $other = $s->{other_count} || 0;
            my $total = $s->{total_count} || 0;
            my $nodelist = join(',', @{$s->{nodelists}});
            printf( "%-10s %4s %10s %6d/%d/%d/%d %s\n", $q, $avail{$q}, $timelimit{$q}, $alloc, $idle, $other, $total, $nodelist );
        }
    }else{
        foreach my $q ( sort {$a cmp $b} keys %line ){
            foreach my $l ( @{ $line{$q} } ){
                print "$l";
            }
        }
    }
}

### Main ####

my $drain = '';
my $header = 1;
my $verbose = 0;
my $summarize = 0;
my $extraargs = '';
foreach my $arg (@ARGV) {
    if( $arg eq '-R' ){
        $drain = "true";
    }elsif( $arg eq '-h' or $arg eq '--noheader' ){
        $header = 0;
    }elsif( $arg eq '-v' or $arg eq '--verbose' ){
        $verbose = 1;
    }elsif( $arg eq '-s' or $arg eq '--summarize' ){
        $summarize = 1;
    }elsif( $arg eq '--help' ){
        print_usage;
    }else{
        $extraargs = " ".$arg;
    }
}

if( $extraargs ){
    print_warn( $extraargs );
}

if( $drain ){
    run_drain(
        header => $header,
        verbose => $verbose);
}else{
    run_list(
        header => $header,
        verbose => $verbose,
        summarize => $summarize);
}
