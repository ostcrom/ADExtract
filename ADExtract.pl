#!/usr/bin/perl
#
# ADUpdate.pl v1.1 - by Daniel Steinke 3/10/2014 www.danielsteinke.com
#
# This program runs LDAP queries and dumps requested fields into a CSV.
# Queries are defined in an XML file, specified as a command line 
# argument.
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

use strict;
use Net::LDAP;
use Net::LDAP::Control::Paged;
use Net::LDAP::Constant qw( LDAP_CONTROL_PAGED );
use XML::Simple qw(:strict);
use Text::CSV;
use Data::Dumper;

if (!$ARGV[0]) {

	print "Missing XML Config file! Usage: $0 ConfigFile.xml \n";
	exit;
}

##XML stuff
my $xmlObject = XML::Simple->new(ForceArray => [ 'field', 'search' ], KeyAttr => [ search => 'name' ]);
my $config = $xmlObject->XMLin($ARGV[0]);
my $searches = $config->{search};

##LDAP stuff
my $ldapHost = $config->{ldapHost};
my $ldapUser = $config->{username};
my $ldapPassword = $config->{password};
my $pageLimit = $config->{pageLimit} || 1000;
my $ldap;



##Try to connect to LDAP...
if($ldap = Net::LDAP->new( $ldapHost)){
	print "\nSuccessfully conntected to LDAP host $ldapHost \n";
} else {
	print "Could not connect to LDAP host... $ldapHost\n";
	exit;
}

##Try to BIND to our LDAP host
print "Binding to $ldapHost with username: $ldapUser\n";
my $mesg = $ldap->bind($ldapUser,
		password => $ldapPassword
	);
##Should be no error messages if we bound OK....						
if (!$mesg->{errorMessage}){
	print "Successfully bound to $ldapHost...\n"
} else {
	print "Could not bind to LDAP host, check username and password! \n";
	print $mesg->{errorMessage}."\n";
	exit;
}

