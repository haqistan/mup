#! perl

=pod

=head1 NAME

mup - perl interface to mu

=head1 SYNOPSIS

  use mup;

  my $mu = mup->new();

  my @results = $mu->find({ subject => 'something'});
  print scalar(@results)." results for subject:something\n";

=head1 DESCRIPTION

This is a perl interface to mu, the Maildir search-and-destroy system.
It presents the same API as described in the L<mu-server(1)> man page.
In fact it works by communicating with a C<mu server> process, just
like the C<mu4e> emacs interface to mu does.

=head1 METHODS

=cut

package mup;
use strict;
use warnings;
use vars qw($VERSION);
use Data::SExpression;
use IPC::Open2;
use IO::Select;
use Time::HiRes;
use Moose;
use namespace::clean;

$VERSION = '0.1.0';

has 'dying' => (
    is => 'rw',
    isa => 'Bool',
    required => 1,
    default => 0
);
has 'dead' => (
    is => 'rw',
    isa => 'Bool',
    required => 1,
    default => 0
);
has 'pid' => (
    is => 'rw',
    isa => 'Int',
    required => 1,
    default => 0
);
has 'in' => (
    is => 'rw'
);
has 'out' => (
    is => 'rw'
);
has 'tout' => (
    is => 'rw',
    isa => 'Num',
    default => 0.5,
    required => 1,
);
has 'orig_tout' => (
    is => 'rw',
    isa => 'Num',
    default => 0.5,
    required => 1,
);
has 'select' => (
    is => 'ro',
    isa => 'Object',
    default => sub { IO::Select->new() },
    required => 1,
);
has 'inbuf' => (
    is => 'rw',
    isa => 'Str',
    default => '',
    required => 1,
);
has 'ds' => (
    is => 'ro',
    isa => 'Object',
    default => sub {
        Data::SExpression->new({fold_alists=>1,use_symbol_class=>1})
    },
    required => 1,
);
has 'mu_bin' => (
    is => 'rw',
    isa => 'Str',
    default => 'mu',
    required => 1,
);
has 'mu_server_cmd' => (
    is => 'rw',
    isa => 'Str',
    default => 'server',
    required => 1,
);
has 'verbose' => (
    is => 'rw',
    isa => 'Bool',
    default => 0,
    required => 1,
);
has 'bufsiz' => (
    is => 'rw',
    isa => 'Int',
    default => 2048,
    required => 1,
);

sub _init {
    my $self = shift(@_);
    my($in,$out);
    my($bin,$cmd) = ($self->mu_bin,$self->mu_server_cmd);
    my $pid = open2($out,$in,$bin,$cmd);
    $self->orig_tout($self->tout);
    $self->pid($pid);
    $self->out($out);
    $self->in($in);
    $self->select->add($out);
    my $junk = $self->_read();
    warn("mup: _init junk: $junk\n") if $self->verbose;
    return $self;
}

sub BUILD { shift->_init(); }

sub _cleanup {
    my($self) = @_;
    if ($self->pid) {
        warn("mup: reaping mu server pid ".$self->pid."\n") if $self->verbose;
        waitpid($self->pid,0);
        $self->pid(0);
    }
    if ($self->inbuf) {
        warn("mup: restart pitching inbuf: |".$self->inbuf."|\n")
            if $self->verbose;
        $self->inbuf('');
    }
}

sub restart {
    my($self) = @_;
    $self->_cleanup();
}

sub reset {
    my($self) = @_;
    $self->_reset_parser();
    return $self;
}

sub _read {
    my($self) = @_;
    my $restart_needed = 0;
    my @ready = $self->select->can_read($self->tout);
    while (@ready && !$restart_needed) {
        foreach my $handle (@ready) {
            my $buf = '';
            my $nread = $handle->sysread($buf,$self->bufsiz);
            if (!$nread) {
                warn("mup: mu server died - restarting") if $self->verbose();
                $restart_needed = 1;
            } else {
                $self->inbuf($self->inbuf . $buf);
                warn("mup: <<< |$buf|\n") if $self->verbose;
            }
        }
        @ready = $self->select->can_read($self->tout)
            unless $restart_needed;
    }
    my $result = $self->inbuf;
    $self->_cleanup() if ($self->dying || $restart_needed);
    $self->_init() if $restart_needed && !$self->dying;
    return $result;
}

sub _reset_parser {
}

sub _parse {
    my($self) = @_;
    my $raw = $self->inbuf;
    return undef unless $raw;
    my($xcount,$left) = ($1,$2) if $raw =~ /^\376([\da-f]+)\377(.*)$/s;
    my $count = hex($xcount);
    my $nleft = length($left);
    warn("mup: count=$count length=$nleft: |$left|\n")
        if $self->verbose;
    chomp(my $sexp = substr($left,0,$count));
    $self->inbuf(substr($left,$count));
    my $data = $self->ds->read($sexp);
    return undef unless defined($data);
    warn("mup: parsed sexp: $data\n") if $self->verbose;
    return $self->_hashify($data);
}

