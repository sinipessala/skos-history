#!/usr/bin/perl
# nbt, 6.11.2014

# Creates a csv table of change statistics

# Each query must return a result variable with the name given
# in row_head_name (e.g. 'version', or 'category'), plus at least one
# other column with the aggregated values for each row_head.

# Query parsing is based on whitespace recognition, minimal:
#   values ( ... ) { ( ... ) }

use strict;
use warnings;
use lib qw(lib);
use utf8;

use Class::CSV;
use Data::Dumper;
use File::Slurp;
use RDF::Query::Client;
use String::Util qw/unquote/;
use URI::file;

# create utf8 output
binmode( STDOUT, ":utf8" );

# List of version and data structure for results

my %definition = %{ get_definition() };

my $dataset = $ARGV[0];
my $table   = $ARGV[1];

if ( not( $dataset and $definition{$dataset} ) ) {
  print_usage();
  exit;
}

my $endpoint = "http://zbw.eu/beta/sparql/${dataset}v/query";

# Main loop over all tables of a dataset

foreach my $table_ref ( @{ $definition{$dataset}{tables} } ) {

  # TODO remove next line
  next if ref( $$table_ref{title} ) eq '';

  # If a table parameter is given, skip everything else
  if ( $table and $$table_ref{title}{en} ne $table ) {
    next;
  }
  my @column_definitions = @{ $$table_ref{column_definitions} };
  my ( @row_heads, %data );

  # for each column (query), get column data
  foreach my $columndef_ref (@column_definitions) {
    print "  $$columndef_ref{column}\n";
    get_column( $$table_ref{row_head_name},
      $columndef_ref, \@row_heads, \%data );
  }

  foreach my $lang ( @{ $$table_ref{languages} } ) {
    my $csv = build_csv( \@column_definitions, \@row_heads, \%data, $lang );
    print_csv( $table_ref, $csv, $lang );

    # special output for changed categories
    ##foreach my $chart_data_ref ( @{ $$table_ref{chart_data} } ) {
    ##print_chart_data( $csv, $table_ref, $chart_data_ref );
    ##}
  }
}

#######################

sub print_usage {
  print "\nUsage: $0 dataset [table]\n";
  print "\nAvailable datasets and tables:\n";
  foreach my $dataset ( sort keys %definition ) {
    print "  $dataset\n";
    foreach my $table_ref ( @{ $definition{$dataset}{tables} } ) {

      # TODO remove next line
      next if ref( $$table_ref{title} ) eq '';
      print "    $$table_ref{title}{en}\n";
    }
  }
  print "\n";
}

sub get_column {
  my $row_head_name = shift or die "param missing\n";
  my $columndef_ref = shift or die "param missing\n";
  my $row_head_ref  = shift or die "param missing\n";
  my $data_ref      = shift or die "param missing\n";

  # when $data_ref is empty, treat column differently
  my $first_column = %{$data_ref} ? undef : 1;

  # read query from file (by command line argument)
  my $query = read_file( $$columndef_ref{query_file} ) or die "Can't read $!\n";

  # add standard replacement for ?versionHistorySet
  $$columndef_ref{replace}{'?versionHistoryGraph'} =
    $definition{$dataset}{version_history_set};

  # column must get a sub-stucture by language if multilingual
  my $multi_lingual = 0;
  my @languages     = ('en');
  if ( exists( $$columndef_ref{languages} ) ) {
    $multi_lingual = 1;
    @languages     = @{ $$columndef_ref{languages} };
  }

  foreach my $lang (@languages) {

    # add standard replacement for ?versionHistorySet
    $$columndef_ref{replace}{'?language'} = "\"$lang\"";

    # parse VALUES clause
    my ( $variables_ref, $value_ref ) = parse_values($query);

    # replace values
    foreach my $variable ( keys %$value_ref ) {
      if ( defined( $$columndef_ref{replace}{$variable} ) ) {
        $$value_ref{$variable} = $$columndef_ref{replace}{$variable};
      }
    }
    $query = insert_modified_values( $query, $variables_ref, $value_ref );

    # execute query
    my $q        = RDF::Query::Client->new($query);
    my $iterator = $q->execute($endpoint)
      or die "Can't execute $$columndef_ref{query_file}\n";

    # parse and add results
    while ( my $row = $iterator->next ) {
      my $row_head = unquote( $row->{$row_head_name}->as_string );

      if ( defined $$data_ref{$row_head} or $first_column ) {
        die 'Result variable ', $$columndef_ref{result_variable},
          ' is not defined in ', $$columndef_ref{query_file}, "\n"
          unless $row->{ $$columndef_ref{result_variable} };

        my $value =
          unquote( $row->{ $$columndef_ref{result_variable} }->as_string );
        if ($multi_lingual) {
          $$data_ref{$row_head}{ $$columndef_ref{column} }{$lang} = $value;
        } else {
          $$data_ref{$row_head}{ $$columndef_ref{column} } = $value;
        }

        # the list of row headings is dynamically created here
        if ($first_column) {
          push( @{$row_head_ref}, $row_head );
        }
      }
    }
    # first columns actions must only be executed once, with the first language
    $first_column = 0;
  }
}

