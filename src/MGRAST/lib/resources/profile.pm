package resources::profile;

use strict;
use warnings;
no warnings('once');

use POSIX qw(strftime);
use List::MoreUtils qw(natatime);

use Conf;
use MGRAST::Abundance;
use parent qw(resources::resource);

# Override parent constructor
sub new {
    my ($class, @args) = @_;

    # Call the constructor of the parent class
    my $self = $class->SUPER::new(@args);
    
    # Add name / attributes
    my %rights = $self->user ? map { $_, 1 } grep {$_ ne '*'} @{$self->user->has_right_to(undef, 'view', 'metagenome')} : ();
    $self->{name} = "profile";
    $self->{rights} = \%rights;
    $self->{batch_size} = 250;
    $self->{sources} = [
        @{$self->source->{protein}},
        @{$self->source->{rna}},
        @{$self->source->{ontology}}
    ];
    $self->{ontology} = { map { $_, 1 } @{$self->source_by_type('ontology')} };
    $self->{default}  = 1;
    $self->{profile}  = {
        id        => [ 'string', 'unique metagenome identifier' ],
        created   => [ 'string', 'time the output data was generated' ],
        version   => [ 'integer', 'version number of M5NR used' ],
        sources   => [ 'list', [ 'string', 'list of the sources used in annotations, order is same as annotation lists' ] ],
        columns   => [ 'list', [ 'string', 'list of the columns in data' ] ],
        condensed => [ 'boolean', 'true if annotations are numeric identifiers and not full text' ],
        row_total => [ 'integer', 'number of rows in data matrix' ],
        data      => [ 'list', [ 'list', [ 'various', 'the matrix values' ] ] ]
    };
    $self->{submit} = {
        id     => [ 'string', 'unique status identifier' ],
        status => [ 'string', 'cv', ['submitted', 'process is has been submitted'],
                                    ['processing', 'process is still computing'],
                                    ['done', 'process is done computing'] ],
        url     => [ 'url', 'resource location of this object instance']
    };
    $self->{status} = {
        id     => [ 'string', 'unique profile status identifier' ],
        status => [ 'string', 'cv', ['submitted', 'profile is has been submitted'],
                                    ['processing', 'profile is still computing'],
                                    ['done', 'profile is done computing'] ],
        url     => [ 'url', 'resource location of this object instance'],
        size    => [ 'integer', 'size of profile in bytes' ],
        created => [ 'string', 'time the profile was completed' ],
        md5     => [ 'string', 'md5sum of profile' ],
        rows    => [ 'string', 'number of rows in profile data' ],
        sources => [ 'list', [ 'string', 'source name used in profile' ]],
        data    => $self->{profile}
    };
    return $self;
}

# resource is called without any parameters
# this method must return a description of the resource
sub info {
    my ($self) = @_;
    my $content = {
        'name'         => $self->name,
        'url'          => $self->cgi->url."/".$self->name,
        'description'  => "A feature profile in json format that contains abundance and similarity values along with annotations",
        'type'          => 'object',
        'documentation' => $self->cgi->url.'/api.html#'.$self->name,
        'requests'      => [
            { 'name'        => "info",
			  'request'     => $self->cgi->url."/".$self->name,
			  'description' => "Returns description of parameters and attributes.",
              'method'      => "GET" ,
              'type'        => "synchronous" ,  
              'attributes'  => "self",
              'parameters'  => {
                  'options'  => {},
                  'required' => {},
                  'body'     => {} }
			},
            { 'name'        => "instance",
              'request'     => $self->cgi->url."/".$self->name."/{ID}",
              'description' => "Submits profile creation",
              'method'      => "GET",
              'type'        => "asynchronous",  
              'attributes'  => $self->{submit},
              'parameters'  => {
                  'options' => {
                      'condensed' => ['boolean', 'if true, return condensed profile (integer ids for annotations)'],
                      ## only mgrast format saved as permanent shock node
                      'format'    => ['cv', [['mgrast','compressed json format (default)'],
                                             ['biom','BIOM json format']]],
                      'source'    => ['cv', $self->{sources}],
                      'version'   => ['integer', 'M5NR version, default is '.$self->{default}],
                      'verbosity' => ['cv', [['full','returns all data (default)'],
                                             ['minimal','returns only minimal information']]]
				  },
                  'required' => { "id" => ["string", "unique object identifier"] },
                  'body'     => {} }
            },
            { 'name'        => "status",
              'request'     => $self->cgi->url."/".$self->name."/status/{UUID}",
              'description' => "Return profile status and/or results",
              'method'      => "GET",
              'type'        => "synchronous",  
              'attributes'  => $self->{status},
              'parameters'  => {
                  'options' => {
                      'verbosity' => ['cv', [['full','returns all data (default)'],
                                             ['minimal','returns only minimal information']]]
				  },
                  'required' => { "id" => ["string", "RFC 4122 UUID for process"] },
                  'body'     => {} }
            }
        ]
	};
    $self->return_data($content);
}