sub _hashify {
    my($self,$thing) = @_;
    my $rthing = ref($thing);
    my $result = $thing;
    warn("mup: rthing=$rthing: $thing\n") if $self->verbose;
    return $result unless $rthing;
    if ($rthing eq 'Data::SExpression::Symbol') {
        if ($thing eq 'nil') {
            $result = undef;
        } elsif ($thing eq 't') {
            $result = 1;
        }
    } elsif ($rthing eq 'ARRAY') {
        $result = {};
        while (scalar(@$thing)) {
            my($key,$val) = splice(@$thing,0,2);
            $key = "$1" if "$key" =~ /^:(.*)$/;
            warn("mup: ARRAY key=$key val=(".ref($val).") |$val|\n")
                if $self->verbose;
            $result->{$key} = $self->_hashify($val);
        }
    } elsif ($rthing eq 'HASH') {
        $result = {};
        foreach my $key (keys(%$thing)) {
            my $val = $thing->{$key};
            $key = "$1" if "$key" =~ /^:(.*)$/;
            warn("mup: HASH key=$key val=(".ref($val).") |$val|\n")
                if $self->verbose;
            $result->{$key} = $self->_hashify($val);
        }
    }
    return $result;
}

=pod

=head2 new

Construct a new interface object; this will cause a C<mu server>
process to be started.

=cut


=pod

=head2 finish

Shut down the mu server.

=cut

sub finish {
    my($self) = @_;
    if ($self->pid) {
        $self->dying(1);
        $self->_send("cmd:quit");
        my $junk = $self->_read();
        warn("mup: trailing garbage in finish: |$junk|\n") if $self->verbose;
    }
}

sub DEMOLISH { shift->finish(); }

sub _refify {
    return ((@_ == 1) && (ref($_[0]) eq 'HASH')) ? $_[0] : { @_ };
}

sub _quote {
    my($val) = @_;
    $val = qq|"$val"| if (!ref($val) && $val =~ /\s/);
    $val;
}

sub _argify {
    my $self = shift(@_);
    my $href = _refify(@_);
    if (exists($href->{'timeout'})) {
        $self->tout($href->{'timeout'});
        warn("mup: tout ".$self->orig_tout." => ".$self->tout."\n")
            if $self->verbose;
        delete($href->{'timeout'});
    }
    return join(' ', map { "$_:"._quote($href->{$_}) } keys(%$href));
}

sub _send {
    my($self,$str) = @_;
    $self->in->write("$str\n");
    $self->in->flush();
    return $self;
}

sub _execute {
    my($self,$cmd,@args) = @_;
    my $args = $self->_argify(@args);
    my $cmdstr = "cmd:$cmd $args";
    warn("mup: >>> $cmdstr\n") if $self->verbose;
    if ($self->inbuf) {
        my $junk = $self->inbuf;
        warn("mup: pitching |$junk|\n") if $self->verbose;
    }
    $self->inbuf('');
    $self->_send($cmdstr);
    $self->_read();
    $self->tout($self->orig_tout);
    return $self->_parse();
}

=pod

=head2 add

Add a document to the database.

=cut

sub add { shift->_execute('add',@_); }



=pod

=head2 contacts

Search contacts.

=cut

sub contacts { shift->_execute('contacts',@_); }



=pod

=head2 extract

=cut

sub extract { shift->_execute('extract',@_); }



=pod

=head2 find

Blah.

=cut

sub find { shift->_execute('find',@_); }



=pod

=head2 index

Blah.

=cut

sub index { shift->_execute('index',@_); }



=pod

=head2 move

Blah.

=cut

sub move { shift->_execute('move',@_); }



=pod

=head2 ping

Blah.

=cut

sub ping { shift->_execute('ping',@_); }



=pod

=head2 mkdir

Blah.

=cut

sub mkdir { shift->_execute('mkdir',@_); }



=pod

=head2 remove

Blah.

=cut

sub remove { shift->_execute('remove',@_); }



=pod

=head2 view

Blah.

=cut

sub view { shift->_execute('view',@_); }

########################################################################

no Moose;
__PACKAGE__->meta->make_immutable;

1;

__END__

=pod

=head1 SEE ALSO

L<mu(1)>, L<mu-server(1)>

=head1 AUTHOR

attila <attila@stalphonsos.com>

=head1 LICENSE

Copyright (C) 2015 by attila <attila@stalphonsos.com>

Permission to use, copy, modify, and distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL
WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE
AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL
DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR
PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
PERFORMANCE OF THIS SOFTWARE.

=cut

##
# Local variables:
# mode: perl
# tab-width: 4
# perl-indent-level: 4
# cperl-indent-level: 4
# cperl-continued-statement-offset: 4
# indent-tabs-mode: nil
# comment-column: 40
# End:
##
