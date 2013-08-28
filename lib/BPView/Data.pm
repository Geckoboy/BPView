#!/usr/bin/perl -w
#
# COPYRIGHT:
#
# This software is Copyright (c) 2013 by ovido
#                             <sales@ovido.at>
#
# This file is part of Business Process View (BPView).
#
# (Except where explicitly superseded by other copyright notices)
# BPView is free software: you can redistribute it and/or modify it 
# under the terms of the GNU General Public License as published by 
# the Free Software Foundation, either version 3 of the License, or 
# any later version.
#
# BPView is distributed in the hope that it will be useful, but WITHOUT 
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or 
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License 
# for more details.
#
# You should have received a copy of the GNU General Public License
# along with BPView.  
# If not, see <http://www.gnu.org/licenses/>.


package BPView::Data;

BEGIN {
    $VERSION = '1.200'; # Don't forget to set version and release
}  						# date in POD below!

use strict;
use warnings;
use YAML::Syck;
use Carp;
use File::Spec;
use JSON::PP;

# required for BP-Addon
use LWP::UserAgent;
use HTTP::Request;
use HTTP::Request::Common qw(POST);

# for debugging only
#use Data::Dumper;


=head1 NAME

  BPView::Data - Connect to data backend

=head1 SYNOPSIS

  use BPView::Data;
  my $details = BPView::Data->new(
  		provider	=> 'ido',
  		provdata	=> $provdata,
  		views		=> $views,
  	 );
  $json = $details->get_status();

=head1 DESCRIPTION

This module fetches business process data from various backends like
IDOutils and BPaddon-API.

=head1 CONSTRUCTOR

=head2 new ( [ARGS] )

Creates an BPView::Data object. <new> takes at least the provider and 
provdata. Arguments are in key-value pairs.
See L<EXAMPLES> for more complex variants.

=over 4

=item provider

name of datasource provider (supported: ido|bpaddon)

=item provdata

provider specific connection data

IDO:
  host: hostname (e.g. localhost)
  port: port (e.g. 3306)
  type: mysql|pgsql
  database: database name (e.g. icinga)
  username: database user (e.g. icinga)
  password: database password (e.g. icinga)
  prefix: database prefix (e.g. icinga_)
  