# Override parent request function
sub request {
    my ($self) = @_;
    
    # determine sub-module to use
    if (scalar(@{$self->rest}) == 0) {
        $self->info();
    } elsif (scalar(@{$self->rest}) == 1) {
        $self->submit($self->rest->[0]);
    } elsif ((scalar(@{$self->rest}) > 1) && ($self->rest->[0] eq 'status')) {
        $self->status($self->rest->[1]);
    } else {
        $self->info();
    }
}

sub status {
    my ($self, $uuid) = @_;
    
    my $verbosity = $self->cgi->param('verbosity') || "full";
    # get node
    my $node = $self->get_shock_node($uuid, $self->mgrast_token);
    if (! $node) {
        $self->return_data( {"ERROR" => "process id $uuid does not exist"}, 404 );
    }
    my $obj = $self->status_report_from_node($node, "processing");
    if ($node->{file}{name} && $node->{file}{size}) {
        $obj->{status} = "done";
        if ($verbosity eq "full") {
            my ($content, $err) = $self->get_shock_file($uuid, undef, $self->mgrast_token);
            if ($err) {
                $self->return_data( {"ERROR" => "unable to retrieve data: ".$err}, 404 );
            }
            $obj->{data} = $self->json->decode($content);
        }
    }
    $self->return_data($obj);
}

