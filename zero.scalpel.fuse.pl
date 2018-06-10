#!/usr/bin/perl -w
#
# MIT License
# 
# Copyright (c) 2018 Anthony Kava
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# zero.scalpel.fuse.pl	FUSE driver in Perl for reading scalpel's
# 			audit.txt file and showing a file system
# 			that maps files it would have carved to a
# 			disk image -- this allows for zero-storage
# 			carving as you can browse and view files
# 			with only a 'scalpel -p' (preview, scalpel
# 			writes no files)
#
# 			Useful for me anyway, maybe not for you,
# 			but if so then enjoy.
#
# 			NO WARRANTY (MIT) -- PROOF OF CONCEPT
#
#			Version: 0.00.2018.06.10.1301.poc
# 			@anthonykava aka Karver
#
#	TODO: split lots of entries into sub-dirs
#	TODO: do better
#
#	Uses Fuse Perl module found thuswhere:
#
#		http://search.cpan.org/dist/Fuse/
#		https://github.com/dpavlin/perl-fuse.git
#		(This script has roots in 'examples/example.pl' from the repo)
#
#		Debian/Ubuntu can usually do: sudo apt install libfuse-perl
#
#   Pre-reqs:
#
#   	Perl modules: Cwd, Fuse, POSIX
#
#   	Other:	scalpel 1.60
#   			Debian/Ubuntu: sudo apt install scalpel
#  				See also: https://github.com/sleuthkit/scalpel
#
#	Example use with an E01 and xmount (no root/sudo required):
#	(xmount not required with a raw/dd disk image, of course)
#
#		$ mkdir xm; xmount --in ewf IMAGE.E01 xm/
#		$ scalpel -p xm/IMAGE.E01.dd
#		$ ./zero.scalpel.fuse.pl xm/IMAGE.dd
#		$ ls mnt/
#		$ #...profit... (use whatever tools you like)
#		$ fusermount -u mnt/; rmdir mnt	# when done
#		$ fusermount -u xm/; rmdir xm	# when done

use strict;							# of course
use warnings;							# helpful
use Cwd			qw/cwd abs_path/;			# for resolving relative paths
use Fuse		qw/fuse_get_context/;			# kinda the point
use POSIX		qw/ENOENT EISDIR EINVAL/;		# values for FUSE

my $usage		= "\tUsage: $0 imgPath [auditPath] [mntPoint] [debug] [stayAttached]\n";
my $imgPath		= shift()||'';				# Disk image path
my $auditPath		= shift()||'scalpel-output/audit.txt';	# Path to scalpel audit.txt
my $mntPoint		= shift()||'mnt';			# Mount point
my $debug		= shift()||0;				# 0=none, 1=some
my $stayAttached	= shift()||0;				# 0=be daemon-like, 1=stay

# Init hashes to track things (not ideal, so let's call this beta)
my %fileStarts		= ();
my %fileSizes		= ();
my %fileExtens		= ();

# Make $mntPoint if it doesn't exist, resolve to absolute path (FUSE wants)
mkdir($mntPoint) if !-e $mntPoint;
$mntPoint=abs_path($mntPoint) if -e $mntPoint;

# Check our parameters before proceeding
if(!-e $imgPath)
{
	die("\nProblem with imgPath=$imgPath\n\n$usage\n");
}
if(!-e $auditPath)
{
	die("\nProblem with auditPath=$auditPath\n\n$usage\n");
}
if(!-e $mntPoint || !-d $mntPoint)
{
	die("\nProblem with mntPoint=$mntPoint\n\n$usage\n");
}

# Open image file -- we'll be seeking around inside
my $imgFh;
if(open($imgFh,$imgPath))
{
	&debug("Launch: imgPath=$imgPath auditPath=$auditPath mntPoint=$mntPoint debug=$debug");
}
else
{
	die("\nProblem OPENING imgPath=$imgPath\n\n$usage\n");
}

