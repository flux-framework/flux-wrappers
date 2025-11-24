#!/bin/env -S flux python
###############################################################
# Copyright 2020 Lawrence Livermore National Security, LLC
# (c.f. NOTICE.LLNS)
#
# SPDX-License-Identifier: LGPL-3.0
###############################################################

import argparse
import datetime
import flux
import flux.hostlist
import flux.job
import logging
import os.path
import re
import time


class CustomHelpFormatter(argparse.HelpFormatter):
    """
    Create minimal argparse format to mimic that of Slurm.

    See https://stackoverflow.com/a/31124505 for original answer to shortening
    argparse's usage documentation.
    """

    def __init__(self, prog):
        super().__init__(prog, max_help_position=40, width=80)

    def _format_action_invocation(self, action):
        if not action.option_strings or action.nargs == 0:
            return super()._format_action_invocation(action)
        default = self._get_default_metavar_for_optional(action)
        args_string = self._format_args(action, default)
        return ", ".join(action.option_strings) + " " + args_string


class SlurmFormatter:
    """ """

    token_re = r"%\.?[0-9]*[^%\s]?"
    token_pad_re = r"\.*[0-9]+"

    @staticmethod
    def parse_time(time):
        """
        turn a bunch of seconds into something human readable
        """
        time = int(time)

        # Convert time into hours, minutes, and seconds.
        days = time // 86400
        hours = time // 3600 % 24
        minutes = time // 60 % 60
        seconds = time % 60

        if days > 0:
            return f"{days}-{hours:02}:{minutes:02}:{seconds:02}"

        if hours > 0:
            return f"{hours}:{minutes:02}:{seconds:02}"

        return f"{minutes:02}:{seconds:02}"

    def get_header_dict(self):
        """
        print header for output
        """
        headers = {
            "%": "",
            "%a": "USERNAME",
            "%i": "JOBID",
            "%F": "JOBID",
            "%K": "ARRAYID",
            "%P": "PARTITION",
            "%j": "NAME",
            "%u": "USER",
            "%t": "STATUS",
            "%M": "TIME",
            "%D": "NODES",
            "%R": "NODELIST(REASON)",
        }

        return headers

    def get_job_dict(self, job):
        """
        Print a row based on the information from a job and format_string.
        """
        reasonnode = job.sched.reason_pending
        if str(job.sched.reason_pending) == "":
            reasonnode = job.nodelist

        values = {
            "%": "",
            "%a": job.username,
            "%i": job.id.f58,
            "%F": job.id.f58,
            "%K": "0",
            "%P": job.queue,
            "%j": job.name,
            "%u": job.username,
            "%t": job.status_abbrev,
            "%M": self.parse_time(job.runtime),
            "%D": job.nnodes,
            "%R": reasonnode,
        }

        return values

    def format(self, format_string, types_dict):
        """
        format output to minimc slurm's format language
        """
        result = []
        prev_end = 0

        # Search for tokens that begin with % in the format string.
        for token in re.finditer(self.token_re, format_string):

            # Copy text in string before format token to the result text.
            prefix = format_string[prev_end : token.start()]

            # To match the behavior of squeue's format option we should
            # ignore unknown tokens and print them as regular text after
            # issuing a warning.
            try:
                # Users may specify padding modifiers before tokens in
                # the form of %.10u or %10u to indicate a prefix or suffix
                # padding respectively. Find and extract padding modifiers
                # if present.
                width_match = re.match(self.token_pad_re, token.group()[1:])
                if width_match is not None:
                    width_string = width_match.group()
                    output = types_dict[token.group().replace(width_string, "")]
                    if width_string[0] == ".":
                        width = int(width_string[1:])
                        output = f"{output:>{width}}"[:width]
                    else:
                        width = int(width_string)
                        output = f"{output:<{width}}"[:width]
                else:
                    output = types_dict[token.group()]

                result.append(prefix)
                result.append(output)
                prev_end = token.end()

            except KeyError:
                continue

        # Add the remainder of format string after last token to result.
        result.append(format_string[prev_end:])
        return "".join(result)

    def get_unknown_tokens(self, format_string):
        """
        Return a list of unknown tokens based on the types_dict given.
        """
        headers = self.get_header_dict()
        unknown_tokens = []
        for token in re.finditer(self.token_re, format_string):
            width_match = re.match(self.token_pad_re, token.group()[1:])
            key = token.group()
            try:
                if width_match is not None:
                    width_string = width_match.group()
                    key = key.replace(width_string, "")
                    headers[key]
                else:
                    headers[key]
            except KeyError:
                unknown_tokens.append(key)
        return unknown_tokens


def disclaimer():
    """
    print a warning for unsupported arguments
    """
    myname = os.path.basename(__file__)
    return (
        f'{myname}: hint: {myname} is a wrapper script for the native "flux jobs" command.\n'
        f'{myname}: hint: See "man flux jobs" for help using the native commands.'
    )

def filter_byhostlist(jobs, jobfilter):
    """
    filter out jobs that did not run on hosts in jobfilter
    """
    filtered_jobs = []
    for j in jobs:
        for h in jobfilter:
            if h in flux.hostlist.Hostlist(j.nodelist):
                filtered_jobs.append(j)
    return filtered_jobs


