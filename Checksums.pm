package CPAN::Checksums;

use strict;
use vars qw($VERSION $REVISION $CAUTION $TRY_SHORTNAME @ISA @EXPORT_OK);

require Exporter;

@ISA = qw(Exporter);
@EXPORT_OK = qw(updatedir);
$REVISION = sprintf "%d.%03d", q$Revision: 1.10 $ =~ /(\d+)\.(\d+)/;
$VERSION = "1.0";
$CAUTION ||= 0;
$TRY_SHORTNAME ||= 0;

use DirHandle ();
use IO::File ();
use Digest::MD5 ();
use Compress::Zlib ();
use File::Spec ();
use Data::Dumper ();
use Data::Compare ();

sub updatedir ($) {
  my($dirname) = @_;
  my $dref = {};
  my(%shortnameseen,@p);
  my($dh)= DirHandle->new;
  my($fh) = new IO::File;
  $dh->open($dirname) or die "Couldn't opendir $dirname\: $!";
 DIRENT: for my $de ($dh->read) {
    next if $de =~ /^\./;
    next if substr($de,0,9) eq "CHECKSUMS";
    next if $de =~ /readme$/i;

    my $abs = File::Spec->catfile($dirname,$de);

    #
    # SHORTNAME offers an 8.3 name, probably not needed but it was
    # always there,,,
    #
    if ($TRY_SHORTNAME) {
      my $shortname = lc $de;
      $shortname =~ s/\.tar[._-]gz$/\.tgz/;
      my $suffix;
      ($suffix = $shortname) =~ s/.*\.//;
      substr($suffix,3) = "" if length($suffix) > 3;
      if ($shortname =~ /\-/) {
        @p = $shortname =~ /(.{1,16})-.*?([\d\.]{2,8})/;
      } else {
        @p = $shortname =~ /(.{1,8}).*?([\d\.]{2,8})/;
      }
      $p[0] ||= lc $de;
      $p[0] =~ s/[^a-z0-9]//g;
      $p[1] ||= 0;
      $p[1] =~ s/\D//g;
      my $counter = 7;
      while (length($p[0]) + length($p[1]) > 8) {
        substr($p[0], $counter) = "" if length($p[0]) > $counter;
        substr($p[1], $counter) = "" if length($p[1]) > $counter--;
      }
      my $dot = $suffix ? "." : "";
      $shortname = "$p[0]$p[1]$dot$suffix";
      while (exists $shortnameseen{$shortname}) {
        my($modi) = $shortname =~ /([a-z\d]+)/;
        $modi++;
        $shortname = "$modi$dot$suffix";
        if (++$counter > 1000){ # avoid endless loops and accept the buggy choice
          warn "Warning: long loop on shortname[$shortname]de[$de]";
          last;
        }
      }
      $dref->{$de}->{shortname} = $shortname;
      $shortnameseen{$shortname} = undef; # for exists check good enough
    }

    #
    # STAT facts
    #
    if (-l File::Spec->catdir($dirname,$de)){
      # Symlinks are a mess on a replicated, database driven system,
      # but as they are not forbidden, we cannot ignore them. We do
      # have a directory with nothing but a symlink in it. When we
      # ignored the symlink, we did not write a CHEKSUMS file and
      # CPAN.pm issued lots of warnings:-(
      $dref->{$de}{issymlink} = 1;
    }
    if (-d File::Spec->catdir($dirname,$de)){
      $dref->{$de}{isdir} = 1;
    } else {
      my @stat = stat $abs or next DIRENT;
      $dref->{$de}{size} = $stat[7];
      my(@gmtime) = gmtime $stat[9];
      $gmtime[4]++;
      $gmtime[5]+=1900;
      $dref->{$de}{mtime} = sprintf "%04d-%02d-%02d", @gmtime[5,4,3];

      my $md5 = Digest::MD5->new;
      $fh->open("$abs\0") or die "Couldn't open $abs: $!";
      $md5->addfile($fh);
      $fh->close;
      my $digest = $md5->hexdigest;
      $dref->{$de}{md5} = $digest;
      $md5 = Digest::MD5->new;
      if ($de =~ /\.gz$/) {
        my($buffer, $gz);
        if ($gz  = Compress::Zlib::gzopen($abs, "rb")) {
          $md5->add($buffer)
              while $gz->gzread($buffer) > 0;
          # Error management?
          $dref->{$de}{'md5-ungz'} = $md5->hexdigest;
          $gz->gzclose;
        }
      }
    } # ! -d
  }
  $dh->close;
  my $ckfn = File::Spec->catfile($dirname, "CHECKSUMS");
  unless (%$dref) {
    unlink $ckfn or die "Couldn't unlink $ckfn: $!" if -f $ckfn;
    return 1;
  }
  local $Data::Dumper::Indent = 1;
  local $Data::Dumper::Quotekeys = 1;
  my $ddump = Data::Dumper->new([$dref],["cksum"])->Dump;
  if ($fh->open($ckfn)) {
    my $cksum = "";
    local $/ = "\n";
    while (<$fh>) {
      next if /^\#/;
      $cksum .= $_;
    }
    close $fh;
    return 1 if $cksum eq $ddump;
    return 1 if ckcmp($cksum,$dref);
    if ($CAUTION) {
      my $report = investigate($cksum,$dref);
      warn $report if $report;
    }
  }
  chmod 0644, $ckfn or die "Couldn't chmod to 0644 for $ckfn\: $!" if -f $ckfn;
  open $fh, ">$ckfn\0" or die "Couldn't open >$ckfn\: $!";
  printf $fh "# CHECKSUMS file written on %s by CPAN::Checksums (v%s)\n%s",
      scalar gmtime, $VERSION, $ddump;
  close $fh;
  chmod 0444, $ckfn or die "Couldn't chmod to 0444 for $ckfn\: $!";
  2;
}