sub parse_values {
  my $query = shift or die "param missing\n";

  $query =~ m/ values \s+\(\s+ (.*?) \s+\)\s+\{ \s+\(\s+ (.*?) \s+\)\s+\} /ixms;

  my @variables  = split( /\s+/, $1 );
  my @values_tmp = split( /\s+/, $2 );
  my %value;
  for ( my $i = 0 ; $i < scalar(@variables) ; $i++ ) {
    $value{ $variables[$i] } = $values_tmp[$i];
  }
  return \@variables, \%value;
}

sub insert_modified_values {
  my $query         = shift or die "param missing\n";
  my $variables_ref = shift or die "param missing\n";
  my $value_ref     = shift or die "param missing\n";

  # create new values clause
  my @values;
  foreach my $variable (@$variables_ref) {
    push( @values, $$value_ref{$variable} );
  }
  my $values_clause =
      ' values ( '
    . join( ' ', @$variables_ref )
    . " ) {\n    ( "
    . join( ' ', @values )
    . " )\n  }";

  # insert into query
  $query =~ s/\svalues .*? \s+\)\s+\}/$values_clause/ixms;

  return $query;
}

sub build_csv {
  my @column_definitions = @{ shift() } or die "param missing\n";
  my @row_heads          = @{ shift() } or die "param missing\n";
  my $data_ref           = shift        or die "param missing\n";
  my $lang               = shift        or die "param missing\n";

  # initialize csv table with column names and headers
  my ( @columns, @column_headers );
  foreach my $column_ref (@column_definitions) {
    push( @columns,        $$column_ref{column} );
    push( @column_headers, $$column_ref{header}{$lang} );
  }
  my $csv = Class::CSV->new( fields => \@columns );
  $csv->add_line( \@column_headers );

  # add rows
  foreach my $row_head (@row_heads) {

    # map multilingual columns to a flat data structure
    my %row = %{ $$data_ref{$row_head} };
    foreach my $column_ref (@column_definitions) {
      if ( exists( $$column_ref{languages} ) ) {
        $row{ $$column_ref{column} } = $row{ $$column_ref{column} }{$lang};
      }
    }
    $csv->add_line( \%row );
  }
  return $csv;
}

sub print_csv {
  my $table_ref = shift or die "param missing\n";
  my $csv       = shift or die "param missing\n";
  my $lang      = shift or die "param missing\n";

  # output resulting table
  print "\n", $$table_ref{title}{$lang}, "\n\n";
  $csv->print;
  print "\n";
}