sub submit {
    my ($self, $mid) = @_;
    
    # check id format
    my ($id) = $mid =~ /^mgm(\d+\.\d+)$/;
    unless ($id) {
        $self->return_data( {"ERROR" => "invalid id format: " . $mid}, 400 );
    }
    # get database / data
    my $master = $self->connect_to_datasource();
    my $job = $master->Job->get_objects( {metagenome_id => $id} );
    unless ($job && @$job) {
        $self->return_data( {"ERROR" => "id $id does not exist"}, 404 );
    }
    $job = $job->[0];
    unless ($job->viewable) {
        $self->return_data( {"ERROR" => "id $id is still processing and unavailable"}, 404 );
    }
    # check rights
    unless ($job->{public} || exists($self->rights->{$id}) || ($self->user && $self->user->has_star_right('view', 'metagenome'))) {
        $self->return_data( {"ERROR" => "insufficient permissions to view this data"}, 401 );
    }
    
    # get paramaters
    my $version   = $self->cgi->param('version') || $self->{default};
    my @sources   = $self->cgi->param('source') || ("RefSeq");
    my $condensed = $self->cgi->param('condensed') ? 'true' : 'false';
    my $format    = ($self->cgi->param('format') && ($self->cgi->param('format') eq 'biom')) ? 'biom' : 'mgrast';
    
    $version = $self->check_version($version);
    
    # validate type / source
    my $all_srcs = {};
    if ($job->{sequence_type} =~ /^Amplicon/) {
        map { $all_srcs->{$_} = 1 } @{$self->source_by_type('rna')};
    } else {
        map { $all_srcs->{$_} = 1 } @{$self->source_by_type('protein')};
        map { $all_srcs->{$_} = 1 } @{$self->source_by_type('rna')};
        map { $all_srcs->{$_} = 1 } @{$self->source_by_type('ontology')};
    }
    @sources = sort @sources;
    foreach my $s (@sources) {
        unless (exists $all_srcs->{$s}) {
            return ({"ERROR" => "Invalid source for profile: ".$s." - valid types are [".join(", ", keys %$all_srcs)."]"}, 400);
        }
    }
    
    # check for static feature profile node from shock
    my $squery = {
        id => 'mgm'.$id,
        type => 'metagenome',
        data_type => 'profile',
        stage_name => 'done'
    };
    my $snodes = $self->get_shock_query($squery, $self->mgrast_token);
    $self->check_static_profile($snodes, \@sources, $condensed, $version);
    
    # check if temp profile compute node is in shock
    my $tquery = {
        type => "temp",
        url_id => $self->url_id,
        owner  => $self->user ? 'mgu'.$self->user->_id : "anonymous",
        data_type => "profile"
    };
    my $tnodes = $self->get_shock_query($tquery, $self->mgrast_token);
    if ($tnodes && (@$tnodes > 0)) {
        my $obj = $self->status_report_from_node($tnodes->[0], "submitted");
        $self->return_data($obj);
    }
    
    # need to create new temp node
    $tquery->{row_total} = 0;
    $tquery->{sources}   = \@sources;
    $tquery->{condensed} = $condensed;
    $tquery->{version}   = $version;
    $tquery->{format}    = $format;
    my $node = $self->set_shock_node('mgm'.$id.'.biom', undef, $tquery, $self->mgrast_token, undef, undef, "7D");
    
    # asynchronous call, fork the process
    my $pid = fork();
    # child - compute data and dump it
    if ($pid == 0) {
        close STDERR;
        close STDOUT;
        my ($data, $error) = $self->prepare_data($id, $node->{id}, \@sources, $condensed, $version, $format);
        if ($error) {
            $data->{STATUS} = $error;
        }
        $self->put_shock_file($data->{id}.".json", $data, $node->{id}, $self->mgrast_token);
        exit 0;
    }
    # parent - end html session
    else {
        my $obj = $self->status_report_from_node($node, "submitted");
        $self->return_data($obj);
    }
}

