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
    $VERSION = '1.400'; # Don't forget to set version and release
}  						# date in POD below!

use strict;
use warnings;
use YAML::Syck;
use Carp;
use File::Spec;
use File::stat;
use JSON::PP;
use Tie::IxHash;

# for debugging only
use Data::Dumper;


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
IDOutils and mk-livestatus.

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
  	"config"	=> undef,
  	"bps"		=> undef,
  	"filter"	=> undef,	# filter states (e.g. don't display bps with state ok)
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
  	foreach my $topic (keys %{ $self->{ 'views' }{ $environment } }){
		next if ($topic =~ m/^__display*/);
		foreach my $product (keys %{ $self->{ 'views' }{ $environment }{ $topic } }){
			my $bp = $environment . "-" . $topic . "-" . $product;
			# replace non-chars with _ except -, due to Nagios limitations
			#$bp =~ s/[^a-zA-Z0-9-]+/_/g;
			$bp =~ s/[^a-zA-Z0-9-]/_/g;
			push @{ $service_names }, $bp;
		}
  	}
  }
  
  my $result = undef;
  # fetch data from Icinga/Nagios
  if ($self->{'provider'} eq "ido"){
  	
  	# construct SQL query
  	my $sql = $self->_query_ido( $service_names );
  	# get results
  	$result = $self->_get_ido( $sql );
  	
  }elsif ($self->{'provider'} eq "mk-livestatus"){
  	
  	# construct query
  	my $query = $self->_query_livestatus( $service_names );
  	# get results
  	$result = eval { $self->_get_livestatus( $query ) };
  	
  	# mk-livestatus error handling
  	croak "No data received via mk-livestatus." unless $result;
  	
  }else{
  	carp ("Unsupported provider: $self->{'provider'}!");
  }
  
	# sorting the hash 
	my $views = $self->{ 'views' };
	while(my($view_key, $view) = each %$views) {
		while(my($topic, $prods) = each %$view) {
			next if $topic =~ m/^__display/;
			tie my %new_prods, 'Tie::IxHash', (map { ($_ => $prods->{$_}) } sort { lc($a) cmp lc($b) } keys %$prods);
			$view->{$topic} = \%new_prods;
		}
		tie my %new_view, 'Tie::IxHash', (map { ($_ => $view->{$_}) } sort { lc($a) cmp lc($b) } keys %$view);
		$views->{$view_key} = \%new_view;
	}
	tie my %new_views, 'Tie::IxHash', (map { ($_ => $views->{$_}) } sort { $views->{$a}->{__displayorder} <=> $views->{$b}->{__displayorder} } keys %$views);
	$self->{ 'views' } = \%new_views;

  # verify if status is given for all products
  # note: if product is missing in Icinga/Nagios there's no state for it
  # we use status code 99 for this (0-3 are reserved as Nagios plugin exit codes)
  # this is ugly - can it be done better?
  
  foreach my $environment (keys %{ $self->{ 'views' } }){
    foreach my $topic (keys %{ $self->{ 'views' }{ $environment } }){
      
      # don't process order information
      next if ( $topic eq "__displayorder" || $topic eq "__displayinrow" );
      
      foreach my $product (keys %{ $self->{ 'views' }{ $environment }{ $topic } }){
      	
    	# see _get_ido for example output!
  	    my $service = lc($environment . "-" . $topic . "-" . $product);
  	    # replace non-chars with _ except -, due to Nagios limitations
        #$service =~ s/[^a-zA-Z0-9-]+/_/g;
        $service =~ s/[^a-zA-Z0-9-]/_/g;
        
    	if (defined ($result->{ $service }{ 'state' })){
  	      # found status in IDO database
	      $self->{ 'views' }{ $environment }{ $topic }{ $product }{ 'state' } = $result->{ $service }{ 'state' };
	    }else{
	      # didn't found status in IDO database
  	      $self->{ 'views' }{ $environment }{ $topic }{ $product }{ 'state' } = 99;
	    }
	    
	    # return also business process name
	    $self->{ 'views' }{ $environment }{ $topic }{ $product }{ 'bpname' } = $service;
	    $self->{ 'views' }{ $environment }{ $topic }{ $product }{ 'name' } = $self->{ 'bps' }{ $service }{ 'BP' }{ 'NAME' };

	    # filter objects
	    if (defined $self->{ 'filter' }{ 'state' }){
	      	
	      my $del = 1;
          # filter results
          for (my $i=0;$i< scalar @{ $self->{ 'filter' }{ 'state' } }; $i++){
            if (lc( $self->{ 'filter' }{ 'state' }->[ $i ] ) eq "ok"){
              $del = 0 if $result->{ $service }{ 'state' } == 0;
            }elsif (lc( $self->{ 'filter' }{ 'state' }->[ $i ] ) eq "warning"){
              $del = 0 if $result->{ $service }{ 'state' } == 1;
            }elsif (lc( $self->{ 'filter' }{ 'state' }->[ $i ] ) eq "critical"){
              $del = 0 if $result->{ $service }{ 'state' } == 2;
            }elsif (lc( $self->{ 'filter' }{ 'state' }->[ $i ] ) eq "unknown"){
              $del = 0 if $result->{ $service }{ 'state' } == 3;
            }
          }
          delete $self->{ 'views' }{ $environment }{ $topic }{ $product } if $del == 1;
	      
	    }
	    
	    # filter hostnames
	    if (defined $self->{ 'filter' }{ 'name' }){
	    	
	      my $del = 1;
          # loop through hostname hash
          foreach my $hostname (keys %{ $self->{ 'bps' }{ $service }{ 'HOSTS' } }){
            for (my $i=0;$i< scalar @{ $self->{ 'filter' }{ 'name' } }; $i++){
              $del = 0 if lc( $hostname ) =~ lc ( $self->{ 'filter' }{ 'name' }->[ $i ]);
            }
          }
          delete $self->{ 'views' }{ $environment }{ $topic }{ $product } if $del == 1;
	    	
	    }
	      
      }
      
      # delete empty topics
      delete $self->{ 'views' }{ $environment }{ $topic} if scalar keys %{ $self->{ 'views' }{ $environment }{ $topic } } == 0;
      
    }
    
    # delete empty environments
    delete $self->{ 'views' }{ $environment } if scalar keys %{ $self->{ 'views' }{ $environment } } <= 2;
    #print STDERR Dumper $self->{ 'views' }{ $environment };
    
  }

  # produce json output
  my $json = JSON::PP->new->pretty;
  $json->utf8('true');
  $json = $json->encode($self->{ 'views' });
  return $json;
  
}


