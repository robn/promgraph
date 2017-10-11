package Promgraph;

# ABSTRACT: Graph server for Prometheus

use 5.020;
use warnings;
use strict;
use experimental qw(postderef);

use Plack::Request;
use Plack::Response;
use URI;
use URI::QueryParam;
use HTTP::Tiny;
use JSON::MaybeXS;
use List::AllUtils qw(part);
use Date::Format;
use Chart::Clicker;

use Sort::ByExample
  cmp => { -as => 'by_prom_label', example => [qw(node dc)], fallback => sub { shift cmp shift } };

my $PROM_BASE_URI = 'http://prometheus:9090';

my $app = sub {
  my ($env) = @_;

  my $req = Plack::Request->new($env);
  my ($start, $end, $step, $query) = map { $req->parameters($_) } qw(start end step query);

  unless ($start && $end && $step && $query) {
    return Plack::Response->new(400)->finalize;
  }

  my $u = URI->new("$PROM_BASE_URI/api/v1/query_range");
  $u->query_param(start => $start);
  $u->query_param(end   => $end);
  $u->query_param(step  => $step);
  $u->query_param(query => $query);

  # $u->query_param(query => '(100 - 100 * (node_filesystem_free{device!~"by-uuid",device!~"tmpfs"} / node_filesystem_size{device!~"by-uuid",device!~"tmpfs"})) >= 91');

  my $ua = HTTP::Tiny->new;
  my $res = $ua->get("$u");
  unless ($res->success) {
    # die "E: get failed: $res->{status} $res->{reason}\n" unless $res->{success};
    return Plack::Response->new($res->{status})->finalize;
  }

  my $promres = decode_json($res->{content});
  my $results = $promres->{data}->{result};

  my @legend;
  my %bucket;

  for my $i (0 .. $#$results) {
    my $metric = $results->[$i]->{metric};
    my $values = $results->[$i]->{values};

    $legend[$i] = join ' ', map { "$_ $metric->{$_}" } sort by_prom_label grep { !/^(?:job|instance)$/ } keys $metric->%*;

    for my $value ($values->@*) {
      my ($k, $v) = $value->@*;
      $bucket{$k}->[$i] = $v;
    }
  }

  my @xvals = sort keys %bucket;

  my @plotdata = map { my $i = $_; [ map { $bucket{$_}->[$i] } @xvals ] } (0 .. $#$results);

  my $cc = Chart::Clicker->new(
    width  => 1024,
    height => 768,
    format => 'png',
  );

  my $ds = Chart::Clicker::Data::DataSet->new(
    series => [
      map {
        Chart::Clicker::Data::Series->new(
          name   => $legend[$_],
          keys   => \@xvals,
          values => $plotdata[$_],
        )
      } (0 .. $#legend),
    ],
  );
  $cc->add_to_datasets($ds);

  $cc->padding(10);

  my $ctx = $cc->get_context('default');

  $ctx->domain_axis->format(sub { time2str('%R', shift, 'UTC' ) });

  $ctx->range_axis->label_font->family('Monaco');
  $ctx->range_axis->tick_font->family('Monaco');
  $ctx->domain_axis->tick_font->family('Monaco');
  $ctx->domain_axis->label_font->family('Monaco');

  $ctx->renderer->brush->width(2);

  $cc->legend->font->size(12);
  $cc->legend->font->family('Monaco');

  $cc->draw;
  my $png = $cc->driver->data;

  return Plack::Response->new(200, [
    'Content-Type'   => 'image/png',
    'Content-Length' => length($png),
  ], $png)->finalize;
};

sub to_app { $app }

1;
