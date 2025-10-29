#!/bin/env -S flux python
###############################################################
# Copyright 2020 Lawrence Livermore National Security, LLC
# (c.f. NOTICE.LLNS)
#
# SPDX-License-Identifier: LGPL-3.0
###############################################################

import argparse,time
import os.path
import flux
import flux.job as fjob

def print_argwarn(argval) :
    '''
    print a warning for unsupported arguments
    '''
    myname = os.path.basename(__file__)
    print(f'WARNING: "{argval}" is not supported by this wrapper and is being ignored.')
    print(f'WARNING: {myname} is a wrapper script for the native "flux jobs" command.')
    print('See "flux help jobs" or contact the LC Hotline for help using the native commands.') 
    return None

def parse_time(time) :
    '''
    turn a bunch of seconds into something human readable
    '''
    itime = int(time)
    seconds = itime % 60
    mtime = int( itime / 60 )
    minutes = mtime % 60
    htime = int( mtime / 60 )
    if htime > 0 :
        return f"{htime}:{minutes:02}:{seconds:02}"
    else :
        return f"{minutes:02}:{seconds:02}"

def parse_date(date) :
    '''
    turn whatever flux gives me into something like what showq uses
    '''
    dstr = time.strftime("%a %b %d %H:%M:%S",time.localtime(date))
    return dstr

def parse_exception(exception) :
    '''
    report something like the return code that showq reports
    '''
    if exception.occurred == False :
        return "0:0"
    else :
        return f"1:{exception.severity}"

def get_nodestring(resource) :
    '''
    parse something from flux to get nodestring
    '''
    return "NA"

def get_queuestring(sched) :
    '''
    parse sched from flux to get queue
    '''
    return f"{sched.queue}"

def printheader(jstate) :
    '''
    print header for output
    '''
    print(f"{jstate} jobs------------------------")
    if jstate == "active" :
        print("JOBID      USERNAME   STATE        PROCS    REMAINING            STARTTIME")
    elif jstate == "completed" :
        print("JOBID      USERNAME   ACCOUNT    QOS       CLASS      EXEHOST    STATE        CCODE  PROCS     WALLTIME       COMPLETIONTIME")
    else :
        print("JOBID      USERNAME   STATE        PROCS      WCLIMIT            QUEUETIME")
    print()

def printonejob(j,jstate) :
    '''
    print one job
    '''
    if jstate == "completed" :
        remstring = parse_time(j.contextual_time)
        timestring = parse_date(j.t_cleanup)
        exceptstring = parse_exception(j.exception)
        nastring = " NA         NA        NA         NA        "
        print(f"{j.id.f58:<10} {j.username:<9} {nastring} {j.status:<12} {exceptstring:>5} {j.ntasks:>6} {remstring:>12}  {timestring}")
    else :
        if jstate == "active" :
            remstring = parse_time(j.contextual_time)
            timestring = parse_date(j.t_run)
        else :
            remstring = parse_time(j.contextual_time)
            timestring = parse_date(j.t_submit)
        print(f"{j.id.f58:<10} {j.username:<9}  {j.status:<9}   {j.ntasks:>6}    {remstring:>9}  {timestring}")

def printfooter(nj,jstate) :
    '''
    print footer for output
    '''
    print(f"{nj} {jstate} jobs")
    print()
    print()

def printjobs(jlist,jstate,noheader=False) :
    '''
    print a list of jobs with a header and footer
    '''
    if noheader == False :
        printheader(jstate)
    for j in jlist :
        printonejob(j,jstate)
    if noheader == False :
        print()
        printfooter(len(jlist),jstate)

def main(parsedargs) :
    args, unknown_args = parsedargs
    if unknown_args  :
        print_argwarn(" ".join(unknown_args))
    if args.user != None :
        user = args.user
    else :
        user = "all"
    # get job list and sort it
    myhandle = flux.Flux()
    if args.jobid == None :
        # cap this at 10000 to keep the time to run the command <30s
        mylist = fjob.JobList(myhandle,user=user,max_entries=10000)
    else :
        decid = fjob.id_parse(args.jobid)
        mylist = fjob.JobList(myhandle,user=user,ids=[decid],max_entries=0)
    donejobs = [j for j in mylist.jobs() if j.state_single == "I"]
    pendjobs = [j for j in mylist.jobs() if j.state_single in {"P", "S"}]
    runjobs = [j for j in mylist.jobs() if j.state_single in {"R", "C"}]
    blockedjobs = [j for j in mylist.jobs() if j.state_single == "D"]
    if args.c :
        printjobs(donejobs, "completed", args.noheader)
        njobs = len(donejobs)
    elif args.b :
        printjobs(blockedjobs, "blocked", args.noheader)
        njobs = len(blockedjobs)
    elif args.i :
        printjobs(pendjobs, "eligible", args.noheader)
        njobs = len(pendjobs)
    elif args.r :
        printjobs(runjobs, "active", args.noheader)
        njobs = len(runjobs)
    else :
        printjobs(runjobs, "active", args.noheader)
        printjobs(pendjobs, "eligible", args.noheader)
        printjobs(blockedjobs, "blocked", args.noheader)
        njobs = len(runjobs) + len(pendjobs) + len(blockedjobs)
    if args.noheader == False :
        print(f"Total jobs: {njobs:>3}")
        print()

if __name__ == '__main__' :
    parser = argparse.ArgumentParser(description="List running and queued jobs in squeue format.", conflict_handler='resolve', allow_abbrev=False)
    parser.add_argument('-H', '--noheader', action='store_true', help='do not print a header')
    parser.add_argument('-u', '--user', metavar='<user>', help='show jobs run by user')
    parser.add_argument('-j', '--jobid', metavar='<jobid>', help='show only job with jobid')
    exclarg = parser.add_mutually_exclusive_group()
    exclarg.add_argument('-c', action='store_true', help='display only completed jobs')
    exclarg.add_argument('-b', action='store_true', help='display only blocked jobs')
    exclarg.add_argument('-i', action='store_true', help='display only eligible jobs')
    exclarg.add_argument('-r', action='store_true', help='display only running jobs')
    main(parser.parse_known_args())