# Parse audit.txt and build our FS
if(open(my $fh,$auditPath))
{
	my $goTime=0;
	foreach(<$fh>)
	{
		chomp();
		$goTime=0 if /Completed/;
		if($goTime)
		{
			my($file,$start,$chop,$len,$image)=split(/\s+/,$_,5);
			#File		  Start		Chop	Length		Extracted From
			#00000017.3GP5      487936	YES         2500000	image.reformatted.dd
			#00000016.PNG       430592	YES         2500000	image.reformatted.dd
			#00000015.JPG      1428805	YES         2500000	image.reformatted.dd

			if($file && $start && $len)
			{
				$fileStarts{$file}=$start;
				$fileSizes{$file}=$len;
				my $exten='unknown';
				$exten=$1 if $file=~/\.([^\.]+)$/;
				$fileExtens{$exten}++;
				&debug("audit.txt => file=$file start=$start chop=$chop len=$len image=$image exten=$exten");
			}
		}
		elsif(/File\s+Start\s+Chop\s+Length\s+Extracted From/)	# scalpel 1.60 specific probably
		{
			$goTime=1;
		}
	}
	close($fh);
}
else
{
	die("\nProblem OPENING auditPath=$auditPath\n");
}

# Build our file system layout as arrays of files in %fs (keys are dirs)
my %fs=('/' => []);
foreach my $ext (sort(keys(%fileExtens)))
{
	push(@{ $fs{'/'} },$ext);
	$fs{'/'.$ext}=[];
	foreach my $file (sort(keys(%fileSizes)))
	{
		my $fileExt='unknown';
		$fileExt=$1 if $file=~/^.+\.([^\.]+)$/;
		push(@{ $fs{'/'.$ext} },$file) if $ext eq $fileExt;
	}
}

#/*********************************************************************/
#/*                         Main Procedure                            */
#/*********************************************************************/

&daemonise() if !$stayAttached;				# fork-off
Fuse::main(						# FUSE tofu & potatoes
	mountpoint	=>	$mntPoint,		# <-- mount point here
	mountopts	=>	'ro,allow_other',
	getattr		=>	"main::e_getattr",
	getdir		=>	"main::e_getdir",
	open		=>	"main::e_open",
	statfs		=>	"main::e_statfs",
	read		=>	"main::e_read",
	threaded	=>	0
);

#/*********************************************************************/
#/*                           Subroutines                             */
#/*********************************************************************/

# e_getattr($file) -- handler for returning FS attributes
sub e_getattr
{
	my $path=shift()||'.';
	my @ret=(-ENOENT());				# default no entity
	&debug("e_getattr($path)");

	my $blockSize=2**10 * 64;															# our preferred block size
	my $size=$blockSize;																# default $size to 1 block
	my $modes=(0100<<9) + 0444;															# default mode to regular file 0444
	my($dev,$ino,$rdev,$blocks,$gid,$uid,$nlink,$blksize)=(0,0,0,1,0,0,1,$blockSize); # init stat details
	my($atime,$ctime,$mtime)=(time(),time(),time());									# MAC times are now

	# If $path is meant to be a directory (e.g., /, ., /jpg)
	my $dirTest='/'.$path;
	if($path eq '/' || $path eq '.' || $fs{$path} || $fs{$dirTest})	# directory
	{
		$modes=(0040<<9)+0555;	# 0555 mode dir
		@ret=($dev,$ino,$modes,$nlink,$uid,$gid,$rdev,$size,$atime,$mtime,$ctime,$blksize,$blocks);
	}
	else	# regular file
	{
		$modes=(0100<<9)+0444;	# 0444 mode file
		my $file='';
		$file=$1 if $path=~/^.+\/([^\/]+)$/;
		$size=$fileSizes{$file} ? $fileSizes{$file} : 0;
		@ret=($dev,$ino,$modes,$nlink,$uid,$gid,$rdev,$size,$atime,$mtime,$ctime,$blksize,$blocks);
	}
	return(@ret);
}

# e_getdit($dir) -- handler for returning dir entries
sub e_getdir
{
	my $dir=shift()||'/';				# / default, why not
	my @ret=();
	&debug("e_getdir($dir)");

	if($dir eq '/' || $dir eq '.')			# root
	{
		@ret=@{ $fs{'/'} };
	}
	elsif($dir=~/^\/?([^\/]+)$/)			# first level (file extensions)
	{
		my $ext=$1;
		$dir='/'.$dir if $dir!~/^\//;
		debug("should show fs dir=$dir now, fs{$dir}=@{ $fs{$dir} }");
		@ret=@{ $fs{$dir} };
	}
	return(@ret,0);			# no, I don't know what the last element '0' means
}