# Prints data formatted for insertion into a
# highcharts.com bar-negative-stack chart
sub print_chart_data {
  my $csv            = shift or die "param missing\n";
  my $table_ref      = shift or die "param missing\n";
  my $chart_data_ref = shift or die "param missing\n";

  # all but the first line, which contains column headers
  my @lines = @{ $csv->lines }[ 1 .. $#{ $csv->lines } ];
  my ( @values, $column_ref );

  # categories
  print "\n\n  var categories = [ ";
  foreach my $line (@lines) {
    push( @values, $line->{ $$table_ref{row_head_name} } );
  }
  print "'", join( "', '", @values ), "'";
  print " ];\n\n";

  print "      series: [{\n";

  # use the column referenced by the first entry in chart_data array
  $column_ref = $$table_ref{column_definitions}[ $$chart_data_ref[0] ];
  print "        name: '$$column_ref{header}',\n        data: [ ";
  @values = ();
  foreach my $line (@lines) {
    push( @values, $line->{ $$column_ref{column} } || 0 );
  }

  # value has to be negative to build the left-hand part of the stack
  print join( ", ", map { -$_ } @values );
  print " ]\n";

  print "      }, {\n";

  # use the column referenced by the second entry in chart_data array
  $column_ref = $$table_ref{column_definitions}[ $$chart_data_ref[1] ];
  print "        name: '$$column_ref{header}',\n        data: [ ";
  @values = ();
  foreach my $line (@lines) {
    push( @values, $line->{ $$column_ref{column} } || 0 );
  }
  print join( ", ", @values );
  print " ]\n";

  print "      }]\n\n";
}

sub get_definition {

  # List of queries and parameters for each statistics column
  # (the first column for each table must return the row_head values).

  my %definition = (
    'stw' => {
      version_history_set => '<http://zbw.eu/stw/version>',
      tables              => [
        {
          title              => 'Concept changes by version',
          row_head_name      => 'version',
          column_definitions => [
            {
              column          => 'version',
              header          => 'Version',
              query_file      => '../sparql/version_overview.rq',
              result_variable => 'version',
            },
            {
              column          => 'version_date',
              header          => 'Date',
              query_file      => '../sparql/version_overview.rq',
              result_variable => 'date',
            },
            {
              column          => 'total_thsys',
              header          => 'Total thsys',
              query_file      => '../sparql/stw/count_concepts.rq',
              replace         => { '?type' => '"Thsys"', },
              result_variable => 'conceptCount',
            },
            {
              column          => 'total_descriptors',
              header          => 'Total descriptors',
              query_file      => '../sparql/stw/count_concepts.rq',
              replace         => { '?type' => '"Descriptor"', },
              result_variable => 'conceptCount',
            },
            {
              column          => 'added_thsys',
              header          => 'Added thsys',
              query_file      => '../sparql/stw/count_added_concepts.rq',
              replace         => { '?conceptType' => 'zbwext:Thsys', },
              result_variable => 'addedConceptCount',
            },
            {
              column          => 'added_descriptors',
              header          => 'Added descriptors',
              query_file      => '../sparql/stw/count_added_concepts.rq',
              replace         => { '?conceptType' => 'zbwext:Descriptor', },
              result_variable => 'addedConceptCount',
            },
            {
              column          => 'deprecated_descriptors',
              header          => 'Deprecated descriptors',
              query_file      => '../sparql/stw/count_deprecated_concepts.rq',
              replace         => { '?conceptType' => 'zbwext:Descriptor', },
              result_variable => 'deprecatedConceptCount',
            },
            {
              column          => 'deprecated_descriptors_replaced',
              header          => 'Redirected descriptors',
              query_file      => '../sparql/stw/count_deprecated_concepts.rq',
              replace         => { '?conceptType' => 'zbwext:Descriptor', },
              result_variable => 'replacedByConceptCount',
            },
          ],
        },
        {
          title              => 'Label changes by version',
          row_head_name      => 'version',
          column_definitions => [
            {
              column          => 'version',
              header          => 'Version',
              query_file      => '../sparql/version_overview.rq',
              result_variable => 'version',
            },
            {
              column          => 'added_labels',
              header          => 'Added labels (total en)',
              query_file      => '../sparql/count_added_labels.rq',
              result_variable => 'addedLabelCount',
            },
            {
              column          => 'deleted_labels',
              header          => 'Deleted labels (total en)',
              query_file      => '../sparql/count_deleted_labels.rq',
              result_variable => 'deletedLabelCount',
            },
            {
              column     => 'added_des_labels_en',
              header     => 'Added descriptor labels (en)',
              query_file => '../sparql/stw/count_added_labels.rq',
              replace    => {
                '?language'    => '"en"',
                '?conceptType' => 'zbwext:Descriptor',
              },
              result_variable => 'addedLabelCount',
            },
            {
              column     => 'deleted_des_labels_en',
              header     => 'Deleted descriptor labels (en)',
              query_file => '../sparql/stw/count_deleted_labels.rq',
              replace => { '?language' => '"en"', '?type' => '"Descriptor"', },
              result_variable => 'deletedLabelCount',
            },
            {
              column     => 'added_des_labels_de',
              header     => 'Added descriptor labels (de)',
              query_file => '../sparql/stw/count_added_labels.rq',
              replace    => {
                '?language'    => '"de"',
                '?conceptType' => 'zbwext:Descriptor',
              },
              result_variable => 'addedLabelCount',
            },
            {
              column     => 'deleted_des_labels_de',
              header     => 'Deleted descriptor labels (de)',
              query_file => '../sparql/stw/count_deleted_labels.rq',
              replace => { '?language' => '"de"', '?type' => '"Descriptor"', },
              result_variable => 'deletedLabelCount',
            },
            {
              column     => 'added_sys_labels_en',
              header     => 'Added thsys labels (en)',
              query_file => '../sparql/stw/count_added_labels.rq',
              replace =>
                { '?language' => '"en"', '?conceptType' => 'zbwext:Thsys', },
              result_variable => 'addedLabelCount',
            },
            {
              column     => 'deleted_sys_labels_en',
              header     => 'Deleted thsys labels (en)',
              query_file => '../sparql/stw/count_deleted_labels.rq',
              replace    => { '?language' => '"en"', '?type' => '"Thsys"', },
              result_variable => 'deletedLabelCount',
            },
            {
              column     => 'added_sys_labels_de',
              header     => 'Added thsys labels (de)',
              query_file => '../sparql/stw/count_added_labels.rq',
              replace =>
                { '?language' => '"de"', '?conceptType' => 'zbwext:Thsys', },
              result_variable => 'addedLabelCount',
            },
            {
              column     => 'deleted_sys_labels_de',
              header     => 'Deleted thsys labels (de)',
              query_file => '../sparql/stw/count_deleted_labels.rq',
              replace    => { '?language' => '"de"', '?type' => '"Thsys"', },
              result_variable => 'deletedLabelCount',
            },
          ],
        },
        {
          title              => 'Concept changes by category',
          row_head_name      => 'secondLevelCategory',
          chart_data         => [ [ 1, 2 ], [ 4, 3 ], [ 6, 5 ], [ 7, 8 ], ],
          column_definitions => [
            {
              column     => 'secondLevelCategory',
              header     => 'Second level category',
              query_file => '../sparql/stw/count_total_concepts_by_category.rq',
              replace    => { '?language' => '"de"', },
              result_variable => 'secondLevelCategoryLabel',
            },
            {
              column     => 'total_descriptors_8.06',
              header     => 'Total 8.06',
              query_file => '../sparql/stw/count_total_concepts_by_category.rq',
              replace    => {
                '?newVersion'  => '"8.06"',
                '?conceptType' => 'zbwext:Descriptor',
              },
              result_variable => 'totalConcepts',
            },
            {
              column     => 'total_descriptors_8.14',
              header     => 'Total 8.14',
              query_file => '../sparql/stw/count_total_concepts_by_category.rq',
              replace    => {
                '?newVersion'  => '"8.14"',
                '?conceptType' => 'zbwext:Descriptor',
              },
              result_variable => 'totalConcepts',
            },
            {
              column     => 'added_descriptors',
              header     => 'Added descriptors',
              query_file => '../sparql/stw/count_added_concepts_by_category.rq',
              replace    => {
                '?oldVersion'  => '"8.06"',
                '?newVersion'  => '"8.14"',
                '?conceptType' => 'zbwext:Descriptor',
              },
              result_variable => 'addedConcepts',
            },
            {
              column => 'deprecated_descriptors',
              header => 'Deprecated descriptors',
              query_file =>
                '../sparql/stw/count_deprecated_concepts_by_category.rq',
              replace => {
                '?oldVersion'  => '"8.06"',
                '?newVersion'  => '"8.14"',
                '?conceptType' => 'zbwext:Descriptor',
              },
              result_variable => 'deprecatedConcepts',
            },
            {
              column     => 'added_thsys',
              header     => 'Added categories',
              query_file => '../sparql/stw/count_added_concepts_by_category.rq',
              replace    => {
                '?oldVersion'  => '"8.06"',
                '?newVersion'  => '"8.14"',
                '?conceptType' => 'zbwext:Thsys',
              },
              result_variable => 'addedConcepts',
            },
            {
              column => 'deprecated_thsys',
              header => 'Deprecated categories',
              query_file =>
                '../sparql/stw/count_deprecated_concepts_by_category.rq',
              replace => {
                '?oldVersion'  => '"8.06"',
                '?newVersion'  => '"8.14"',
                '?conceptType' => 'zbwext:Thsys',
              },
              result_variable => 'deprecatedConcepts',
            },
            {
              column     => 'total_thsys_8.06',
              header     => 'Total categories 8.06',
              query_file => '../sparql/stw/count_total_concepts_by_category.rq',
              replace    => {
                '?newVersion'  => '"8.06"',
                '?conceptType' => 'zbwext:Thsys',
              },
              result_variable => 'totalConcepts',
            },
            {
              column     => 'total_thsys_8.14',
              header     => 'Total categories 8.14',
              query_file => '../sparql/stw/count_total_concepts_by_category.rq',
              replace    => {
                '?newVersion'  => '"8.14"',
                '?conceptType' => 'zbwext:Thsys',
              },
              result_variable => 'totalConcepts',
            },
          ],
        },
        {
          row_head_name => 'topConcept',
          languages     => [qw/ en de /],
          title         => {
            en => 'Concept changes by sub-thesaurus',
            de => 'Geänderte Begriffe nach Subthesaurus',
          },
          chart_data => {
            total_descriptors => {
              title => {
                en => 'Descriptors by sub-thesaurus',
                de => 'Deskriptoren nach Subthesaurus',
              },
              columns => [ 1, 2 ],
            },
            changed_descriptors => {
              title => {
                en => 'Added and deprecated descriptors by sub-thesaurus',
                de => 'Neue und stillgelegte Deskriptoren nach Subthesaurus',
              },
              columns => [ 4, 3 ],
            },
            changed_thsys => {
              title => {
                en => 'Added and deprecated descriptors by sub-thesaurus',
                de => 'Neue und stillgelegte Deskriptoren nach Subthesaurus',
              },
              columns => [ 6, 5 ],
            },
            total_thsys => {
              title => {
                en => 'Categories by sub-thesaurus',
                de => 'Systematikstellen nach Subthesaurus',
              },
              columns => [ 7, 8 ],
            },
          },
          column_definitions => [
            {
              column    => 'topConcept',
              languages => [qw/ en de /],
              header    => {
                en => 'Sub-thesaurus',
                de => 'Subthesaurus',
              },
              query_file      => '../sparql/stw/count_total_concepts_by_top.rq',
              result_variable => 'topConceptLabel',
            },
            {
              column => 'total_descriptors_8.06',
              header => {
                en => 'Total descriptors 8.06',
                de => 'Gesamtzahl Deskriptoren 8.06',
              },
              query_file      => '../sparql/stw/count_total_concepts_by_top.rq',
              replace         => { '?newVersion' => '"8.06"', },
              result_variable => 'totalConcepts',
            },
            {
              column => 'total_descriptors_8.14',
              header => {
                en => 'Total descriptors 8.14',
                de => 'Gesamtzahl Deskriptoren 8.14',
              },
              query_file      => '../sparql/stw/count_total_concepts_by_top.rq',
              replace         => { '?newVersion' => '"8.14"', },
              result_variable => 'totalConcepts',
            },
            {
              column => 'added_descriptors',
              header => {
                en => 'Added descriptors',
                de => 'Zugefügte Deskriptoren',
              },
              query_file => '../sparql/stw/count_added_concepts_by_top.rq',
              replace    => {
                '?oldVersion' => '"8.06"',
                '?newVersion' => '"8.14"',
              },
              result_variable => 'addedConcepts',
            },
            {
              column => 'deprecated_descriptors',
              header => {
                en => 'Deprecated descriptors',
                de => 'Stillgelegte Deskriptoren',
              },
              query_file => '../sparql/stw/count_deprecated_concepts_by_top.rq',
              replace    => {
                '?oldVersion' => '"8.06"',
                '?newVersion' => '"8.14"',
              },
              result_variable => 'deprecatedConcepts',
            },
            {
              column => 'added_thsys',
              header => {
                en => 'Added categories',
                de => 'Zugefügte Systematikstellen',
              },
              query_file => '../sparql/stw/count_added_concepts_by_top.rq',
              replace    => {
                '?oldVersion'  => '"8.06"',
                '?newVersion'  => '"8.14"',
                '?conceptType' => 'zbwext:Thsys',
              },
              result_variable => 'addedConcepts',
            },
            {
              column => 'deprecated_thsys',
              header => {
                en => 'Deprecated categories',
                de => 'Stillgelegte Systematikstellen',
              },
              query_file => '../sparql/stw/count_deprecated_concepts_by_top.rq',
              replace    => {
                '?oldVersion'  => '"8.06"',
                '?newVersion'  => '"8.14"',
                '?conceptType' => 'zbwext:Thsys',
              },
              result_variable => 'deprecatedConcepts',
            },
            {
              column => 'total_thsys_8.06',
              header => {
                en => 'Total categories 8.06',
                de => 'Gesamtzahl Systematikstellen 8.06',
              },
              query_file => '../sparql/stw/count_total_concepts_by_top.rq',
              replace    => {
                '?newVersion'  => '"8.06"',
                '?conceptType' => 'zbwext:Thsys',
              },
              result_variable => 'totalConcepts',
            },
            {
              column => 'total_thsys_8.14',
              header => {
                en => 'Total categories 8.14',
                de => 'Gesamtzahl Systematikstellen 8.14',
              },
              query_file => '../sparql/stw/count_total_concepts_by_top.rq',
              replace    => {
                '?newVersion'  => '"8.14"',
                '?conceptType' => 'zbwext:Thsys',
              },
              result_variable => 'totalConcepts',
            },
          ],
        },
      ],
    },
    'thesoz' => {
      version_history_set => '<http://lod.gesis.org/thesoz/version>',
      tables              => [
        {
          title              => 'Concept changes by version',
          row_head_name      => 'version',
          column_definitions => [
            {
              column          => 'version',
              header          => 'Version',
              query_file      => '../sparql/version_overview.rq',
              result_variable => 'version',
            },
            {
              column          => 'version_date',
              header          => 'Date',
              query_file      => '../sparql/version_overview.rq',
              result_variable => 'date',
            },
            {
              column          => 'added_concepts',
              header          => 'Added concepts',
              query_file      => '../sparql/count_added_concepts.rq',
              result_variable => 'addedConceptCount',
            },
            {
              column     => 'added_descriptors',
              header     => 'Added descriptors',
              query_file => '../sparql/stw/count_added_concepts.rq',
              replace    => {
                '?conceptType' =>
                  '<http://lod.gesis.org/thesoz/ext/Descriptor>',
              },
              result_variable => 'addedConceptCount',
            },
            {
              column          => 'deleted_concepts',
              header          => 'Deleted concepts',
              query_file      => '../sparql/count_deleted_concepts.rq',
              result_variable => 'deletedConceptCount',
            },
          ],
        },
      ],
    },
  );

  return \%definition;
}
