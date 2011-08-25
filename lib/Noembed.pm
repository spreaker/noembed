package Noembed;

use Module::Find ();
use Class::Load;
use Plack::Request;
use Text::MicroTemplate::File;
use File::ShareDir qw/dist_dir/;
use JSON;

use parent 'Plack::Component';

our $VERSION = "0.01";

sub prepare_app {
  my $self = shift;

  my $template = Text::MicroTemplate::File->new(
    include_path => [template_dir()],
    use_cache    => 2
  );

  $self->{render} = sub { $template->render_file(@_) };
  $self->{providers} = [];
  $self->{locks} = {};

  $self->register_provider($_) for Module::Find::findsubmod("Noembed::Source");
}

sub call {
  my ($self, $env) = @_;

  my $req = Plack::Request->new($env);
  return error("url parameter is required") unless $req->parameters->{url};
  return $self->handle_url($req);
}

sub template_dir {
  return share_dir() . "/templates";
}

sub style_dir {
  return share_dir() . "/styles";
}

# yuck.
sub share_dir {
  my @try = ("share", "../share");
  for (@try) {
    return $_ if -e "$_/templates/Twitter.html";
  }
  dist_dir "Noembed";
}

sub handle_url {
  my ($self, $req) = @_;

  return sub {
    my $respond = shift;

    my $url = $req->parameters->{url};
    my $working = $self->has_lock($url);

    $self->add_lock($url, $respond);

    return if $working;
  
    for my $provider (@{$self->{providers}}) {
      if ($provider->matches($url)) {
        $provider->download($req, sub {
          my ($body, $error) = @_;
          $self->end_lock($url, $error ? error($error) : json_res($body));
        });
        return;
      }
    }

    $self->end_lock($url, error("no matching providers found for $url"));
  }
}

sub json_res {
  my $body = shift;

  [
    200,
    [
      'Content-Type', 'text/javascript; charset=utf-8',
      'Content-Length', length $body
    ],
    [$body]
  ];
}

sub error {
  my $message = shift;
  my $body = encode_json {error => ($message || "unknown error")};
  json_res $body;
}

sub register_provider {
  my ($self, $class) = @_;

  if ($class !~ /^Noembed::Source::/ and $class !~ s/^\+//) {
    $class = "Noembed::Source::$class";
  }

  my ($loaded, $error) = Class::Load::try_load_class($class);
  if ($loaded) {
    my $provider = $class->new(render => $self->{render});
    push @{ $self->{providers} }, $provider;
  }
  else {
    warn "Could not load provider $class: $error";
  }
}

sub add_lock {
  my ($self, $url, $respond) = @_;

  $self->{locks}{$url} ||= [];
  push @{$self->{locks}{$url}}, $respond;
}

sub end_lock {
  my ($self, $url, $res) = @_;
  my $locks = delete $self->{locks}{$url};
  $_->([@$res]) for @$locks;
}

sub has_lock {
  my ($self, $url) = @_;
  exists $self->{locks}{$url} and @{$self->{locks}{$url}};
}

1;
