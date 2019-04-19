package Yancy::Backend::Static;
our $VERSION = '0.001';
# ABSTRACT: Build a Yancy site from static Markdown files

=head1 SYNOPSIS

=head1 DESCRIPTION

This L<Yancy::Backend> allows Yancy to work with a site made up of
Markdown files with YAML frontmatter, like a L<Statocles> site.

=head1 SEE ALSO

L<Yancy>

=cut

use Mojo::Base -base;
use Mojo::File;
use Text::Markdown;
use YAML ();
use JSON::PP ();

has collections =>;
has path =>;
has markdown_parser => sub { Text::Markdown->new };

sub new {
    my ( $class, $backend, $collections ) = @_;
    my ( undef, $path ) = split /:/, $backend, 2;
    return $class->SUPER::new( {
        path => Mojo::File->new( $path ),
        collections => $collections,
    } );
}

sub create {
    my ( $self, $coll, $params ) = @_;

    my $path = $self->path->child( $self->_id_to_path( $params->{path} ) );
    my $content = $self->_deparse_content( $params );
    if ( !-d $path->dirname ) {
        $path->dirname->make_path;
    }
    $path->spurt( $content );

    return $params->{path};
}

sub get {
    my ( $self, $coll, $id ) = @_;

    # Allow directory path to work
    if ( -d $self->path->child( $id ) ) {
        $id =~ s{/$}{};
        $id .= '/index.markdown';
    }
    else {
        # Clean up the input path
        $id =~ s/\.\w+$//;
        $id .= '.markdown';
    }

    my $path = $self->path->child( $id );
    #; say "Getting path $id: $path";
    return undef unless -f $path;

    my $item = $self->_parse_content( $path->slurp );
    $item->{path} = $self->_path_to_id( $path->to_rel( $self->path ) );
    return $item;
}

sub list {
    my ( $self, $coll, $params, $opt ) = @_;
    $params ||= {};
    $opt ||= {};

    my @items;
    my $total = 0;
    PATH: for my $path ( sort $self->path->list_tree->each ) {
        my $item = $self->_parse_content( $path->slurp );
        $item->{path} = $self->_path_to_id( $path->to_rel( $self->path ) );
        for my $key ( keys %$params ) {
            #; say "list testing: $key - $item->{ $key } ne $params->{ $key }";
            next PATH if $item->{ $key } ne $params->{ $key };
        }
        push @items, $item;
        $total++;
    }

    return {
        items => \@items,
        total => $total,
    };
}

sub set {
    my ( $self, $coll, $id, $params ) = @_;
    my $content = $self->_deparse_content( $params );
    my $path = $self->path->child( $self->_id_to_path( $id ) );
    $path->spurt( $content );
    return 1;
}

sub delete {
    my ( $self, $coll, $id ) = @_;
    return !!unlink $self->path->child( $id );
}

sub read_schema {
    my ( $self, @collections ) = @_;
    my %page_schema = (
        required => [qw( path markdown )],
        'x-id-field' => 'path',
        'x-view-item-url' => '/{path}',
        properties => {
            path => {
                type => 'string',
            },
            title => {
                type => 'string',
            },
            markdown => {
                type => 'string',
                format => 'markdown',
                'x-html-field' => 'html',
            },
            html => {
                type => 'string',
            },
        },
    );
    return @collections ? \%page_schema : { page => \%page_schema };
}

sub _id_to_path {
    my ( $self, $id ) = @_;
    # Allow indexes to be created
    if ( $id =~ m{(?:^|\/)index$} ) {
        $id .= '.markdown';
    }
    # Allow full file paths to be created
    elsif ( $id =~ m{\.\w+$} ) {
        $id =~ s{\.\w+$}{.markdown};
    }
    # Anything else should create a file
    else {
        $id .= '.markdown';
    }
}

sub _path_to_id {
    my ( $self, $path ) = @_;
    return $path->basename( '.markdown' );
}

#=sub _parse_content
#
#   my $item = $backend->_parse_content( $path->slurp );
#
# Parse a file's frontmatter and Markdown. Returns a hashref
# ready for use as an item.
#
#=cut

sub _parse_content {
    my ( $self, $content ) = @_;
    my %item;

    my @lines = split /\n/, $content;
    # YAML frontmatter
    if ( @lines && $lines[0] =~ /^---/ ) {
        shift @lines;

        # The next --- is the end of the YAML frontmatter
        my ( $i ) = grep { $lines[ $_ ] =~ /^---/ } 0..$#lines;

        # If we did not find the marker between YAML and Markdown
        if ( !defined $i ) {
            die qq{Could not find end of YAML front matter (---)\n};
        }

        # Before the marker is YAML
        eval {
            %item = %{ YAML::Load( join "\n", splice( @lines, 0, $i ), "" ) };
        };
        if ( $@ ) {
            die qq{Error parsing YAML\n$@};
        }

        # Remove the last '---' mark
        shift @lines;
    }
    # JSON frontmatter
    elsif ( @lines && $lines[0] =~ /^{/ ) {
        my $json;
        if ( $lines[0] =~ /\}$/ ) {
            # The JSON is all on a single line
            $json = shift @lines;
        }
        else {
            # The } on a line by itself is the last line of JSON
            my ( $i ) = grep { $lines[ $_ ] =~ /^}$/ } 0..$#lines;
            # If we did not find the marker between YAML and Markdown
            if ( !defined $i ) {
                die qq{Could not find end of JSON front matter (\})\n};
            }
            $json = join "\n", splice( @lines, 0, $i+1 );
        }
        eval {
            %item = %{ JSON::PP->new()->utf8(0)->decode( $json ) };
        };
        if ( $@ ) {
            die qq{Error parsing JSON: $@\n};
        }
    }

    # The remaining lines are content
    $item{ markdown } = join "\n", @lines, "";
    $item{ html } = $self->markdown_parser->markdown( $item{ markdown } );

    return \%item;
}

sub _deparse_content {
    my ( $self, $item ) = @_;
    my %data =
        map { $_ => $item->{ $_ } }
        grep { !/^(?:markdown|html|path)$/ }
        keys %$item;
    return YAML::Dump( \%data ) . "---\n". $item->{markdown};
}

1;