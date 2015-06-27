#! perl

=pod

=head1 NAME

mup - perl interface to mu

=head1 SYNOPSIS

  use mup;

  my $mu = mup->new();
  my $results = $mu->search({ 'subject' => 'something'});
  print $results->count." results for subject:something\n";

=head1 DESCRIPTION

This is a perl interface to mu, the Maildir search-and-destroy system.

=cut

package mup;
use strict;
use warnings;
require Exporter;
use base qw(Exporter);
use vars qw($VERSION);
use Data::SExpression;
use IPC::Open2;
use IO::Select;

$VERSION = '0.1.0';

sub _init {
    my $self = shift(@_);
    $self->{'opts'} ||= (@_ && ref($_[0]))? $_[0]: { @_ };
    my($mu_out,$mu_in);
    $self->{'_dead'} = 0;
    $self->{'pid'} = open2($mu_out,$mu_in,'mu','server');
    $self->{'out'} = $mu_out;
    $self->{'in'} = $mu_in;
    $self->{'tout'} = $self->_opt('timeout',1);
    $self->{'select'} = IO::Select->new();
    $self->{'select'}->add($mu_out);
    $self->{'inbuf'} = '';
    $self->{'dying'} = 0;
    $self->{'ds'} =
        Data::SExpression->new({fold_alists=>1,use_symbol_class=>1});
    my $junk = $self->_read();
    warn("mup: _init junk: $junk\n") if $self->verbose;
}

sub _opt {
    my($self,@nv) = @_;
    return undef unless @nv;
    my $nm = shift(@nv);
    my($val) = @nv;
    $val = $self->{'opts'}->{$nm} if exists($self->{'opts'}->{$nm});
    return $val;
}

sub verbose { return shift->_opt('verbose'); }

sub _cleanup {
    my($self) = @_;
    if ($self->{'pid'}) {
        warn("mup: reaping mu server pid ".$self->{pid}) if $self->verbose;
        waitpid($self->{'pid'},0);
        $self->{'pid'} = undef;
    }
    if ($self->{'inbuf'}) {
        warn("mup: restart pitching inbuf: |".$self->{inbuf}."|\n")
            if $self->verbose;
        $self->{'inbuf'} = '';
    }
}

sub restart {
    my($self) = @_;
    $self->_cleanup();
    $self->_init();
}

sub reset {
    my($self) = @_;
    $self->_reset_parser();
    return $self;
}

sub _read {
    my($self) = @_;
    my $restart_needed = 0;
    my @ready = $self->{'select'}->can_read($self->{'tout'});
    while (@ready && !$restart_needed) {
        foreach my $handle (@ready) {
            my $buf = '';
            my $nread = $handle->sysread($buf,1024);
            if (!$nread) {
                warn("mup: mu server died - restarting") if $self->verbose();
                $restart_needed = 1;
            } else {
                $self->{'inbuf'} .= $buf;
            }
        }
        @ready = $self->{'select'}->can_read($self->{'tout'})
            unless $restart_needed;
    }
    my $result = $self->{'inbuf'};
    $self->_cleanup() if ($self->{'dying'} || $restart_needed);
    $self->_init() if $restart_needed;
    return $result;
}

sub _start_block {
}

sub _end_block {
}

sub _reset_parser {
}

sub _in_block {
}

sub _append_block {
}

sub _parse1 {
    my($self) = @_;
    my $raw = $self->{'inbuf'};
    return undef unless $raw;
    my($xcount,$raw) = ($1,$2) if $raw =~ /^\376([\da-f]+)\377(.*)$/;
    my $count = hex($xcount);
    my $sexp = substr($raw,0,$count);
    $self->{'inbuf'} = substr($raw,$count);
    my @results = ();
    $self->_reset_parser();
    my $data = $self->{'ds'}->read($sexp);
    my $result = $data;
    if (ref($data) eq 'ARRAY') {
        $result = {};
        while (scalar(@$data)) {
            my($key,$val) = splice(@$data,0,2);
            $result->{$key} = $val;
        }
    }
    return $result;
}

sub _parse {
    my($self) = @_;
    my @results = ();
    while (defined(my $thing = $self->_parse1())) {
        push(@results,$thing);
    }
    return @results;
}

sub new {
    my $proto = shift(@_);
    my $class = ref($proto) || $proto;
    $proto = {} unless ref($proto);
    bless($proto,$class);
    $proto->_init(@_);
    return $proto;
}

sub finish {
    my($self) = @_;
    if ($self->{'pid'}) {
        $self->{'dying'} = 1;
        $self->{'in'}->write("\n"); # will cause EOF eventually
        $self->{'in'}->flush();
        $self->_read();
    }
}

sub DESTROY {
}

sub _refify {
    my $href = $_[0] if @_ && ref($_[0]) eq 'HASH';
    $href ||= { @_ };
}

sub _quote {
    my($val) = @_;
}

sub _argify {
    my $href = _argify(@_);
    join(' ', map { "$_:"._quote($href->{$_}) } keys(%$href));
}

sub _execute {
    my($self,$cmd,@args) = @_;
    my $args = _argify($cmd,@args);
    my $cmdstr = "cmd:$cmd $args";
    warn("mup: <<< $cmdstr\n") if $self->verbose;
    $self->{'inbuf'} = '';
    $self->{'in'}->write("$cmdstr\n");
    $self->{'in'}->flush();
    $self->_read();
    return $self->_parse();
}

#sub AUTOLOAD {
#    my $self = shift(@_);
#    my $name = $AUTOLOAD;
#    $name =~ s/^mup:://;
#    my $cmd = $name;
#    $cmd =~ s/[_\s]+/-/gs;
#    warn("mup: AUTOLOAD: $name -> $cmd @_\n") if $self->_verbose();
#    return $self->_execute($cmd,@_)
#}

sub add { shift->_execute('add',@_); }

sub contacts { shift->_execute('contacts',@_); }

sub extract { shift->_execute('extract',@_); }

sub find { shift->_execute('find',@_); }

sub index { shift->_execute('index',@_); }

sub move { shift->_execute('move',@_); }

sub ping { shift->_execute('ping',@_); }

sub mkdir { shift->_execute('mkdir',@_); }

sub remove { shift->_execute('remove',@_); }

sub view { shift->_execute('view',@_); }

1;

__END__

=pod

=head1 SEE ALSO

We live in splendid isolation.

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
