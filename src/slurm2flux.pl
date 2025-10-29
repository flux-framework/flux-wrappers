#! /usr/bin/perl

# Written by Philip D. Eckert <eckert2@llnl.gov> and Ryan Day <day36@llnl.gov>

use Getopt::Long 2.24 qw(:config no_ignore_case no_auto_abbrev);
use List::Util qw(min);
use strict;

	
#
# Define all possible Slurm options, whether Flux supports them or not.
#
my (
$account_opt, $acct_freq_opt, $ail_type_opt, $alps_opt, $attach_opt, $batch_opt, $begin_opt, $blrts_imnage_opt, $chdir_opt, $checkpoint_opt, $checkpoint_dir_opt, $cnloab_image_opt, $comment_opt, $constraint_opt, $cores_opt, $cores_per_socket_opt, $corespec_opt, $cpu_bind_opt, $cpus_per_task_opt, $debugger_test_opt, $debugger_test_opt, $dependent_opt, $disable_status_opt, $distribution_opt, $error_opt, $exact_opt, $exclude_opt, $exclusive_opt, $export_opt, $flux_debug_opt, $geometry_opt, $get_user_env_opt, $gid_val, $gpu_bind_opt, $gpus_per_node_opt, $gpus_per_task_opt, $gres_opt, $hint_opt, $hold_opt, $hugepages_opt, $immediate_opt, $input_opt, $ioload_images_opt, $jobname_opt, $jobid_opt, $join_opt, $kill_on_bad_exit_opt, $label_opt, $licenses_opt, $linux_image_opt, $mail_exit_opt, $mail_launch_time_opt, $mail_user_opt, $mem_bind_opt, $mem_opt, $mem_per_cpu_opt, $mincores_opt, $mincpus_opt, $minsockets_opt, $minthreads_opt, $mloaver_image_opt, $mpi_opt, $mpibind_opt, $msg_timeout_opt, $multi_prog_opt, $network_opt, $nice_opt, $no_allocate_opt, $no_kill_opt, $no_rotate_opt, $no_shell_opt, $nodelist_opt, $nodes_opt, $ntasks_opt, $ntasks_per_core_opt, $ntasks_per_node_opt, $ntasks_per_socket_opt, $open_mode_opt, $outoput_opt, $output_opt, $overcommit_opt, $partition_opt, $preserve_opt, $priority_opt, $prolog_opt, $propagate_opt, $pty_opt, $qos_opt, $quiet_on_ibnterupt_opt, $quiet_opt, $ramdisk_image_opt, $reboot_opt, $relative_opt, $reservation_opt, $restarert_dir_opt, $resv_ports_opt, $share_opt, $signal_opt, $sockets_per_node_opt, $task_epilog_opt, $task_prolog_opt, $tasks_per_node_opt, $test_only_opt, $tghreads_per_core_opt, $thp_opt, $threads_opt, $time_min_opt, $time_opt, $tmp_opt, $uid_opt, $unbuffered_opt, $usage_opt, $verbose_opt, $version_opt, $vextra_node_al, $wait_opt, $wckey_opt, $wrap_opt, $help_opt
); 

my (@lreslist, @SlurmScriptOptions);
my ($commandLine, $scriptFile, $scriptArgs, $tempFile, $command, $flag);
my @OPTIONS = ();
my $outshebang = '';
my $outtext = '';

#
# Save off ARGV so we can override the script directives if needed later (sbatch)
#
my @SAVEDARGV = @ARGV;

GetOpts(@ARGV);
foreach my $ii ( 0 .. $#ARGV ){
    if( $ARGV[$ii] =~ /[\;\s]/ ){
        if( $ARGV[$ii] =~ /\"/ ){
            $ARGV[$ii] = "\'$ARGV[$ii]\'";
        }else{
            $ARGV[$ii] = "\"$ARGV[$ii]\"";
        }
    }
}
$commandLine = "@ARGV";
usage() if ($help_opt);

my $hasMpibind = checkForMpibind();

my $fluxversion = getFluxVer();
my $fluxlevel = `/bin/flux getattr instance-level`;

my $fluxcmd = 'flux';
my $fluxpcmd = 'flux --parent';
if( $fluxversion < 0.48 ){
    $fluxcmd = 'flux mini';
    $fluxpcmd = 'flux --parent mini';
}