#----------------------------------------------------------------

=head1 METHODS	

=head2 get_bpstatus

 get_bpstatus ( )

Connects to backend and queries status of all host and service checks.
Returns hash.

  my $hash = $details->get_status();                               	

$VAR1 = {
  'loadbalancer' => [
    {
      'name2' => 'Service State Check',
      'last_hard_state' => '0',
      'hostname' => 'loadbalancer',
      'output' => 'OK: All services are in their appropriate state.'
    },
  ],
}  

=cut

sub get_bpstatus {
	
  my $self		= shift;
  my %options 	= @_;
  
  for my $key (keys %options){
  	if (exists $self->{ $key }){
  	  $self->{ $key } = $options{ $key };
  	}else{
  	  croak "Unknown option: $key";
  	}
  }
  
  my $result = undef;
  
  # verify if we cache data 
  if (defined $self->{ 'provdata' }{ 'cache_file' }){
  	# caching disabled if 0 or no cache time defined
    next if (! defined $self->{ 'provdata' }{ 'cache_time' } || $self->{ 'provdata' }{ 'cache_time' } == 0);
    $result = $self->_open_cache( $self->{ 'provdata' }{ 'cache_time' }, $self->{ 'provdata' }{ 'cache_file' } );
    
    # return cached data
    return $result unless $result == 1;
  }
  
  # fetch data from Icinga/Nagios
  if ($self->{'provider'} eq "ido"){
  	
  	# construct SQL query
  	my $sql = $self->_query_ido( '__all' );
  	# get results
  	$result = $self->_get_ido( $sql, "row" );
  	
  }elsif ($self->{'provider'} eq "mk-livestatus"){
  	
  	# construct query
  	my $query = $self->_query_livestatus( '__all' );
  	# get results
  	$result = eval { $self->_get_livestatus( $query, "row" ) };

  }else{
  	carp ("Unsupported provider: $self->{'provider'}!");
  }
  
  # write cache
  if (defined $self->{ 'provdata' }{ 'cache_file' }){
  	# caching disabled if 0 or no cache time defined
    next if (! defined $self->{ 'provdata' }{ 'cache_time' } || $self->{ 'provdata' }{ 'cache_time' } == 0);
    $self->_write_cache ( $self->{ 'provdata' }{ 'cache_time' }, $self->{ 'provdata' }{ 'cache_file' }, $result );
  }
  
  return $result;
  
}


#----------------------------------------------------------------

=head1 METHODS	

=head2 get_bpdetails

 get_bpdetails ( $bp_name )

