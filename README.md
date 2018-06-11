# zero.scalpel.fuse.pl

FUSE driver in Perl for reading scalpel's audit.txt file and showing a file system that maps files it would have carved to a disk image -- this allows for zero-storage carving as you can browse and view files with only a 'scalpel -p' (preview, scalpel writes no files) -- tested under Ubuntu Linux 18.04  
  
Useful for me anyway, maybe not for you, but if so then enjoy.  
  
NO WARRANTY (MIT) -- PROOF OF CONCEPT  
@anthonykava aka Karver  
  
## Pre-reqs

Perl modules: Cwd, Fuse, POSIX  

Uses Fuse Perl module found thuswhere:  
  
http://search.cpan.org/dist/Fuse/  
https://github.com/dpavlin/perl-fuse.git  
(This script has roots in 'examples/example.pl' from the repo)  
  
Debian/Ubuntu can usually do: sudo apt install libfuse-perl  
  
Tested with scalpel 1.60  
Debian/Ubuntu: sudo apt install scalpel  
See also: https://github.com/sleuthkit/scalpel

## Example use with an E01 and xmount (no root/sudo required)
(xmount not required with a raw/dd disk image, of course)

      $ mkdir xm; xmount --in ewf IMAGE.E01 xm/
      $ scalpel -p xm/IMAGE.dd
      $ ./zero.scalpel.fuse.pl xm/IMAGE.dd
      $ ls mnt/
      $ #...profit... (use whatever tools you like)
      $ fusermount -u mnt/; rmdir mnt # when done
      $ fusermount -u xm/; rmdir xm   # when done