##Start working through the extracts defined in our XML...
foreach my $search (sort keys %{$searches}){
	##CSV stuff
	my $csv = Text::CSV->new({ binary => 1}) or die "Cannot use CSV: ".Text::CSV->error_diag ();

	print "\nRunning export: $search\n";

	my %currentSearch = %{$searches->{$search}};
	
	##Pluck out our search arguments, provide sensible defaults where appropriate.
	##Encapsulate the provided filter, XML parser does not like ampersands...
	my $filter = "(&".$currentSearch{'filter'} .")";
	my $base = $currentSearch{'base'} ;
	my $scope = $currentSearch{'scope'} || 'one';

	##Parse our supplied fields.
	my @fields;
	my %requiredFields;
	my $sortBy = $currentSearch{'sortBy'} || undef;
	my $sortAsc = lc $currentSearch{'sortAsc'} || "false";
	my $sortIndex;
	my %defaultValueFields;
	my %regexReplaceFields;
	
	foreach my $attr (@{$currentSearch{'field'}}){
		if(ref($attr) eq "HASH" && exists $attr->{'content'}){
			my $key = $attr->{'content'};
			push @fields, $key;
			##See if the provided sortBy field matches our current key, but not if a default value is provided.
			if ($sortBy && lc $sortBy eq lc $key && !exists $attr->{'default'}){
				$sortIndex = $#fields;
			}
			if(exists $attr->{'required'} && lc $attr->{'required'} eq "true"){
				$requiredFields{$key} = 1;
			} elsif (exists $attr->{'default'}){
				$defaultValueFields{$key} = $attr->{'default'};
			}
			##If we're tying to do a RegEx...
			if(defined $attr->{'regMatch'} || defined $attr->{'regReplace'} ){
				##make sure we have all the needed variables to do the dang thing...
				if(defined $attr->{'regReplace'} && defined $attr->{'regMatch'}){
					$regexReplaceFields{$key} = [$attr->{'regMatch'}, $attr->{'regReplace'}];
				} else {
					print "Need both regReplace and regMatch values to process a regex replace for $key field.\n";
				}
			}	
		} else  {
			push @fields, $attr; 
			if ($sortBy && lc $sortBy eq lc $attr){
				$sortIndex = $#fields;
			}
		}
	}
	
	##At this point, if an appropriate sortBy field was provided, we should have a matching index. 
	if(defined $sortBy && !defined $sortIndex){
		print "Could not match specified sort field to a column, please make sure the names are identical or that you have not provided a default value. CSV will not be sorted!\n";
		$sortBy = undef;
	}
	
	print "Filter: $filter\n";
	print "Base: $base\n";
	print "Scope: $scope\nPage Limit: $pageLimit\nFields: \n";
	print Dumper(@fields)."\n";
	
	##Set a few house keeping variables and open a stream to our file...
	my $cookie;
	my $page = Net::LDAP::Control::Paged->new( size => $pageLimit );
	my $count = 0;
	my $failCount = 0;
	my @csvRows;
	open (RESULTCSV, ">/tmp/$search.csv");
	
	
	##Arguments for LDAP search...
	my @args = ( base     => $base,
			  scope    => $scope,
			  filter   => $filter,
			  # callback => \&process_entry, # Call this sub for each entry
			  control  => [ $page ],
			  attrs => \@fields,
	);
	 
	
	while (1) {
		# Perform search
		$mesg = $ldap->search( @args );

		# Only continue on LDAP_SUCCESS
		$mesg->code and last;
		$count = $count + $mesg->count();
		
		##Process the entries returned by this page.
		foreach my $entry ($mesg->entries) {
			my @columns = $csv->fields();
			my $columnCount = 0;
			my $skip = 0;
			foreach my $attr (@fields){
				if($skip == 0){
					##See if we have a default value for this field...
					if (exists $defaultValueFields{$attr} && defined $defaultValueFields{$attr}){
						$columns[$columnCount] = $defaultValueFields{$attr};
						$columnCount++;					
					  ##See if this is a required field and that we got a value for it...
					} elsif(exists $requiredFields{$attr} && !defined $entry->get_value($attr)){
						print $entry->get_value($attr)."\n";
						print "Entry missing required field $attr!\nDump of retrieved fields for this entry:\n";
						print $entry->dump()."\n------------------------------------------------------------------------\n\n";
						$skip = 1;
					} else {
					##If the field is not required, fill in our column array, providing an empty value if necessary.
						$columns[$columnCount] = $entry->get_value($attr) || "";
						
						##See if we if we have a regEx replace for this field...
						if(defined $regexReplaceFields{$attr}){
							my $match = $regexReplaceFields{$attr}[0];
							my $replace = $regexReplaceFields{$attr}[1];
							
							$columns[$columnCount] =~ s/$match/$replace/g;
						}
						$columnCount++;
					}
				}
			}
			
			if($skip == 0){
				push @csvRows, \@columns;
			} else {
				$failCount++;
			}
		}
		
		# Get cookie from paged control
		my($resp)  = $mesg->control( LDAP_CONTROL_PAGED )  or last;
		$cookie    = $resp->cookie;

		# Only continue if cookie is nonempty (= we're not done)
		last  if (!defined($cookie) || !length($cookie));

		# Set cookie in paged control
		$page->cookie($cookie);
	}

	if (defined($cookie) && length($cookie)) {
		# We had an abnormal exit, so let the server know we do not want any more
		$page->cookie($cookie);
		$page->size(0);
		$ldap->search( @args );
	}
	print "Returned $count entries.\n";
	if($failCount){
		print "$failCount entries failed.\n";
	}
	
	if (defined $sortBy && defined $sortIndex) {
		print "Sorting by $sortBy in ";
		if ( $sortAsc eq "true" ) {
			print "ascending order....\n";
			@csvRows = sort { $a->[$sortIndex] <=> $b->[$sortIndex] } @csvRows;
		} else {
			print "descending order....\n";
			@csvRows = sort { $b->[$sortIndex] <=> $a->[$sortIndex] } @csvRows;
		}
	
	}
	
	foreach my $line (@csvRows){
		$csv->combine(@{$line});
		print RESULTCSV $csv->string()."\n";
	}

	close RESULTCSV;

}