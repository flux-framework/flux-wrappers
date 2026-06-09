%define realname flux-wrappers
%define realversion 0.1

Name: %{realname}
Version: %{realversion}
Release: 1%{?dist}
Summary: Slurm commands translated to Flux
License: LGPL-3.0
Group: System Environment/Base
URL: https://github.com/LLNL/flux-wrappers
Source0: %{realname}-%{realversion}.tgz
BuildRoot: %{_tmppath}/%{name}-%{version}-root-%(%{__id_u} -n)
Packager: Ryan Day <day36@llnl.gov>

Requires: flux-core
Conflicts: slurm

######################################################################
%global debug_package %{nil}

%prep

%setup -n %{name}-%{version}

%build

%description
The flux-wrappers are a set of wrapper scripts that translate
Slurm and other resource manager commands and flags into their
equivalent Flux commands.

%local_options

%install
rm -rf "$RPM_BUILD_ROOT"
mkdir -p $RPM_BUILD_ROOT
mkdir -p $RPM_BUILD_ROOT%{_bindir}
install src/slurm2flux.pl $RPM_BUILD_ROOT%{_bindir}/slurm2flux
install src/fsqueue.py $RPM_BUILD_ROOT%{_bindir}/squeue
install src/fshowq.py $RPM_BUILD_ROOT%{_bindir}/showq
install src/fscancel.py $RPM_BUILD_ROOT%{_bindir}/scancel
install src/fsinfo.pl $RPM_BUILD_ROOT%{_bindir}/sinfo
ln $RPM_BUILD_ROOT%{_bindir}/slurm2flux $RPM_BUILD_ROOT%{_bindir}/srun
ln $RPM_BUILD_ROOT%{_bindir}/slurm2flux $RPM_BUILD_ROOT%{_bindir}/sbatch
ln $RPM_BUILD_ROOT%{_bindir}/slurm2flux $RPM_BUILD_ROOT%{_bindir}/salloc

#######################################################################

%clean
rm -rf $RPM_BUILD_ROOT


#######################################################################
%post

%files
%{_bindir}/slurm2flux
%{_bindir}/squeue
%{_bindir}/showq
%{_bindir}/scancel
%{_bindir}/sinfo
%{_bindir}/srun
%{_bindir}/sbatch
%{_bindir}/salloc


	

##
## vim: set ts=4 sw=4:
####
%changelog
* Tue Dec 20 2022 Ryan Day <day36@llnl.gov> - 
- Initial build.