#
# If we're running in batch mode (sbatch) we need to parse the script for #SBATCH stuff.
# Otherwise, we just can just pass the rest on to flux.
#
if( ( $0 =~ /sbatch$/ and !$wrap_opt ) or ( $0 =~ /slurm2flux/ and -e $ARGV[0] and -f _ and -T _ ) ){
    # At this point the only thing left on ARGV should be the script and
    # script arguments (if any).
    if (@ARGV) {
        if( $0 =~ /sbatch$/ ){
   	        $scriptFile = shift;
        }else{
            $scriptFile = $ARGV[0];
        }
        open FDIN, "< $scriptFile" or die "Unable to open $scriptFile for reading: $!\n";
	    $scriptArgs = join ' ', @ARGV if @ARGV;
    }
    # Otherwise read the job command file from STDIN and create a temporary file using
    # the process id as part of the name (for uniqueness).
    else {
        open FDIN, "< &STDIN";
   	    $tempFile = "/tmp/jobScript.flux.$$";
  	    open FDOUT, "> $tempFile"
    	    or die( "Unable to open temporary job script file ($tempFile) for writing: $!\n"
        );
    }

    # Check job script
    my $firstline = <FDIN>;
    if( $firstline =~ /^#!/ ){
        $outshebang = $firstline;
    }else{
        $outshebang = "#!/bin/sh\n";
        $outtext .= $firstline;
    }
    foreach my $line (<FDIN>) {
        if( $0 =~ /slurm2flux/ and $line =~s/^\s*srun\s+// ){
            my $s2fline = `$0 $line`;
            $s2fline =~ s/\[run\|alloc\|batch\]/run/;
            $outtext .= $s2fline;
        }else{
            $outtext .= $line;
            if ($line =~ /^\s*#\s*SBATCH\s+/) {
	            chomp $line;
	            $line =~ s/^\s*#\s*SBATCH\s+//; # Remove #SBATCH from line.
	            $line =~ s/#.*//;               # Remove comments
	            $line =~ s/\s+$//;              # Remove trailing whitespace
	            my @args = split /\s+/, $line;
	            foreach my $arg (@args) {
	                push @SlurmScriptOptions, @args;
	            }
	        }
        }
    }
    close FDIN;
    if( $tempFile ){
        print FDOUT $outshebang;
        print FDOUT $outtext;
    }
    close FDOUT;
    
    # Check script options.
    GetOpts(@SlurmScriptOptions) 
	    or die("Invalid SLURM options found in job script file.\n");
    # Check command line arguments (overriding script directives if any)
    GetOpts(@SAVEDARGV);
}

#
# Translate options
#

if ($account_opt) {
    push @OPTIONS, "--setattr=bank=$account_opt ";
}

if ($begin_opt) {
    push @OPTIONS, "--begin-time=".processBegin($begin_opt)." ";
}

if ($comment_opt) {
	push @OPTIONS, "--setattr=user.comment='$comment_opt' ";
}

if ($cores_opt) {
    push @OPTIONS, "--cores=$cores_opt ";
}

if ($ntasks_per_core_opt and 
    ($cores_opt or ($cores_per_socket_opt and $sockets_per_node_opt and $nodes_opt)) and 
    !$cpus_per_task_opt and !$ntasks_opt
    ) {
    push @OPTIONS, "--tasks-per-core=$ntasks_per_core_opt ";
}

if ($cores_per_socket_opt and $sockets_per_node_opt and $nodes_opt){
    push @OPTIONS, "--cores=".$cores_per_socket_opt*$sockets_per_node_opt*$nodes_opt." ";
    $nodes_opt = '';
}

if ($cpu_bind_opt) {
    if ($cpu_bind_opt eq 'none' or $cpu_bind_opt eq 'no') {
        push @OPTIONS, "--setopt=cpu-affinity=off";
    }elsif( $cpu_bind_opt =~ s/^map_cpu\:// or $cpu_bind_opt =~ s/^mask_cpu\:// ){
        $cpu_bind_opt =~ s/\,/\;/g;
        push @OPTIONS, "--setopt=cpu-affinity=map:\"$cpu_bind_opt\"";
    }else{
        print "Warning: --cpu-bind=$cpu_bind_opt is not implemented in this wrapper and is being ignored.\n";
        $cpu_bind_opt = '';
    }
}

if ($cpus_per_task_opt) {
    push @OPTIONS, "-c $cpus_per_task_opt ";
}

if ($chdir_opt) {
    push @OPTIONS, "--setattr=system.cwd=$chdir_opt ";
}

if ($error_opt) {
    $error_opt =~ s/\%j/\{\{id\}\}/g;
    $error_opt =~ s/\%x/\{\{name\}\}/g;
	push @OPTIONS, "--error=$error_opt ";
}