# reformat the data into the requested output format
sub prepare_data {
    my ($self, $id, $node_id, $sources, $condensed, $version, $format) = @_;

    # get data
    my $master = $self->connect_to_datasource();
    my $job  = $master->Job->get_objects( {metagenome_id => $id} );
    my $data = $job->[0];
    
    # set profile based on format
    my $columns = [];
    my $profile = {};
    
    if ($format eq 'biom') {
        $columns = [{id => "abundance"}, {id => "e-value"}, {id => "percent identity"}, {id => "alignment length"}];
        $profile = {
            id                  => "mgm".$id,
            format              => "Biological Observation Matrix 1.0",
            format_url          => "http://biom-format.org",
            type                => "Feature table",
            generated_by        => "MG-RAST".($Conf::server_version ? " revision ".$Conf::server_version : ""),
            date                => strftime("%Y-%m-%dT%H:%M:%S", localtime),
            matrix_type         => "dense",
            matrix_element_type => "float",
            shape               => [ 0, scalar(@$columns) ],
            rows                => [],
            columns             => $columns,
            data                => []
        };
    } else {
        $columns = ["md5sum", "abundance", "e-value", "percent identity", "alignment length", "single organisms", "organisms", "functions", "categories"];
	    $profile = {
            id        => "mgm".$id,
            created   => strftime("%Y-%m-%dT%H:%M:%S", localtime),
            version   => $version,
            sources   => $sources,
            columns   => $columns,
            condensed => $condensed,
            row_total => 0,
            data      => []
	    };
    }

    # get data
    my $id2ann = {}; # md5_id => { accession => [], function => [], organism => [], ontology => [] }
    my $id2md5 = {}; # md5_id => md5
    
    # cass handle
    my $chdl = $self->cassandra_m5nr_handle("m5nr_v".$version, $Conf::cassandra_m5nr);
    
    # run query
    MGRAST::Abundance::get_analysis_dbh();
    my $query = "SELECT md5, abundance, exp_avg, len_avg, ident_avg FROM job_md5s WHERE version=".$version." AND job=".$data->{job_id};
    my $sth = MGRAST::Abundance::execute_query($query);
    
    # loop through results and build profile
    my $md5_row = {};
    my $batch_count = 0;
    while (my @row = $sth->fetchrow_array()) {
        my ($md5, $abun, $eval, $ident, $alen) = @row;
        if ($format eq 'biom') {        
            $md5_row->{$md5} = [$abun, $eval, $ident, $alen];
        } else {
            $md5_row->{$md5} = ["", $abun, $eval, $ident, $alen, [], [], [], []];
        }
        $batch_count++;
        if ($batch_count == $self->{batch_size}) {
            $self->append_profile($chdl, $profile, $md5_row, $sources, $condensed, $format);
            $md5_row = {};
            $batch_count = 0;
        }
    }
    if ($batch_count > 0) {
        $self->append_profile($chdl, $profile, $md5_row, $sources, $condensed, $format);
    }
    # cleanup
    MGRAST::Abundance::end_query($sth);
    $chdl->close();
	
	if ($format eq 'biom') {
	    $profile->{shape}[0] = scalar(@{$profile->{rows}});
	} else {
	    $profile->{row_total} = scalar(@{$profile->{data}});
	    
	    # store it in shock permanently if mgrast format
	    my $attr = {
	        id            => 'mgm'.$id,
	        job_id        => $data->{job_id},
	        created       => $data->{created_on},
	        name          => $data->{name},
	        owner         => 'mgu'.$data->{owner},
	        sequence_type => $data->{sequence_type},
	        status        => $data->{public} ? 'public' : 'private',
	        project_id    => undef,
	        project_name  => undef,
            type          => 'metagenome',
            data_type     => 'profile',
            sources       => $sources,
            row_total     => $profile->{row_total},
            condensed     => $condensed,
            version       => $version,
            file_format   => 'biom',
            stage_name    => 'done',
            stage_id      => '999'
	    };
	    eval {
	        my $proj = $data->primary_project;
	        if ($proj->{id}) {
	            $attr->{project_id} = 'mgp'.$proj->{id};
	            $attr->{project_name} = $proj->{name};
            }
	    };
	    # update existing node / remove expiration
	    # file added to node in asynch mode in parent function
	    my $node = {};
        $node = $self->update_shock_node($node_id, $attr, $self->mgrast_token);
	    $node = $self->update_shock_node_expiration($node_id, $self->mgrast_token);
	    if ($data->{public}) {
	        $self->edit_shock_public_acl($node->{id}, $self->mgrast_token, 'put', 'read');
	    }
    }
    
    return ($profile, undef);
}

