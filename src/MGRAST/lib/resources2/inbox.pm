package resources2::inbox;

use strict;
use warnings;
no warnings('once');

use Data::Dumper;
use Conf;
use parent qw(resources2::resource);

# Override parent constructor
sub new {
    my ($class, @args) = @_;

    # Call the constructor of the parent class
    my $self = $class->SUPER::new(@args);
    
    # Add name
    $self->{name} = "inbox";
    return $self;
}

# resource is called without any parameters
# this method must return a description of the resource
sub info {
    my ($self) = @_;
    my $content = { 'name' => $self->name,
                    'url' => $self->cgi->url."/".$self->name,
                    'description' => "inbox receives user inbox data upload, requires authentication, see http://blog.metagenomics.anl.gov/mg-rast-v3-2-faq/#api_submission for details",
                    'type' => 'object',
                    'documentation' => $Conf::cgi_url.'/Html/api.html#'.$self->name,
                    'requests' => [ { 'name'        => "info",
                                      'request'     => $self->cgi->url."/".$self->name,
                                      'description' => "Returns description of parameters and attributes.",
                                      'method'      => "GET",
                                      'type'        => "synchronous",  
                                      'attributes'  => "self",
                                      'parameters'  => { 'options'     => {},
                                                         'required'    => {},
                                                         'body'        => {} } },
                                    { 'name'        => "view",
                                      'request'     => $self->cgi->url."/".$self->name."/view",
                                      'description' => "lists the contents of the user inbox",
                                      'method'      => "GET",
                                      'type'        => "synchronous",  
                                      'attributes'  => { 'id'        => [ 'string', "user login" ],
                                                         'timestamp' => [ 'string', "timestamp for return of this query" ],
                                                         'files'     => [ 'list', [ 'object', [ { 'filename'  => [ 'string', "path of file from within user inbox" ],
                                                                                                  'filesize'  => [ 'string', "disk size of file in bytes" ],
                                                                                                  'timestamp' => [ 'string', "timestamp of file" ]
                                                                                                 }, "list of file objects"] ] ],
                                                         'url'       => [ 'uri', "resource location of this object instance" ] },
                                      'parameters'  => { 'options'     => {},
                                                         'required'    => { "auth" => [ "string", "unique string of text generated by MG-RAST for your account" ] },
                                                         'body'        => {} } },
                                    { 'name'        => "upload",
                                      'request'     => $self->cgi->url."/".$self->name."/upload",
                                      'description' => "receives user inbox data upload",
                                      'method'      => "POST",
                                      'type'        => "synchronous",  
                                      'attributes'  => { 'id'        => [ 'string', "user login" ],
                                                         'status'    => [ 'string', "status message" ],
                                                         'timestamp' => [ 'string', "timestamp for return of this query" ]
                                                       },
                                      'parameters'  => { 'options'     => {},
                                                         'required'    => { "auth" => [ "string", "unique string of text generated by MG-RAST for your account" ] },
                                                         'body'        => {} } }
                                     ]
                                 };

    $self->return_data($content);
}

sub instance {
    my ($self) = @_;

    if (($self->rest->[0] eq 'upload') && ($self->method eq 'POST')) {
        $self->upload_file();
    } elsif ($self->rest->[0] eq 'view') {
        $self->view_inbox();
    } else {
        $self->info();
    }
}

sub view_inbox {
    my ($self) = @_;

    my $black_list = "USER";
    my $black_list_seq_ext = "stats_info|error_log|lock|";
    if($self->user) {
        use Digest::MD5 qw(md5_hex);
        my $base_dir = "$Conf::incoming";
        my $udir = $base_dir."/".md5_hex($self->user->login);
        my @files = ();
        foreach my $file (`ls $udir`) {
            chomp $file;
            if(-d "$udir/$file") {
                my $subdir = $file;
                foreach my $subfile (`ls $udir/$subdir`) {
                    chomp $subfile;
                    unless($subfile =~ /^$black_list$/ || $subfile =~ /^\S+\.($black_list_seq_ext)$/) {
                        my $filesize = -s "$udir/$subdir/$subfile";
                        my $timestamp = scalar localtime((stat("$udir/$subdir/$subfile"))[9]);
                        push @files, { 'filename'   => "$subdir/$subfile",
                                       'filesize',  => $filesize." bytes",
                                       'timestamp', => $timestamp };
                    }
                }
            } else {
                unless($file =~ /^$black_list$/ || $file =~ /^\S+\.($black_list_seq_ext)$/) {
                    my $filesize = -s "$udir/$file";
                    my $timestamp = scalar localtime((stat("$udir/$file"))[9]);
                    push @files, { 'filename'   => $file,
                                   'filesize',  => $filesize." bytes",
                                   'timestamp', => $timestamp };
                }
            }
        }
        $self->return_data( { 'id' => $self->user->login,
                              'timestamp' => scalar localtime,
                              'files' => \@files,
                              'url' => $self->cgi->url."/".$self->name."/view" } );
    } else {
      $self->return_data( {"ERROR" => "authentication failed"}, 401 );
    }
}

sub upload_file {
    my ($self) = @_;

    if($self->user) {
        use Digest::MD5 qw(md5_hex);
        my $base_dir = "$Conf::incoming";
        my $udir = $base_dir."/".md5_hex($self->user->login);
        my $fn = $self->cgi->param('upload');

        if ($fn) {

            if ($fn =~ /\.\./) {
                $self->return_data( {"ERROR" => "invalid parameters, trying to change directory with filename, aborting"}, 400 );
            }

            if ($fn !~ /^[\w\d_\.\-\:\, ]+$/) {
                $self->return_data({"ERROR" => "Invalid parameters, filename allows only word, underscore, dash, colon, comma, dot (.), space, and number characters"}, 400);
            }

            if (-f "$udir/$fn") {
                $self->return_data( {"ERROR" => "the file already exists"}, 400 );
            }

            my $fh = $self->cgi->upload('upload');
            if (defined $fh) {
                my $io_handle = $fh->handle;
                if (open FH, ">$udir/$fn") {
                    my ($bytesread, $buffer);
                    while ($bytesread = $io_handle->read($buffer,4096)) {
                        print FH $buffer;
                    }
                    close FH;
                    $self->return_data( { 'id' => $self->user->login,
                                          'status' => "data received successfully",
                                          'timestamp' => scalar localtime } );
                } else {
                    $self->return_data( {"ERROR" => "storing object failed - could not open target file"}, 507 );
                }
            } else {
                $self->return_data( {"ERROR" => "storing object failed - could not obtain filehandle"}, 507 );
            }

        } else {
            $self->return_data( {"ERROR" => "invalid parameters, requires filename and data"}, 400 );
        }

    } else {
      $self->return_data( {"ERROR" => "authentication failed"}, 401 );
    }
}

1;