if ($dependent_opt) {
    push @OPTIONS, processDepend($dependent_opt);
}

if ($export_opt) {
    push @OPTIONS, processExport($export_opt);
}

if ($flux_debug_opt) {
	push @OPTIONS, "--debug ";
}

#if ( !$exact_opt and !$cpus_per_task_opt and !$gpus_per_task_opt and 
#     !$ntasks_per_core_opt and !$ntasks_per_node_opt and
#     $0 =~ /srun$/ ){
#    push @OPTIONS, "--exclusive ";
#}

if ($exclusive_opt) {
    if( !$cpus_per_task_opt and !$gpus_per_task_opt and $fluxlevel > 0 ){
        push @OPTIONS, "--exclusive ";
    }
}

if ($input_opt) {
    push @OPTIONS, "--input=$input_opt ";
}

if ($gpu_bind_opt and ($gpu_bind_opt eq 'none' or $gpu_bind_opt eq 'no')) {
    push @OPTIONS, "--setopt=gpu-affinity=off ";
}

if ($gpus_per_node_opt and !$gpus_per_task_opt) {
    push @OPTIONS, "--gpus-per-node=".processGpuNode($gpus_per_node_opt)." ";
}

if ($gpus_per_task_opt) {
    push @OPTIONS, "-g $gpus_per_task_opt ";
}

if ($help_opt) {
	usage();
}

if ($hugepages_opt) {
    if( -e "/etc/flux/system/prolog-job-manager.d/hugepages.sh" ){
        push @OPTIONS, "--setattr=hugepages=$hugepages_opt ";
    }else{
        print STDERR "Warning: hugepages prolog is not present. Ignoring --hugepages flag.\n";
    }
}

if ($jobname_opt) {
    push @OPTIONS, "--job-name=$jobname_opt ";
}

if ($label_opt) {
    push @OPTIONS, "--label-io ";
}

if ($mem_bind_opt and $mem_bind_opt ne 'none') {
    print STDERR "Warning: --mem-bind options other than 'none' are not supported. Ignoring '--mem-bind=$mem_bind_opt'.\n";
}

if ($mpi_opt) {
    if( $mpi_opt eq 'none' ){
        push @OPTIONS, "-o mpi=$mpi_opt ";
    }
}

if ($mpibind_opt and ($0 =~ /srun$/ or $0 =~ /slurm2flux$/)) {
    if( $mpibind_opt eq 'off' ){
        unless( $cpu_bind_opt ){
            push @OPTIONS, "--setopt=cpu-affinity=per-task ";
        }
        unless( $gpu_bind_opt and ($gpu_bind_opt eq 'none' or $gpu_bind_opt eq 'no') ){
            push @OPTIONS, "--setopt=gpu-affinity=per-task ";
        }
    }
    if( $hasMpibind ){
        push @OPTIONS, processMpibind($mpibind_opt);
    }else{
        print "Warning: mpibind not found. Ignoring --mpibind flag.\n";
    }
}

if ($corespec_opt and ($0 =~ /srun$/ or $0 =~ /slurm2flux$/)) {
    if( $hasMpibind ){
        push @OPTIONS, "-o mpibind=corespec_first:$corespec_opt ";
    }else{
        print "Warning mpibind not found. Ignoring --core-spec flag.\n";
    }
}

if ($ntasks_opt) {
	push @OPTIONS, "-n $ntasks_opt ";
}

if ($ntasks_per_node_opt and $nodes_opt and !$cpus_per_task_opt and !$ntasks_opt) {
    if( $0 =~ /srun$/ ){
        push @OPTIONS, "--tasks-per-node=$ntasks_per_node_opt ";
    }elsif ( $nodes_opt ){
        my $temp_tasks = $ntasks_per_node_opt * $nodes_opt;
        push @OPTIONS, "-n $temp_tasks ";
    }
}

if ($nodes_opt) {
	push @OPTIONS, "--nodes=$nodes_opt ";
}

if ($no_shell_opt and $0 =~ /salloc$/) {
    push @OPTIONS, "--bg ";
}

if ($output_opt) {
    $output_opt =~ s/\%j/\{\{id\}\}/g;
    $output_opt =~ s/\%x/\{\{name\}\}/g;
	push @OPTIONS, "--output=$output_opt ";
}

if ($partition_opt) {
    push @OPTIONS, "--queue=$partition_opt ";
}

if ($priority_opt=~/^\d+$/) {
	push @OPTIONS, "--urgency=$priority_opt ";
}