Returns service details for given business process.
Returns hash.

  my $hash = $details->get_bpdetails( $bp_name );                               	

$VAR1 = {
   "mailserver": {
      "Amavisd-new Virus Check" : {
         "hardstate" : "OK",
         "output" : "Amavisd-New Virusscanning OK - server returned 2.7.0 Ok, discarded, id=00848-16 - INFECTED: Eicar-Test-Signature"
      },
   },
}

=cut

sub get_bpdetails {
	
  my $self		= shift;
  my $bp_name	= shift or croak "Missing business process name!";
  my %options 	= @_;
  
  for my $key (keys %options){
  	if (exists $self->{ $key }){
  	  $self->{ $key } = $options{ $key };
  	}else{
  	  croak "Unknown option: $key";
  	}
  }
  
  my $status = eval { $self->get_bpstatus() };
  croak "Failed to receive BP stati.\nReason: $@" if $@;
  
  my $return = {};
  
  croak "No data received from backend!" unless $status;
  
  foreach my $host (keys %{ $self->{ 'bps' }{ $self->{ 'bp' } }{ 'HOSTS' } }){
    foreach my $service (keys %{ $self->{ 'bps' }{ $self->{ 'bp' } }{ 'HOSTS' }{ $host } }){
    	
      # loop through host array
      for (my $i=0; $i< scalar @{ $status->{ $host } }; $i++){
      	if ($status->{ $host }->[ $i ]->{ 'name2' } eq $service){
      	  # service found
      	  my $state = "UNKNOWN";
      	  if    ( $status->{ $host }->[ $i]->{ 'last_hard_state' } == 0 ){ $state = "OK"; }
      	  elsif ( $status->{ $host }->[ $i]->{ 'last_hard_state' } == 1 ){ $state = "WARNING"; }
      	  elsif ( $status->{ $host }->[ $i]->{ 'last_hard_state' } == 2 ){ $state = "CRITICAL"; } 
      	  elsif ( $status->{ $host }->[ $i]->{ 'last_hard_state' } == 3 ){ $state = "UNKNOWN"; }; 
      	  $return->{ $host }{ $service }{ 'hardstate' } = $state;
     	  $return->{ $host }{ $service }{ 'output' } = $status->{ $host }->[ $i ]->{ 'output' };
      	}
      }
      # service not found
      if (! defined $return->{ $host }{ $service }{ 'hardstate' } ){
      	# service missing in data source
      	$return->{ $host }{ $service }{ 'hardstate' } = "UNKNOWN";
      	$return->{ $host }{ $service }{ 'output' } = "Service $service not found in Monitoring system!";
      }
    }
  }
  
  return $return;
  
}


#----------------------------------------------------------------

=head1 METHODS	

=head2 get_details

 get_details ( 'bp' => $business_process )

Connects to data backend and fetches service status details for all
services of this business process.
Returns JSON data.

  my $json = $get_details( 'bp' => $business_process );
  