sub append_profile {
    my ($self, $chdl, $profile, $md5_row, $sources, $condensed, $format) = @_;
    
    my @mids = keys %$md5_row;
    my $count = 0;
    my %md5_idx = {}; # md5id => row index #
    
    foreach my $src (@$sources) {
        my $cass_data = [];
        if ($condensed eq "true") {
            $cass_data = $chdl->get_id_records_by_id(\@mids, $src);
        } elsif ($condensed eq "false") {
            $cass_data = $chdl->get_records_by_id(\@mids, $src);
        }
        foreach my $info (@$cass_data) {
            # set / get row index
            unless (exists $md5_idx{$info->{id}}) {
                # set profile row
                $profile->{data}[$count] = $md5_row->{$info->{id}};
                $md5_idx{$info->{id}} = $count;
                $count += 1;
            }
            my $index = $md5_idx{$info->{id}};

            if ($format eq 'biom') {
                # append source specific data in profile row metadata 
                if ($index >= scalar(@{$profile->{rows}})) {
                    $profile->{rows}[$index] = { id => $info->{md5}, metadata => {} }
                }
                $profile->{rows}[$index]{metadata}{$src} = { function => $info->{function} };
                if (exists $self->{ontology}{$info->{source}}) {
                    $profile->{rows}[$index]{metadata}{$src}{ontology} = $info->{accession};
                } else {
                    $profile->{rows}[$index]{metadata}{$src}{single}    = $info->{single};
                    $profile->{rows}[$index]{metadata}{$src}{organism}  = $info->{organism};
                    $profile->{rows}[$index]{metadata}{$src}{accession} = $info->{accession};
                }
            } else {
                # append source specific data in profile data
                # md5sum, abundance, e-value, percent identity, alignment length, single organisms, organisms, functions, categories
                $profile->{data}[$index][0] = $info->{md5};
                push @{$profile->{data}[$index][5]}, $info->{single};
                push @{$profile->{data}[$index][6]}, $info->{organism};
                push @{$profile->{data}[$index][7]}, $info->{function};
                if (exists $self->{ontology}{$info->{source}}) {
                    push @{$profile->{data}[$index][8]}, $info->{accession};
                } else {
                    push @{$profile->{data}[$index][8]}, [];
                }
            }
        }
    }
}

sub status_report_from_node {
    my ($self, $node, $status) = @_;
    return {
        id      => $node->{id},
        status  => $status,
        url     => $self->cgi->url."/".$self->name."/status/".$node->{id},
        size    => $node->{file}{size},
        created => $node->{file}{created_on},
        md5     => $node->{file}{checksum}{md5} ? $node->{file}{checksum}{md5} : "",
        rows    => $node->{attributes}{row_total} ? $node->{attributes}{row_total} : 0,
        sources => $node->{attributes}{sources} ? $node->{attributes}{sources} : [],
        version => $node->{attributes}{version} ? $node->{attributes}{version} : 1,
    };
}

sub check_static_profile {
    my ($self, $nodes, $sources, $condensed, $version) = @_;
    
    # sort results by newest to oldest
    my @sorted = sort { $b->{file}{created_on} cmp $a->{file}{created_on} } @$nodes;
    
    foreach my $n (@$nodes) {
        my $has_sources  = 1;
        my %node_sources = map { $_, 1 } @{$n->{attributes}{sources}};
        foreach my $s (@$sources) {
            unless (exists $node_sources{$s}) {
                $has_sources = 0;
            }
        }
        if ( $n->{attributes}{condensed} &&
             $n->{attributes}{version} &&
             ($n->{attributes}{condensed} eq $condensed) &&
             ($n->{attributes}{version} == $version) &&
             $has_sources ) {
            $self->status($n->{id});
        }
    }
}

sub check_version {
    my ($self, $version) = @_;
    
    unless ($version =~ /^\d+$/) {
        $self->return_data({"ERROR" => "invalid version was entered ($version). Must be an integer"}, 404);
    }
    $version = $version * 1;
    ## currently only support version 1
    unless ($version == 1) {
        $self->return_data({"ERROR" => "invalid version was entered ($version). Currently only version 1 is supported"}, 404);
    }
    #unless (exists $self->{m5nr_version}{$version}) {
    #    $self->return_data({"ERROR" => "invalid version was entered ($version). Please use one of: ".join(", ", keys %{$self->{m5nr_version}})}, 404);
    #}
    return $version;
}

1;