if ($pty_opt) {
    push @OPTIONS, "-o pty.interactive ";
}

if ($time_opt) {
	my $time = timeToSeconds($time_opt);
	push @OPTIONS, "--time-limit=$time ";
}

if ($hold_opt) {
    push @OPTIONS, "--urgency=0 ";
}


if ($thp_opt) {
    if( -e "/etc/flux/system/prolog-job-manager.d/thp.sh" ){
        push @OPTIONS, "--setattr=thp=$thp_opt ";
    }else{
        print STDERR "Warning: thp prolog is not present. Ignoring --thp flag.\n";
    }
}

if ($unbuffered_opt and $0 =~ /srun$/) {
    push @OPTIONS, "--unbuffered -o pty.interactive ";
}

if ($verbose_opt and $0 !~ /sbatch$/) {
	push @OPTIONS, "--verbose ";
}

if ($wrap_opt) {
    push @OPTIONS, "--wrap $wrap_opt";
}

if ($no_allocate_opt) {
	push @OPTIONS, "--dry-run ";
}

#
# decide what flux command to run based on the Slurm command and run it
#
my $exit_status=0;
if( $0 =~ /salloc$/ ){
    if( $verbose_opt ) {
        print "# running: $fluxpcmd alloc @OPTIONS $commandLine\n";
    }
	$exit_status = system("$fluxpcmd alloc @OPTIONS $commandLine");
}elsif( $0 =~ /sbatch$/ ){
	if ($scriptFile || $tempFile) {
	    if ($scriptFile) {
	    	$command = $scriptFile;
	    } else {
    		$command = $tempFile;
    	}
    	$command .= " $scriptArgs" if ($scriptArgs);
    }
    if( $verbose_opt ) {
        print "# running: $fluxpcmd batch @OPTIONS $command\n";
    }
    if( $wait_opt ){
        if( $output_opt and $error_opt ){
    	    $exit_status = system("$fluxpcmd alloc @OPTIONS \"$command 1> $output_opt 2> $error_opt\"");
        }elsif( $output_opt ){
    	    $exit_status = system("$fluxpcmd alloc @OPTIONS \"$command >& $output_opt\"");
        }elsif( $error_opt ){
    	    $exit_status = system("$fluxpcmd alloc @OPTIONS \"$command 2> $error_opt\"");
        }else{
    	    $exit_status = system("$fluxpcmd alloc @OPTIONS $command");
        }
    }else{
    	$exit_status = system("$fluxpcmd batch @OPTIONS $command");
    }
}else{
    if( !$cpus_per_task_opt and !$gpus_per_task_opt and
        !$ntasks_per_core_opt and !$ntasks_per_node_opt ){
        if( $fluxlevel > 0 ){
            push @OPTIONS, "--exclusive ";
        }
        if( !$nodes_opt ){
            if( $jobid_opt ){   # flux proxy job
                $nodes_opt = `flux jobs -n -o '{nnodes}' $jobid_opt`;
                chomp $nodes_opt;
            }elsif( $ENV{"FLUX_JOB_NNODES"} ){   # in a flux job (run,submit)
                $nodes_opt = $ENV{"FLUX_JOB_NNODES"};
            }elsif( $ENV{"FLUX_URI"} ){    # in a flux instance (alloc,batch)
                $nodes_opt = `flux resource list -n -o '{nnodes}'`;
                chomp $nodes_opt;
            }else{   # outside of a flux job
                $nodes_opt = "";
            }
            unless( $ntasks_opt ){
                $ntasks_opt = $nodes_opt;
            }
            if( $nodes_opt ){
                $nodes_opt = min($ntasks_opt, $nodes_opt);
                push @OPTIONS, "--nodes=$nodes_opt ";
            }
        }
    }
    if( $0 =~ /srun$/ ){
        if( $jobid_opt ) {
            if( $verbose_opt ) {
                print "# running: flux proxy $jobid_opt $fluxcmd run @OPTIONS $commandLine\n";
            }
            $exit_status = exec("flux proxy $jobid_opt $fluxcmd run @OPTIONS $commandLine");
        }else{
            if( $verbose_opt ) {
                print "# running: $fluxcmd run @OPTIONS $commandLine\n";
            }
	        $exit_status = exec("$fluxcmd run @OPTIONS $commandLine");
        }
    }else{
        if( $jobid_opt ){
            printf("flux proxy $jobid_opt $fluxcmd [run|alloc|batch] @OPTIONS $commandLine\n");
        }else{
            if( $outtext and $fluxversion >= 0.48 ){
                printFluxScript();
            }else{
                printf("$fluxcmd [run|alloc|batch] @OPTIONS $commandLine\n");
            }
        }
    }
}
$exit_status = $exit_status >> 8;
exit $exit_status;

