# -*- mode: cperl -*-

use strict;
BEGIN {
    sub find_exe {
        my($exe,$path) = @_;
        my($dir);
        #warn "in find_exe exe[$exe] path[@$path]";
        for $dir (@$path) {
            my $abs = File::Spec->catfile($dir,$exe);
            require ExtUtils::MakeMaker;
            if (($abs = MM->maybe_command($abs))) {
                return $abs;
            }
        }
    }
    my $found_prereq = 0;
    unless ($found_prereq) {
        $found_prereq = eval { require Digest::SHA; 1 };
    }
    unless ($found_prereq) {
        $found_prereq = eval { require Digest::SHA1; 1 };
    }
    unless ($found_prereq) {
        $found_prereq = eval { require Digest::SHA::PurePerl; 1 };
    }
    my $exit_message = "";
    unless ($found_prereq) {
        $exit_message = "None of the supported SHA modules (Digest::SHA,Digest::SHA1,Digest::SHA::PurePerl) found";
    }
    unless ($exit_message) {
        if (!-f 'SIGNATURE') {
            $exit_message = "No signature file";
        }
    }
    unless ($exit_message) {
        if (!-s 'SIGNATURE') {
            $exit_message = "Empty signature file";
        }
    }
    unless ($exit_message) {
        if (eval { require Module::Signature; 1 }) {
            my $min = "0.66";
            if ($Module::Signature::VERSION < $min-0.0000001) {
                $exit_message = "Signature testing disabled for Module::Signature versions < $min";
            }
        } else {
            $exit_message = "No Module::Signature found [INC = @INC]";
        }
    }
    unless ($exit_message) {
        if (!eval { require Socket; Socket::inet_aton('pool.sks-keyservers.net') }) {
            $exit_message = "Cannot connect to the keyserver";
        }
    }
    unless ($exit_message) {
        require Config;
        my(@path) = split /$Config::Config{'path_sep'}/, $ENV{'PATH'};
        if (!find_exe('gpg',\@path)) {
            $exit_message = "Signature testing disabled without gpg program available";
        }
    }
    if ($exit_message) {
        $|=1;
        print "1..0 # SKIP $exit_message\n";
        eval "require POSIX; 1" and POSIX::_exit(0);
    }
}

print "1..1\n";

(Module::Signature::verify() == Module::Signature::SIGNATURE_OK())
    or print "not ";
print "ok 1 # Valid signature\n";

# Local Variables:
# mode: cperl
# cperl-indent-level: 4
# End:
