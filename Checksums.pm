package CPAN::Checksums;

use strict;
use vars qw($VERSION $CAUTION @ISA @EXPORT_OK);

require Exporter;

@ISA = qw(Exporter);
@EXPORT_OK = qw(updatedir);
$VERSION = sprintf "%d.%03d", q$Revision: 1.6 $ =~ /(\d+)\.(\d+)/;
$CAUTION ||= 0;

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
    next if -l $abs;

    #
    # SHORTNAME offers an 8.3 name, probably not needed but it was
    # always there,,,
    #
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
      if ($counter++ > 1000){ # avoid endless loops and accept the buggy choice
        warn "Warning: long loop on shortname[$shortname]de[$de]";
        last;
      }
    }
    $dref->{$de}->{shortname} = $shortname;
    $shortnameseen{$shortname} = undef; # for exists check good enough

    #
    # STAT facts
    #
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
# Below is the stub of documentation for your module. You better edit it!

=head1 NAME

CPAN::Checksums - Write a CHECKSUMS file for a directory as on CPAN

=head1 SYNOPSIS

  use CPAN::Checksums qw(updatedir);
  my $success = updatedir($directory);

=head1 DESCRIPTION

updatedir takes a directory name as argument and writes a CHECKSUMS
file in that directory unless a previously written CHECKSUMS file is
there that is still valid. Returns 2 if a new CHECKSUMS file has been
written, 1 if a valid CHECKSUMS file is already there, otherwise dies.

Setting the global variable $CAUTION causes updatedir to report
changes of files in the attributes C<size>, C<mtime>, C<md5>, or
C<md5-ungz> to STDERR.

=head1 AUTHOR

Andreas Koenig, andreas.koenig@anima.de

=head1 SEE ALSO

perl(1).

=cut
