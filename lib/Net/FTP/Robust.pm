# Copyrights 2009 by Mark Overmeer.
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 1.06.
use warnings;
use strict;

package Net::FTP::Robust;
use vars '$VERSION';
$VERSION = '0.01';


use Log::Report 'net-ftp-robust', syntax => 'SHORT';
use Net::FTP;
use Time::HiRes qw/gettimeofday tv_interval/;

use Data::Dumper;

sub size_short($);
use constant
  { GB => 1024 * 1024 * 1024
  , MB => 1024 * 1024
  , kB => 1024
  };


sub new() { my $class = shift; (bless {}, $class)->init( {@_} ) }

sub init($)
{   my ($self, $args) = @_;

    # delete all my own options from the %$args
    $self->{login_attempts}
       = defined $args->{login_attempts} ? delete $args->{login_attempts} : 10;

    # probably, some people will attempt lowercased 'host'
    $args->{Host}         ||= delete $args->{host};

    $self->{login_user}     = delete $args->{user}        || 'anonymous';
    $self->{login_password} = delete $args->{password}    || '-anonymous@';
    $self->{login_delay}    = delete $args->{login_delay} || 60;

    $self->{skip_names}     = delete $args->{skip_names}
       || sub { $_[2] =~ m/^\./ };  # UNIX hidden files

    $self->{ftp_opts}       = $args;

    $self;
}


sub get($$)
{   my ($self, $from, $to) = @_;
    $to       ||= '.';

    my $retries = $self->{login_attempts};
    my $success = 0;

    for(my $attempt = 1; not $success; $attempt++)
    {   info __x"connection attempt {nr}{max}"
          , nr => $attempt, max => ($retries ? " of $retries" : '')
            if $attempt != 1;

        my $ftp = Net::FTP->new( %{$self->{ftp_opts}} );
        if(!$ftp)
        {   notice __x"cannot establish contact: {err}", err => $@;
        }
        elsif(! $ftp->login($self->{login_user}, $self->{login_password}))
        {   notice __x"login failed: {msg}", msg => $ftp->message;
        }
        else
        {   $ftp->binary;

            my ($dir, $base) = $from =~ m!^(?:(.*)/)?(.+)!;
            $dir ||= '.';

            if(! $ftp->cwd($dir))
            {   notice __x"directory {dir} does not exist: {msg}"
                   , dir => $dir, msg => $ftp->message;
                $ftp->close;
            }

            my $stats   = $self->{stats}
                        = { files => 0, new_files => 0, downloaded => 0 };
            my $start   = [ gettimeofday ];
            $success    = $self->_recurse($ftp, $dir, $base, $to);
            my $elapsed = tv_interval $start;

            $success
                or notice __x"attempt {nr} unsuccessful", nr => $attempt;

            info __x"Got {new} new files, {size} in {secs}s avg {speed}/s"
              , new   => $stats->{new_files}
              , total => $stats->{files}
              , size  => size_short($stats->{downloaded})
              , secs  => sprintf("%.3s", $elapsed)
              , speed => size_short($stats->{downloaded} / $elapsed);

            $ftp->close;
        }


        my $last_attempt = $retries!=0 && $attempt >= $retries;
        last if $success || $last_attempt;

        sleep $self->{login_delay};
    }

    $success;
}

sub _recurse($$$$)
{   my ($self, $ftp, $dir, $entry, $to) = @_;

    my $full = "$dir/$entry";
    if($self->{skip_names}->($ftp, $full, $entry))
    {   trace "skipping $full";
        return 1;
    }

    if($ftp->cwd($entry))
    {   # Entering directory
        $to = File::Spec->catdir($to, $entry);
        
        -d $to || mkdir $to
            or fault __x"cannot create directory {dir}", dir => $to;

        my $success = $self->_get_directory($ftp, $full, $to);
        $ftp->cdup;
        return $success;
    }

    $self->_get_file($ftp, $dir, $entry, $to);
}

sub _get_directory($$$)
{   my ($self, $ftp, $where, $to) = @_;
    my @entries = $ftp->ls;

    trace "directory $where has ".@entries. " entries";

    foreach my $entry (@entries)
    {   my $success = $self->_recurse($ftp, $where, $entry, $to);
        $success or return 0;
    }

    1;
}

sub _get_file($$$$)
{   my ($self, $ftp, $dir, $base, $to) = @_;

    my $remote_name = "$dir/$base";
    my $local_name  = "$to/$base";
    my $local_temp  = "$to/.$base";

    my $remote_mtime = $ftp->mdtm($base) || 0;
    my $stats        = $self->{stats};
    $stats->{files}++;

    if(-e $local_name)
    {   # file already downloaded, still valid?
        if(! -f $local_name)
        {   # not downloadable
            error __x"download file {fn}, but exists as something else"
              , fn => $local_name;
        }

        my $local_mtime = (stat $to)[9];
        if($local_mtime >= $remote_mtime)
        {   trace "file $remote_name already downloaded";
            return 1;
        }

        trace "local file $local_name mtime $remote_mtime is outdated";
        # continue as if the file does not exist
    }

    my $expected_size = $ftp->size($base);
    my $got_size      = -s $local_temp || 0;
    my $to_download   = $expected_size - $got_size;

    if($got_size)
    {   # download did not complete last time
        trace "continue file $remote_name, got " . size_short($got_size)
            . " from " . size_short($expected_size)
            . ", needs " . size_short($to_download);

        $ftp->restart($got_size);
    }
    else
    {   trace "get new file $base (" . size_short($expected_size). ")";
    }

    my $start   = [ gettimeofday ];
    my $success = $ftp->get($base, $local_temp);
    my $elapsed = tv_interval $start;

    my $downloaded = ( -s $local_temp || 0) - $got_size;

    if($downloaded)
    {   info __x"{amount} in {secs}s is {speed}/s: {fn}"
         , amount => size_short($downloaded)
         , secs => sprintf("%3.3f", $elapsed)
         , speed  => size_short($downloaded/$elapsed), fn => $local_name;
        $stats->{downloaded} += $downloaded;
    }
    else
    {   notice __x"failed to get any bytes from {fn}", fn => $local_name;
    }

    if($success)
    {   # accept the downloaded file
        utime $remote_mtime, $remote_mtime, $local_temp; # only root
        unlink $local_name;                              # might exist
        unless(rename $local_temp, $local_name)
        {   fault __x"cannot rename {old} to {new}"
              , old => $local_temp, new => $local_name;
        }
        $stats->{new_files}++;
    }

    $success;
}

sub size_short($)
{   my $size = shift;
    my $name = ' B';
    ($size, $name) = ($size/1024, 'kB') if $size > 1000;
    ($size, $name) = ($size/1024, 'MB') if $size > 1000;
    ($size, $name) = ($size/1024, 'GB') if $size > 1000;

    my $format = $size >= 100 ? "%4.0f%s" : "%4.1f%s";
    sprintf $format, $size, $name;
}


1;