### helper functions ###

#
# print out a job script that will work with flux batch
#
sub printFluxScript
{
    print $outshebang;
    print "### Flux directives ###\n";
    foreach my $fluxopt (@OPTIONS){
        print "#flux: $fluxopt\n";
    }
    print "\n";
    print "### Original script. ###\n";
    print "### #SBATCH directives are preserved but will be ignored by Flux.\n";
    print "### 'srun' commands are converted to 'flux run'.\n";
    print "### Other Slurm commands are not converted.\n";
    print $outtext;
}

#
# check to see if Flux system instance is using mpibind.
# there's probably a smarter / more general way to do this.
#
sub checkForMpibind
{
    if( -e "/etc/flux/shell/lua.d/mpibind.lua" ){
        return 1;
    }else{
        return 0;
    }
}

#
# check Flux version to determine which interface to use
#
sub getFluxVer
{
    my $version = `flux --version | grep commands`;
    $version =~ /commands:\s+(\d+\.\d+)/ and return $1;
    return 1;
}

#
# translate Slurm begin datetime to Flux datetime
# most of them just work, but the YYYY-MM-DD[THH:MM[:SS] format
# needs a bit of massaging
#
sub processBegin
{
    my ($datetime) = @_;
    $datetime =~ s/(\d+)T(\d+)/$1 $2/;
    return "'".$datetime."'";
}

#
# translate Slurm time format (days-hours:minutes:seconds) to seconds
#
sub timeToSeconds
{
	my ($duration) = @_;
	$duration = 0 unless $duration;
	my $seconds = 0;

	$duration = "366:00:00:00" if ($duration =~ /UNLIMITED/);

	my @req = split /:|-/, $duration;
	if ($duration =~ /^(\d+)$/) {
	        $seconds = $duration*60;
	} else {
	        my $inc;
	        $seconds = pop(@req);
	        $seconds += (60 * $inc) if ($inc = pop(@req));
	        $seconds += (60*60 * $inc) if ($inc = pop(@req));
	        $seconds += (24*60*60 * $inc) if ($inc = pop(@req));
	}

    # Time must be at least 1 minute (60 seconds)
	$seconds = 60 if $seconds < 60;
	$seconds .= "s";

	return $seconds;
}

#
# translate Slurm dependency to Flux dependency
#
sub processDepend
{
    my ($dependstr) = @_;
    my $retstr = '';
    if( $dependstr =~ /\:/ ){
        my @depends = split /\:/, $dependstr;
        my $condition = shift @depends;
        if( $condition eq 'after' or
            $condition eq 'afterany' or
            $condition eq 'afterok' or 
            $condition eq 'afternotok' or
            $condition eq 'afterexcept'
            ){
            foreach my $jobid (@depends){
                $retstr .= "--dependency=$condition:$jobid ";
            }
        }
    }else{
        $retstr = "--dependency=afterany:$dependstr ";
    }
    return $retstr;
}

#
# translate Slurm export to Flux env
#
sub processExport
{
    my ($exportstr) = @_;
    my $envstr = '';
    if( lc($exportstr) eq 'none' ){
        $envstr = '--env-remove=* ';
    }else{
        my @exportargs = split /,/, $exportstr;
        if( lc($exportargs[0]) ne 'all' ){
            $envstr = '--env-remove=* ';
        }else{
            shift @exportargs;
        }
        foreach my $arg ( @exportargs ){
            $envstr .= "--env=$arg ";
        }
    }
    return $envstr;
}

#
# strip out gpu type info
#
sub processGpuNode
{
    my ($gpustr) = @_;
    my $retstr = 0;
    $gpustr =~ /(\d+)$/ and $retstr = $1;
    return $retstr;
}

#
# translate Slurm style mpibind args to Flux style
#
sub processMpibind
{
    my ($mpibindstr) = @_;
    my $retstr = '';
    foreach my $mpibindopt ( split /,/, $mpibindstr ){
        if( $mpibindopt eq "verbose" or $mpibindopt eq "v" ){
            $mpibindopt = "verbose:1";
        }elsif( $mpibindopt eq "greedy" ){
            $mpibindopt = "greedy:1";
        }elsif( $mpibindopt =~/^smt(\d+)$/ and my $nsmt = $1 ){
            $mpibindopt = "smt:$nsmt";
        }
        $retstr .="--setopt=mpibind=$mpibindopt ";
    }
    return $retstr;
}

#
# Check to see if an arg is a valid singleton arg
#
sub is_singlearg
{
    my ($arg) = @_;
    my %singleargs = (
           "--bell" => 1,
           "--contiguous" => 1,
           "-X" => 1,
           "--disable-status" => 1,
           "--exact" => 1,
           "--exclusive" => 1,
           "-h" => 1,
           "--help" => 1,
           "-H" => 1,
           "--hold" => 1,
           "--ignore-pbs" => 1,
           "-l" => 1,
           "--label" => 1,
           "--multi-prog" => 1,
           "--nice" => 1,
           "-Z" => 1,
           "--no-allocate" => 1,
           "--no-bell" => 1,
           "-k" => 1,
           "--no-kill" => 1,
           "--no-requeue" => 1,
           "--no-shell" => 1,
           "-O" => 1,
           "--overcommit" => 1,
           "--overlap" => 1,
           "-s" => 1,
           "--oversubscribe" => 1,
           "--parsable" => 1,
           "-E" => 1,
           "--preserve-env" => 1,
           "--pty" => 1,
           "-Q" => 1,
           "--quiet" => 1,
           "--quit-on-interrupt" => 1,
           "--reboot" => 1,
           "--requeue" => 1,
           "--spread-job" => 1,
           "--test-only" => 1,
           "-u" => 1,
           "--unbuffered" => 1,
           "--usage" => 1,
           "--use-min-nodes" => 1,
           "-v" => 1,
           "--verbose" => 1,
           "-V" => 1,
           "--version" => 1,
           "-W" => 1,
           "--wait" => 1,
           "--x11" => 1
        );
    if( $singleargs{$arg} ){
        return 1;
    }else{
        return 0;
    }
}

#
# Check the option, need at least a job id.
#
sub GetOpts
{
	@ARGV = @_;

#
#       A little hacking with the ARGV array to allows
#       arguments and parameters to be squeezed together
#       like msub allows. This works becuase msub paired
#       arguments options are only one character.
#
#       ie. -A abc  can be -Aabc
#
#       Also need to terminate argument processing when
#       we get to the user's executable. This almost does
#       that.
    my @tmpargv;
    my $prevarg = my $doubledash = '';
    foreach my $tmp (@ARGV){
        if( !$doubledash ){
            if( $tmp =~ /^(\-\w)(\S+)/ and 
                    push(@tmpargv, $1),
                    push(@tmpargv, $2) ){
                $prevarg = $2;
            }else{
                if( $tmp !~ /^\-/ and ($prevarg =~ /^\-\-/i or $prevarg !~ /^\-/i or is_singlearg($prevarg)) ){
                    push @tmpargv, '--';
                    $doubledash = 'yes';
                }
                push @tmpargv, $tmp;
                $prevarg = $tmp;
            }
        }else{
            push @tmpargv, $tmp;
        }
    }

    @ARGV = @tmpargv;

	return GetOptions(
        'A|account=s'            => \$account_opt,
        'b|begin=s'              => \$begin_opt,
		'c|cpus-per-task=i'	     => \$cpus_per_task_opt,
        'cpu-bind=s'             => \$cpu_bind_opt,
		'comment=s'        	     => \$comment_opt,
        'cores=i'                => \$cores_opt,
        'cores-per-socket=i'     => \$cores_per_socket_opt,
        'D|chdir=s'              => \$chdir_opt,
        'd|dependency=s'         => \$dependent_opt,
		'e|error=s'        	     => \$error_opt,
        'exact'                  => \$exact_opt,
        'exclusive'              => \$exclusive_opt,
        'export=s'               => \$export_opt,
        'gpu-bind=s'             => \$gpu_bind_opt,
        'gpus-per-node=s'        => \$gpus_per_node_opt,
        'gpus-per-task=i'        => \$gpus_per_task_opt,
        'H|hold'                 => \$hold_opt,
		'h|help'         	     => \$help_opt,
        'hugepages=s'            => \$hugepages_opt,
        'i|input=s'              => \$input_opt,
        'J|job-name=s'           => \$jobname_opt,
        'jobid=s'                => \$jobid_opt,
        'l|label'         	     => \$label_opt,
        'mem-bind=s'             => \$mem_bind_opt,
        'mpi=s'                  => \$mpi_opt,
        'mpibind=s'              => \$mpibind_opt,
		'nice=i'         	     => \$priority_opt,
		'N|nodes=i'        	     => \$nodes_opt,
		'n|ntasks=i'       	     => \$ntasks_opt,
        'ntasks-per-core=i'      => \$ntasks_per_core_opt,
        'ntasks-per-node=i'      => \$ntasks_per_node_opt,
        'no-shell'               => \$no_shell_opt,
		'o|output=s'       	     => \$output_opt,
        'p|partition=s'    	     => \$partition_opt,
        'pty'                    => \$pty_opt,
        'S|core-spec=s'          => \$corespec_opt,
		'slurmd-debug=s'   	     => \$flux_debug_opt,
        'sockets-per-node=i'     => \$sockets_per_node_opt,
		't|time=s'         	     => \$time_opt,
        'thp=s'                  => \$thp_opt,
        'u|unbuffered'           => \$unbuffered_opt,
		'v|verbose'       	     => \$verbose_opt,
        'wait'                   => \$wait_opt,
        'wrap=s'                 => \$wrap_opt,
		'Z|no-allocate'   	     => \$no_allocate_opt,
	);
}