def main(parsedargs):
    args, unknown_args = parsedargs
    myname = os.path.basename(__file__)
    logging.basicConfig(level=args.loglevel, format="%(message)s")
    if unknown_args:
        logging.warning(
            f'{myname}: warning: "{unknown_args}" is not supported by this wrapper and is being ignored.\n'
        )
        logging.warning(disclaimer())
    else:
        logging.debug(disclaimer())

    # Setup the flux command variable to track added options to fsqueue
    flux_command = "flux jobs -c 0"

    # Set user if explicitly specified.
    user = "all"
    flux_command += " -A"
    if args.user is not None:
        user = args.user
        flux_command = flux_command.replace("-A", f"-u {args.user}")

    # Set default job_states for search.
    job_states = ["pending", "running"]

    # Validate explicit job state if given.
    if args.state is not None:
        known_states = {
            "running": "running",
            "r": "running",
            "pending": "pending",
            "pd": "pending",
            "all": "active,inactive",
            "f": "failed",
            "cg": "cleanup",
            "completing": "cleanup",
            "ca": "canceled",
            "cancelled": "canceled",
            "to": "timeout",
            "timeout": "timeout",
            "cd": "completed",
            "completed": "completed",
        }

        # Normalize and search for state in known states.
        if args.state.lower() in known_states.keys():
            job_states = [known_states[args.state.lower()]]
            flux_command += f" -f {','.join(job_states)}"
        else:
            logging.error(f"{myname}: error: Invalid job state specified: {args.state}")
            logging.error(
                f"{myname}: error: Valid job states include: {','.join(known_states.keys())}"
            )
            exit(1)

    # Start with an empty list of job ids and append ids if explicity
    # defined by the user as an argument.
    job_ids = []
    if args.jobs is not None:
        for id in args.jobs.split(","):
            job_ids.append(flux.job.JobID(id))
            flux_command += " " + id

    # queues
    queue = ""
    if args.partition is not None:
        queue = args.partition
        flux_command += f" --queue={queue}"

    # job name
    job_name = ""
    if args.name is not None:
        job_name = args.name
        flux_command += f" --name={job_name}"

    # Initialize a connection to flux.
    conn = flux.Flux()

    # Retrieve a list of jobs and attributes from flux. If job_ids is not empty
    # the search will be limited to the jobs specified. Otherwise flux will
    # return a full list of all jobs matching the other filters we've specified.
    rpc = flux.job.JobList(
        conn, user=user, ids=job_ids, queue=queue, name=job_name, filters=job_states, max_entries=0
    ).fetch_jobs()
    jobs = list(rpc.get_jobinfos())

    # Further filter jobs so that all jobs are running on a node in
    # args.nodelist if a nodelist was specified by the user.
    if args.nodelist is not None:
        nodelist = flux.hostlist.Hostlist(args.nodelist)
        jobs = filter_byhostlist(jobs, nodelist)

    # If run with very verbose, show equivalent flux commands to what we
    # are showing in fsqueue.
    logging.debug(f"{myname}: hint: To see an equivelent output from flux try running,")
    logging.debug("")
    logging.debug("\t" + flux_command)
    logging.debug("")

    # If run with verbose mimic squeue's verbose output format to display the
    # values of each of the input command line argument values.
    logging.info("-----------------------------")
    for arg in vars(args):
        logging.info(f"{arg:<11} = {getattr(args, arg)}")
    logging.info("-----------------------------")
    logging.info("")
    logging.info("")
    logging.info(datetime.datetime.now().strftime("%a %b %d %H:%M:%S %Y"))
    logging.info(f"last_update_time={int(time.time())} records={len(jobs)}")

    formatter = SlurmFormatter()

    unknown_tokens = formatter.get_unknown_tokens(args.format)
    for token in unknown_tokens:
        logging.error(f"{myname}: error: Invalid job format specification: {token[1]}")

    if args.noheader is False:
        headers_dict = formatter.get_header_dict()
        print(formatter.format(args.format, headers_dict))

    for job in jobs:
        job_dict = formatter.get_job_dict(job)
        print(formatter.format(args.format, job_dict))


if __name__ == "__main__":

    def fmt(prog):
        return CustomHelpFormatter(prog)

    parser = argparse.ArgumentParser(
        description="List running and queued jobs in squeue format.",
        conflict_handler="resolve",
        allow_abbrev=False,
        formatter_class=fmt,
    )

    parser.add_argument("-u", "--user", metavar="<user>", help="show jobs run by user")

    parser.add_argument(
        "-t",
        "--state",
        metavar="<state>",
        help='use "-t all" to show jobs in all states, including completed jobs',
    )

    parser.add_argument(
        "-j",
        "--jobs",
        metavar="<jobid>,<jobid>,....",
        help="display only jobs specified",
    )

    parser.add_argument(
        "-p",
        "--partition",
        metavar="<partition>",
        help="display only jobs in specified partition/queue.",
    )

    parser.add_argument(
        "-h", "--noheader", action="store_true", help="do not print a header"
    )

    parser.add_argument(
        "-o",
        "--format",
        metavar="<format>",
        default="%.18i %.9P %.8j %.8u %.2t %.10M %.6D %R",
        help="format specification",
    )

    parser.add_argument(
        "-v",
        "--verbose",
        help="report details of script actions",
        action="store_const",
        dest="loglevel",
        const=logging.INFO,
    )

    parser.add_argument(
        "-vv",
        "--very-verbose",
        help="show equivalent flux commands",
        action="store_const",
        dest="loglevel",
        const=logging.DEBUG,
    )

    parser.add_argument(
        "-w", "--nodelist", metavar="<nodelist>", help="show jobs that ran on nodelist"
    )
    
    parser.add_argument(
        "-n", "--name", metavar="<job_name>", help="show jobs named job_name"
    )

    main(parser.parse_known_args())