sub ckcmp ($$) {
  my($old,$new) = @_;
  for ($old,$new) {
    $_ = makehashref($_);
  }
  Data::Compare::Compare($old,$new);
}

# see if a file changed but the name not
sub investigate ($$) {
  my($old,$new) = @_;
  for ($old,$new) {
    $_ = makehashref($_);
  }
  my $complain = "";
  for my $dist (sort keys %$new) {
    if (exists $old->{$dist}) {
      my $headersaid;
      for my $diff (qw/md5 size md5-ungz mtime/) {
        next unless exists $old->{$dist}{$diff} &&
            exists $new->{$dist}{$diff};
        next if $old->{$dist}{$diff} eq $new->{$dist}{$diff};
        $complain .=
            scalar localtime().
                ":\ndiffering old/new version of same file $dist:\n"
                    unless $headersaid++;
        $complain .=
            qq{\t$diff "$old->{$dist}{$diff}" -> "$new->{$dist}{$diff}"\n}; #};
      }
    }
  }
  $complain;
}

sub makehashref ($) {
  local($_) = shift;
  unless (ref $_ eq "HASH") {
    require Safe;
    my($comp) = Safe->new("CPAN::Checksums::reval");
    my $cksum; # used by Data::Dumper
    $_ = $comp->reval($_);
    die "Caught $@" if $@;
  }
  $_;
}

1;

__END__

=head1 NAME

CPAN::Checksums - Write a CHECKSUMS file for a directory as on CPAN

=head1 SYNOPSIS

  use CPAN::Checksums qw(updatedir);
  my $success = updatedir($directory);

=head1 INCOMPATIBILITY ALERT

Since version 1.0 the generation of the attribute C<shortname> is
turned off by default. It was too slow and was not used as far as I
know, and above all, it could fail on large directories. The shortname
feature can still be turned on by setting the global variable
$TRY_SHORTNAME to a true value.

=head1 DESCRIPTION

updatedir takes a directory name as argument and writes a CHECKSUMS
file in that directory unless a previously written CHECKSUMS file is
there that is still valid. Returns 2 if a new CHECKSUMS file has been
written, 1 if a valid CHECKSUMS file is already there, otherwise dies.

Setting the global variable $CAUTION causes updatedir() to report
changes of files in the attributes C<size>, C<mtime>, C<md5>, or
C<md5-ungz> to STDERR.

By setting the global variable $TRY_SHORTNAME to a true value, you can
tell updatedir() to include an attribute C<shortname> in the resulting
hash that is 8.3-compatible. Please note, that updatedir() in this
case may be slow and may even fail on large directories, because it
will always only try 1000 iterations to find a name that is not yet
taken and then give up.

=head1 PREREQUISITES

DirHandle, IO::File, Digest::MD5, Compress::Zlib, File::Spec,
Data::Dumper, Data::Compare

=head1 AUTHOR

Andreas Koenig, andreas.koenig@anima.de

=head1 SEE ALSO

perl(1).

=cut