#
# Usage.
#
sub usage
{

	printf("
    -Slurm compatible options supported in Flux-

OPTIONS
=======
-A|--account=<bank>         Run job under <bank>.
-b|--begin=<datetime>       Ensure that job doesn't start until date/time.
--cores=<count>             Number of cores for job.
--cores-per-socket=<count>  Number of cores per socket (must also use --sockets-per-node and --nodes).
-c|cpus-per-task=<count>    Number of cpus per task.
--cpu-bind=none             Turn off native cpu binding.
--cpu-bind=<cpu_list>|<cpu_mask>
                            Specify a detailed task to cpu binding with a cpu list or cpu mask.
--comment=<comment>         User defined comment.
-D|--chdir=<directory>      Specify a working directory.
-d|--dependency=<jobid>     Specify job that this job is dependent on.
-e|--error=<filename>       Path and file name for stderr data.
--exact                     Use minimal resources required for ntasks.
--exclusive                 Allocate whole nodes to job.
--export=<[ALL,]<env_vars>|ALL|NONE>
                            Control which env variables get exported to job. Default is ALL.
--gpu-bind=none             Turn off native gpu binding.
--gpus-per-node=<count>     Number of gpus per node.
--gpus-per-task=<count>     Number of gpus per task.
-H|--hold                   Submit job in a 'held' state.
-h|--help                   List the available options.
--hugepages=N[KMG]          Attempt to make N (kB,MB, GB) worth of HugePages available on nodes in allocation.
-i|--input=<filename>       Path and file name for stdin.
-J|--job-name=<jobname>     Name for the job.
--jobid=<jobid>             Run under an existing allocation (srun only).
-l|--label                  Label IO with task rank prefixes.
--mem-bind=none             Memory binding preferences. 'none' is the only currently valid value.
--mpi=none                  Use native mpi libraries.
--mpibind=<option>          Options for mpibind pluging.
-N|--nodes=<count>          Number of nodes needed.
-n|--ntasks=<count>         Number of tasks needed.
--ntasks-per-core=<count>   Run <count> tasks on each core.
--ntasks-per-node=<count>   Run <count> tasks on each node.
--no-shell                  Just get an allocation and don't run anything (salloc only).
--nice=<number>             User defined priority.
-o|--output=<filename>      Path and file name for stdout data.
-p|--partion=<partition>    Partition or queue to submit job to.
--pty                       Run in pseudo terminal mode.
-S|--core-spec=<corecount>  Reserve cores for system processes.
--slurmd-debug=<level>      Debugging added.
--sockets-per-node=<count>  Number of sockets per node (must also use --cores-per-socket and --nodes).
-t|--time=<timelimit>       Wall time of job.
--thp=[always|never]        Control transparent huge page (THP) support on nodes of an allocation.
-u|--unbuffered             Disable buffering of standard inuput and output.
-v|-verbose                 Give more messages.
--wait                      Do not return until job completes.
--wrap=<command>            Wrap command in an implied script.
-Z|--no-allocate            Run a job on a set of nodes with doing an actual allocation.
\n\n");

	exit;
}

##########
########## not yet, might be needed later on.
##########
#                'a|attach'        		=> \$attach_opt,
#                'b|batch'         		=> \$batch_opt,
#                'Bextra-node-info=s' 		=> \$vextra_node_al,
#                'C|constraint=s'    		=> \$constraint_opt,
#                'E|preserve-env'  		=> \$preserve_opt,
#                'E|preserve-flux-env' 		=> \$preserve_opt,
#                'G|geometry=s'      		=> \$geometry_opt,
#                'I|immediate:s'     		=> \$immediate_opt,
#                'join=s'          		=> \$join_opt,
#                'k|no-kill'       		=> \$no_kill_opt,
#                'K|kill-on-bad-exit:s' 		=> \$kill_on_bad_exit_opt,
#                'L|licenses=s'      		=> \$licenses_opt,
#                'L|license=s'      		=> \$licenses_opt,
#                'm|distribution=s'  		=> \$distribution_opt,
#                'O|overcommit'    		=> \$overcommit_opt,
#                'q|quit-on-interrupt' 		=> \$quiet_on_ibnterupt_opt,
#                'Q|quiet'            		=> \$quiet_opt,
#                'r|relative=s'      		=> \$relative_opt,
#                'R|no-rotate'     		=> \$no_rotate_opt,
#                's|share'         		=> \$share_opt,
#                'T|threads=s'       		=> \$threads_opt,
#                'u|unbuffered'    		=> \$unbuffered_opt,
#                'V|version'       		=> \$version_opt,
#                'w|nodelist=s'      		=> \$nodelist_opt,
#                'W|wait=s'          		=> \$wait_opt,
#                'x|exclude=s'       		=> \$exclude_opt,
#                'X|disable-status' 		=> \$disable_status_opt,
#                'acctg-freq=s'       		=> \$acct_freq_opt,
#                'alps=s'             		=> \$alps_opt,
#                'blrts-image=s'      		=> \$blrts_imnage_opt,
#                'checkpoint=s'       		=> \$checkpoint_opt,
#                'checkpoint-dir=s'   		=> \$checkpoint_dir_opt,
#                'cnload-image=s'     		=> \$cnloab_image_opt,
#                'debugger-test'    		=> \$debugger_test_opt,
#                'epilog=s'           		=> \$debugger_test_opt,
#                'get-user-env=s'      		=> \$get_user_env_opt,
#                'gid=s'              		=> \$gid_val,
#                'gres=s'             		=> \$gres_opt,
#                'hint=s'             		=> \$hint_opt,
#                'ioload-image=s'     		=> \$ioload_images_opt,
#                'linux-image=s'      		=> \$linux_image_opt,
#                'mail-type=s'        		=> \$ail_type_opt,
#                'mail-user=s'        		=> \$mail_user_opt,
#                'max-exit-timeout=s' 		=> \$mail_exit_opt,
#                'max-launch-time=s'  		=> \$mail_launch_time_opt,
#                'mem=s'              		=> \$mem_opt,
#                'mem-per-cpu=s'      		=> \$mem_per_cpu_opt,
#                'mem_bind=s'         		=> \$mem_bind_opt,
#                'mloader-image=s'    		=> \$mloaver_image_opt,
#                'mpi=s'              		=> \$mpi_opt,
#                'msg-timeout=s'      		=> \$msg_timeout_opt,
#                'multi-prog'       		=> \$multi_prog_opt,
#                'network=s'          		=> \$network_opt,
#                'nice:s'              		=> \$nice_opt,
#                'ntasks-per-socket=s'		=> \$ntasks_per_socket_opt,
#                'open-mode=s'        		=> \$open_mode_opt,
#                'prolog=s'           		=> \$prolog_opt,
#                'propagate:s'         		=> \$propagate_opt,
#                'pty'              		=> \$pty_opt,
#                'qos=s'              		=> \$qos_opt,
#                'ramdisk-image=s'    		=> \$ramdisk_image_opt,
#                'reboot'           		=> \$reboot_opt,
#                'reservation=s'      		=> \$reservation_opt,
#                'restart-dir=s'      		=> \$restarert_dir_opt,
#                'resv-ports:s'        		=> \$resv_ports_opt,
#                'signal=s'           		=> \$signal_opt,
#                'task-epilog=s'      		=> \$task_epilog_opt,
#                'task-prolog=s'      		=> \$task_prolog_opt,
#                'tasks-per-node=s'   		=> \$tasks_per_node_opt,
#                'test-only'        		=> \$test_only_opt,
#                'time-min=s'         		=> \$time_min_opt,
#                'threads-per-core=s' 		=> \$tghreads_per_core_opt,
#                'tmp=s'              		=> \$tmp_opt,
#                'uid=s'              		=> \$uid_opt,
#                'usage'            		=> \$usage_opt,
#                'wckey=s'            		=> \$wckey_opt,