$VAR1 = {
   "mailserver": {
      "Amavisd-new Virus Check" : {
         "hardstate" : "OK",
         "output" : "Amavisd-New Virusscanning OK - server returned 2.7.0 Ok, discarded, id=00848-16 - INFECTED: Eicar-Test-Signature"
      },
   },
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

  #use BPView::BP;
  
  # Die if no hosts are defined
  croak "No host defined for given business process " . $self->{ 'bp' } unless defined $self->{ 'bps' }{ $self->{ 'bp' } }{ 'HOSTS' };
  
  # get details for given business process 
  my $return = eval { $self->get_bpdetails( $self->{ 'bp' } ) };
  croak "Failed to fetch BP details.\nReason: $@" if $@;
  
  # filter objects
  if (defined $self->{ 'filter' }{ 'state' }){
  	
  	foreach my $host (keys %{ $return }){
  	  foreach my $service (keys %{ $return->{ $host } }){
	      	
        my $del = 1;
        # filter results
        for (my $x=0;$x< scalar @{ $self->{ 'filter' }{ 'state' } }; $x++){
          if (lc( $self->{ 'filter' }{ 'state' }->[ $x ] ) eq "ok"){
            $del = 0 if lc( $return->{ $host }{ $service }{ 'hardstate' } ) eq "ok";
          }elsif (lc( $self->{ 'filter' }{ 'state' }->[ $x ] ) eq "warning"){
            $del = 0 if lc( $return->{ $host }{ $service }{ 'hardstate' } ) eq "warning";
          }elsif (lc( $self->{ 'filter' }{ 'state' }->[ $x ] ) eq "critical"){
            $del = 0 if lc( $return->{ $host }{ $service }{ 'hardstate' } ) eq "critical";
          }elsif (lc( $self->{ 'filter' }{ 'state' }->[ $x ] ) eq "unknown"){
            $del = 0 if lc( $return->{ $host }{ $service }{ 'hardstate' } ) eq "unknown";
          }
        }
        delete $return->{ $host }{ $service } if $del == 1;
    
  	  }
    }
	      
  }
	    
  # filter hostnames
  if (defined $self->{ 'filter' }{ 'name' }){
  	
  	my $del = 1;
    # loop through hostname hash
    #foreach my $hostname (keys %{ $self->{ 'bps' }{ $service }{ 'HOSTS' } }){
  	foreach my $host (keys %{ $return }){
  	  foreach my $service (keys %{ $return->{ $host } }){
        for (my $x=0;$x< scalar @{ $self->{ 'filter' }{ 'name' } }; $x++){
          $del = 0 if lc( $host ) =~ lc ( $self->{ 'filter' }{ 'name' }->[ $x ]);
        }
        delete $return->{ $host }{ $service } if $del == 1
  	  }
    }
    
  }
	    
  # produce json output
  my  $json = JSON::PP->new->pretty;
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
  
  my $sql = undef;
  
  # construct SQL query
  # query all host and service data
  if ($service_names eq "__all"){
  	$sql = "SELECT " . $self->{'provdata'}{'prefix'} . "objects.name1 AS hostname, " . $self->{'provdata'}{'prefix'} . "objects.name2, " . $self->{'provdata'}{'prefix'};
  	$sql .= "servicestatus.last_hard_state, " . $self->{'provdata'}{'prefix'} . "servicestatus.output FROM " . $self->{'provdata'}{'prefix'} . "objects,";
  	$sql .= $self->{'provdata'}{'prefix'} . "servicestatus WHERE " . $self->{'provdata'}{'prefix'} . "objects.objecttype_id=2 AND " . $self->{'provdata'}{'prefix'};
  	$sql .= "objects.is_active=1 AND " . $self->{'provdata'}{'prefix'} . "objects.object_id=" . $self->{'provdata'}{'prefix'} . "servicestatus.service_object_id";
  }else{
    # query data for specified service
    $sql = "SELECT name2 AS service, current_state AS state FROM " . $self->{'provdata'}{'prefix'} . "objects, " . $self->{'provdata'}{'prefix'} . "servicestatus ";
    $sql .= "WHERE object_id = service_object_id AND is_active = 1 AND name2 IN (";
    # go trough service_names array
    for (my $i=0;$i<scalar @{ $service_names };$i++){
  	  $sql .= "'" . lc($service_names->[$i]) . "', ";
    }
    # remove trailing ', '
    chop $sql;
    chop $sql;
    $sql .= ") ORDER BY name1";
  }
  
  return $sql;
  
}


#----------------------------------------------------------------

# construct livetstatus query
sub _query_livestatus {
	
  my $self			= shift;
  my $service_names	= shift or croak ("Missing service_names!");
  
  my $query = undef;
   
  # get service status for given host and services
  # construct livestatus query
  if ($service_names eq "__all"){
  	$query = "GET services\n
Columns: host_name description last_hard_state plugin_output\n";
  }else{
  	# query data for specified service
    $query = "GET services\n
Columns: display_name state\n";
    # go through service array
    for (my $i=0;$i< scalar @{ $service_names };$i++){
   	  $query .= "Filter: display_name = " . lc($service_names->[$i]) . "\n";
    }
    $query .= "Or: " . scalar @{ $service_names } . "\n" if scalar @{ $service_names } > 1;
  }
  	  
  return $query;
  
}


#----------------------------------------------------------------

# get service status from IDOutils
sub _get_ido {
	
  my $self	= shift;
  my $sql	= shift or croak ("Missing SQL query!");
  my $fetch	= shift;	# how to handle results
  
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
  if (! defined $fetch || $fetch eq "all"){
  	# use hashref to fetch results
    $result = $query->fetchall_hashref("service");
  
  # example output:
  # $VAR1 = {
  #        'production-mail-zarafa' => {
  #                                      'service' => 'production-mail-zarafa',
  #                                      'state' => '0'
  #                                    },
  
  }elsif ($fetch eq "row"){
  	# fetch all data and return array
  	while (my $row = $query->fetchrow_hashref()){
  	  push @{ $result->{ $row->{ 'hostname' } } }, $row;
  
  # example output:
  # $VAR1 = {
  #         'loadbalancer' => [
  #           {
  #             'name2' => 'PING',
  #             'last_hard_state' => '0',
  #             'hostname' => 'loadbalancer',
  #             'output' => ''
  #           },
  #         ]
  #         },
  	}
  	
  }else{
  	croak "Unsupported fetch method: " . $fetch;
  }
  
  
  # disconnect from database
  #$dbh->disconnect;
  
  return $result;
  
}