BPAddon:
  cgi_url: url to BPAddon-CGIs (e.g. https://localhost/nagiosbp/cgi-bin)
  conf: BPAddon config file name (e.g. nagios-bp)
  username: CGI username (if url is protected)
  password: CGI password (if url is protected)

=item views

hash reference of view config
required for BPView::Data->get_status()

=item bp

name of business process to query service details from
required for BPView::Data->get_details()

=cut


sub new {
  my $invocant	= shift;
  my $class 	= ref($invocant) || $invocant;
  my %options	= @_;
    
  my $self 		= {
  	"views"		=> undef,	# views object (hash)
  	"bp"		=> undef,	# name of business process
  	"provider"	=> "ido",	# provider (ido | mk-livestatus)
  	"provdata"	=> undef,	# provider details like hostname, username,... 
  };
  
  for my $key (keys %options){
  	if (exists $self->{ $key }){
  	  $self->{ $key } = $options{ $key };
  	}else{
  	  croak "Unknown option: $key";
  	}
  }
  
  # parameter validation
  # TODO!
  # don't use views and bps together
  if (defined $self->{ 'views' } && defined $self->{ 'bp' }){
  	croak ("Can't use views and bp together!");
  }
  
  chomp $self->{ 'bp' } if defined $self->{ 'bp' };
  
  bless $self, $class;
  return $self;
}


#----------------------------------------------------------------

=head1 METHODS	

=head2 get_status

 get_status ( 'views' => $views )

Connects to backend and queries status of business process.
Business process must be available in Icinga/Nagios!
Returns JSON data.

  my $json = $get_status( 'views' => $views );
  
$VAR1 = {
   "production" : {
       "mail" : {
          "lb" : {
             "bpname" : "production-mail-lb",          	
              "state" : "0"         	
           }
       }
    }
 }                               	

=cut

sub get_status {
	
  my $self		= shift;
  my %options 	= @_;
  
  for my $key (keys %options){
  	if (exists $self->{ $key }){
  	  $self->{ $key } = $options{ $key };
  	}else{
  	  croak "Unknown option: $key";
  	}
  }
  
  my $service_names;
  # go through views hash
  # name required for BP is -> environment-group-product
  foreach my $environment (keys %{ $self->{ 'views' } }){
  	foreach my $groups (keys %{ $self->{ 'views' }{ $environment } }){
      foreach my $product (keys %{ $self->{ 'views' }{ $environment }{ $groups } }){
      	my $bp = $environment . "-" . $groups . "-" . $product;
      	# replace non-chars with _ except -, due to Nagios limitations
        #$bp =~ s/[^a-zA-Z0-9-]+/_/g;
        $bp =~ s/[^a-zA-Z0-9-]/_/g;
  	  	push @{ $service_names }, $bp;
  	  }
  	}
  }
  
  my $return = undef;
  # fetch data from Icinga/Nagios
  if ($self->{'provider'} eq "ido"){
  	
  	# construct SQL query
  	my $sql = $self->_query_ido( $service_names );
  	# get results
  	my $result = $self->_get_ido( $sql );
  	
    # verify if status is given for all products
    # note: if product is missing in Icinga/Nagios there's no state for it
    # we use status code 99 for this (0-3 are reserved as Nagios plugin exit codes)
    # this is ugly - can it be done better?
    foreach my $environment (keys %{ $self->{ 'views' } }){
  	  foreach my $groups (keys %{ $self->{ 'views' }{ $environment } }){
  	    foreach my $product (keys %{ $self->{ 'views' }{ $environment }{ $groups } }){
  	      # see _get_ido for example output!
  	      my $service = $environment . "-" . $groups . "-" . $product;
  	      # replace non-chars with _ except -, due to Nagios limitations
          #$service =~ s/[^a-zA-Z0-9-]+/_/g;
          $service =~ s/[^a-zA-Z0-9-]/_/g;
  	  	  if (defined ($result->{ $service }{ 'state' })){
  	  	  	# found status in IDO database
	      	$self->{ 'views' }{ $environment }{ $groups }{ $product }{ 'state' } = $result->{ $service }{ 'state' };
	      }else{
	      	# didn't found status in IDO database
	      	$self->{ 'views' }{ $environment }{ $groups }{ $product }{ 'state' } = 99;
	      }
	      # return also business process name
	      $self->{ 'views' }{ $environment }{ $groups }{ $product }{ 'bpname' } = $service;
  	    }
  	  }
    }
    
  	
  }elsif ($self->{'provider'} eq "mk-livestatus"){
  	# TODO: later!
  	
  }else{
  	carp ("Unsupported provider: $self->{'provider'}!");
  }
  
  
  # produce json output
  my $json = JSON::PP->new->pretty;
  $json = $json->sort_by(sub { $JSON::PP::a cmp $JSON::PP::b })->encode($self->{ 'views' });
  
  return $json;
  
}


#----------------------------------------------------------------

=head1 METHODS	

=head2 get_details

 get_details ( 'bp' => $business_process )

Connects to BPAddon API and fetches service status details for all
services of this business process.
Returns JSON data.

  my $json = $get_details( 'bp' => $business_process );
  
$VAR1 = {
   "priority_definitions" : {},
   "business_process" : {
      "hardstate" : "OK",
      "components" : [
         {
            "hardstate" : "OK",
            "plugin_output" : "HTTP OK: HTTP/1.1 302 Moved Temporarily - 351 bytes in 0.187 second response time",
            "service" : "HTTPS Check",
            "host" : "localhost"
         }
      ],
      "bp_id" : "production-mail-lb",
      "display_name" : "Loadbalancer",
      "display_prio" : "0"
   },
   "json_created" : "2013-07-23 15:41:19"
}

=cut

sub get_details {
	
  my $self		= shift;
  my %options 	= @_;
  
  for my $key (keys %options){
  	if (exists $self->{ $key }){
  	  $self->{ $key } = $options{ $key };
  	}else{
  	  croak "Unknown option: $key";
  	}
  }
  
  # we only support business process addon api queries at the moment
  if (! $self->{ 'provider' } eq "bpaddon" ){
  	croak "Unsupported provider: " . $self->{ 'provider' };
  }
  
  # set default timeout if missing
  if (! defined $self->{ 'provdata' }{ 'timeout' }){ $self->{ 'provdata' }{ 'timeout' } = 10; };
   
  # connect to BP Addon API
  
  # construct URL
  #https://localhost/nagiosbp/cgi-bin/nagios-bp.cgi?detail=production-mail-lb&conf=bpview&outformat=json
  my $url = $self->{ 'provdata' }{ 'cgi_url' } . "/nagios-bp.cgi?detail=" . $self->{ 'bp' } . "&conf=" . $self->{ 'provdata' }{ 'conf' } . "&outformat=json";
  
  # connect to API
  my $ra = LWP::UserAgent->new();
  $ra->timeout( $self->{ 'provdata' }{ 'timeout' } );
  
  # skip SSL certificate verification
  if (LWP::UserAgent->VERSION >= 6.0){
    $ra->ssl_opts(verify_hostname => 0, SSL_verify_mode => 0x00);	# disable SSL cert verification
  }
  
  my $rr = HTTP::Request->new(GET => $url);
  
  # Authentication
  if (defined $self->{ 'provdata' }{ 'username' }){
    $rr->authorization_basic($self->{ 'provdata' }{ 'username' }, $self->{ 'provdata' }{ 'password' });
  }
  
  my $re = $ra->request($rr);
  if (! $re->is_success){	
    croak ("Can't connect to BP-Addon API: " . $re->error_as_HTML);
  }
  
  my $result = $re->content;
  my $json = JSON::PP->new->pretty;
  my $decoded = $json->decode($result) or croak ("JSON data provided from BP-Addon are invalid!");
  
  my $return = {};
  
  # go through hash
  # we only need host, service and hardstate
  for (my $i=0;$i<scalar @{ $decoded->{ 'business_process' }{ 'components' } };$i++){
  	my $hostname  = $decoded->{ 'business_process' }{ 'components' }[$i]{ 'host' };
  	my $service   = $decoded->{ 'business_process' }{ 'components' }[$i]{ 'service' };
  	my $output    = $decoded->{ 'business_process' }{ 'components' }[$i]{ 'plugin_output' };
  	my $hardstate = $decoded->{ 'business_process' }{ 'components' }[$i]{ 'hardstate' };
  	$return->{ $hostname }{ $service }{ 'output' } = $output;
  	$return->{ $hostname }{ $service }{ 'hardstate' } = $hardstate;
  }
  
  # produce json output
  $json = JSON::PP->new->pretty;
  $json = $json->sort_by(sub { $JSON::PP::a cmp $JSON::PP::b })->encode($return);
  
  return $json;
  
}


#----------------------------------------------------------------

# internal methods
##################

# construct SQL query for IDOutils
sub _query_ido {
	
  my $self			= shift;
  my $service_names	= shift or croak ("Missing service_names!");
  
  # construct SQL query
  my $sql = "SELECT name2 AS service, current_state AS state FROM " . $self->{'provdata'}{'prefix'} . "objects, " . $self->{'provdata'}{'prefix'} . "servicestatus ";
    $sql .= "WHERE object_id = service_object_id AND is_active = 1 AND name2 IN (";
  # go trough service_names array
  for (my $i=0;$i<scalar @{ $service_names };$i++){
  	$sql .= "'" . $service_names->[$i] . "', ";
  }
  # remove trailing ', '
  chop $sql;
  chop $sql; 
  $sql .= ") ORDER BY name1";
  
  return $sql;
  
}


#----------------------------------------------------------------

# get service status from IDOutils
sub _get_ido {
	
  my $self	= shift;
  my $sql	= shift or croak ("Missing SQL query!");
  
  my $result;
  
  my $dsn = undef;
  # database driver
  if ($self->{'provdata'}{'type'} eq "mysql"){
    use DBI;	  # MySQL
  	$dsn = "DBI:mysql:database=$self->{'provdata'}{'database'};host=$self->{'provdata'}{'host'};port=$self->{'provdata'}{'port'}";
  }elsif ($self->{'provdata'}{'type'} eq "pgsql"){
	use DBD::Pg;  # PostgreSQL
  	$dsn = "DBI:Pg:dbname=$self->{'provdata'}{'database'};host=$self->{'provdata'}{'host'};port=$self->{'provdata'}{'port'}";
  }else{
  	croak "Unsupported database type: $self->{'provdata'}{'type'}";
  }
  
  # connect to database
  my $dbh   = eval { DBI->connect_cached($dsn, $self->{'provdata'}{'username'}, $self->{'provdata'}{'password'}) };
  if ($DBI::errstr){
  	croak "$DBI::errstr: $@";
  }
  my $query = eval { $dbh->prepare( $sql ) };
  eval { $query->execute };
  if ($DBI::errstr){
  	croak "$DBI::errstr: $@";
  }
  
  # prepare return
  $result = $query->fetchall_hashref('service');
  
  # example output:
  # $VAR1 = {
  #        'production-mail-zarafa' => {
  #                                      'service' => 'production-mail-zarafa',
  #                                      'state' => '0'
  #                                    },
  
  
  # disconnect from database
  #$dbh->disconnect;
  
  return $result;
  
}

1;


=head1 EXAMPLES

Get business process status from IDO backend

  use BPView::Data;
  my $dashboard = BPView::Data->new(
  	 views		=> $views,
   	 provider	=> "ido",
   	 provdata	=> $provdata,
  );	
  $json = $dashboard->get_status();
    
    
Get business process details from BPAddon API for business process
production-mail-lb

  use BPView::Data;
  my $details = BPView::Data->new(
  	provider	=> 'bpaddon',
  	provdata	=> $provdata,
  	bp			=> "production-mail-lb",
  );
  $json = $details->get_details();


=head1 SEE ALSO

See BPView::Config for reading and parsing config files.

=head1 AUTHOR

Rene Koch, E<lt>r.koch@ovido.atE<gt>

=head1 VERSION

Version 1.200  (August 28 2013))

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2013 by ovido gmbh

This library is free software; you can redistribute it and/or modify
it under the same terms as BPView itself.

=cut