# e_open($file) -- handler for opening files, returns file handle
# "VFS sanity check; it keeps all the necessary state, not much to do here."
sub e_open
{
	my $file=shift()||'.';
	my($flags,$fileinfo)=@_;
	my @ret=(-ENOENT());

	&debug("open called $file, $flags, $fileinfo");

	# If $path is meant to be a directory (e.g., /, ., /jpg)
	my $dirTest='/'.$file;
	if($file eq '/' || $file eq '.' || $fs{$file} || $fs{$dirTest})	# directory
	{
		@ret=(-EISDIR());			# error: this is a dir, mate
	}
	elsif($file=~/^\/?[^\/]+\/([^\/]+)$/)		# if $file is meant to be a file
	{
		my $file=$1;
		@ret=(0,rand()) if $fileStarts{$file};	# random file handle for appearances
	}
    	&debug("open ok for file=$file (handle $ret[1])") if $ret[1];
	return(@ret);
}

# e_read($file) -- handler for reading files
# "return an error numeric, or binary/text string.  (note: 0 means EOF, "0" will"
# "give a byte (ascii \"0\") to the reading program)"
sub e_read
{
	my $path=shift()||'.';
	my($buf,$off,$fh)=@_;
	my $ret=-ENOENT();
	&debug("read from $path, $buf \@ $off");

	if($path=~/^\/?[^\/]+\/([^\/]+)$/)		# if filename seems plausible
	{
		my $file=$1;
		my $start=$fileStarts{$file};
		my $size=$fileSizes{$file};
		if(!$start || !$size)
		{
			$ret=-ENOENT();			# give FS error if this failed
		}
		elsif($off>$size)
		{
			$ret=-EINVAL();			# invalid FS error if reading beyond end
		}
		elsif($off==$size)
		{
			$ret=0;				# return 0 if we're done reading
		}
		else
		{
			open($imgFh,$imgPath) if !$imgFh;
			if($imgFh)
			{
				seek($imgFh,$start+$off,0);
				read($imgFh,$ret,$buf);
				&debug("\tread will return ".length($ret)." byte(s) as \$ret");
			}
			else
			{
				$ret=-ENOENT();		# give FS error if opening image failed
			}
		}
	}
	return($ret);
}

# e_statfs() -- gives FS stats to OS, but I don't understand it yet
sub e_statfs { return 255, 1, 1, 1, 1, 2 }

# daemonise([$logfile]) -- forks-off so we can play like a daemon
# stolen from 'examples/loopback.pl' from the GitHub repo
# "Required for some edge cases where a simple fork() won't do."
# "from http://perldoc.perl.org/perlipc.html#Complete-Dissociation-of-Child-from-Parent"
sub daemonise
{
	my $logfile=shift()||cwd().'/log.zero.scalpel.fuse';		# log file in pwd unless passed
	chdir("/")||die("can't chdir to /: $!");
	open(STDIN,'<','/dev/null')||die("can't read /dev/null: $!");	# redir STDIN (/dev/null)
	open(STDOUT,'>>',$logfile)||die("can't open logfile: $!");	# redir STDOUT to log file
	defined(my $pid=fork())||die("can't fork: $!");			# when you come to a fork()...
	exit(0) if $pid;													# "non-zero now means I am the parent"
#	(setsid() != -1) || die "Can't start a new session: $!";	# (didn't use this)
	open(STDERR,'>&',\*STDOUT)||die("can't dup stdout: $!");	# STDERR to STDOUT
}

# debug($msg[,$lvl=1]) -- print timestamp and $msg if $debug>=$lvl
sub debug
{
	my $msg=shift()||'';
	my $lvl=shift()||1;
	if($debug>=$lvl)
	{
		chomp($msg);
		print scalar(localtime())."\t".$msg."\n" if $msg;
	}
}