#----------------------------------------------------------------

# get service status from mk-livestatus
sub _get_livestatus {
	
  my $self	= shift;
  my $query	= shift or croak ("Missing livestatus query!");
  my $fetch	= shift;	# how to handle results
  
  my $result;
  my $ml;
  
  use Monitoring::Livestatus;
  
  # use socket or hostname:port?
  if ($self->{'provdata'}{'socket'}){
    $ml = Monitoring::Livestatus->new( 	'socket' 	=> $self->{'provdata'}{'socket'},
    									'keepalive' => 1 );
  }else{
    $ml = Monitoring::Livestatus->new( 	'server' 	=> $self->{'provdata'}{'server'} . ':' . $self->{'provdata'}{'port'},
    									'keepalive'	=> 1 );
  }
  
  $ml->errors_are_fatal(0);
  
  # prepare return
  if (! defined $fetch || $fetch eq "all"){
    $result = $ml->selectall_hashref($query, "display_name");
    
  # example output:
  # $VAR1 = {
  #        'production-mail-zarafa' => {
  #                                      'service' => 'production-mail-zarafa',
  #                                      'state' => '0'
  #                                    },
  
    foreach my $key (keys %{ $result }){
      # rename columns
      $result->{ $key }{ 'service' } = delete $result->{ $key }{ 'display_name' };
    }
  
  
  }elsif ($fetch eq "row"){
  	# fetch all data and return array
  	my $tmp = $ml->selectall_arrayref($query);
    for (my $i=0; $i<scalar @{ $tmp }; $i++ ){
      my $tmphash = {};
      $tmphash->{ 'name2' } = $tmp->[$i][1];
      $tmphash->{ 'last_hard_state' } = $tmp->[$i][2];
      $tmphash->{ 'hostname' } = $tmp->[$i][0];
      $tmphash->{ 'output' } = $tmp->[$i][3];
  	  push @{ $result->{ $tmp->[$i][0] } }, $tmphash;
  
  # example output:
  # $VAR1 = {
  #         'loadbalancer' => [
  #           {
  #             'name2' => 'PING',
  #             'last_hard_state' => '0',
  #             'hostname' => 'loadbalancer',
  #             'output' => ''
  #           },
  #         ]
  #         },
  	}

  }else{
  	croak "Unsupported fetch method: " . $fetch;
  }
  
  if($Monitoring::Livestatus::ErrorCode) {
    croak "Getting Monitoring checkresults failed: $Monitoring::Livestatus::ErrorMessage";
  }
  
  return $result;
  
}


#----------------------------------------------------------------

# read cached data
sub _open_cache {

  my $self = shift;
  my $cache_time = shift or croak ("Missing cache time!");
  my $cache_file = shift or croak ("Missing cache file!");
  
  # check file age
  if ( ( time() - $cache_time ) < ( stat( $cache_file )->mtime ) ){
  	
  	# open cache file
    my $yaml = eval { LoadFile( $cache_file ) };
    if ($@){
      carp ("Failed to parse config file $cache_file\n");
      return 1;
    }else{
      return $yaml;
    }
    
  }
  
  return 1;
  
}


#----------------------------------------------------------------

# write cache
sub _write_cache {

  my $self = shift;
  my $cache_time = shift or croak ("Missing cache time!");
  my $cache_file = shift or croak ("Missing cache file!");
  my $data = shift or croak ("Missing data to write to cache file!");
  
  my $yaml = Dump ( $data );
  # write into YAML file
  open (CACHE, "> $cache_file") or croak ("Can't open file $cache_file for writing: $!");
  print CACHE $yaml;
  close CACHE;
  
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
  

Get business process status from IDO backend with all states except ok

  use BPView::Data;
  my $filter = { "state" => "ok" };
  my $dashboard = BPView::Data->new(
  	 views		=> $views,
   	 provider	=> "ido",
   	 provdata	=> $provdata,
   	 filter		=> $filter,
  );	
  $json = $dashboard->get_status
    
    
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
Peter Stoeckl, E<lt>p.stoeckl@ovido.atE<gt>

=head1 VERSION

Version 1.400  (October 18 2013))

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2013 by ovido gmbh

This library is free software; you can redistribute it and/or modify
it under the same terms as BPView itself.

=cut