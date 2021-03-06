#!/usr/bin/perl

use strict;
use warnings;
use Module::Build;



### Prepare global variables for installation

# initial build options
my $options = get_base_options();

# Check for additional Modules to install
check_useq();
check_sam();
check_big();


### Build the script
my $build = Module::Build->new(%$options);
$build->create_build_script;
exit 0;


###### subroutines to assist in building ########


sub get_base_options {
	my %options = (
		build_class       => 'Module::Build',
		module_name       => 'Bio::ToolBox',
		license           => 'perl',
		dist_version_from => 'lib/Bio/ToolBox.pm',
		dist_author       => 'Timothy Parnell <parnell.tj@gmail.com>',
		dist_abstract     => 'Tools for querying and analysis of genomic data',
		configure_requires => {
			'Module::Build'           => 0,
		},
		meta_merge        => {
			resources     => {
				repository     => 'https://github.com/tjparnell/biotoolbox'
			}
		},
		requires          => {
			'Config::Simple'          => 4.58,
			'Module::Load'            => 0,
			'Statistics::Lite'        => 3.2,
			'Statistics::Descriptive' => 3.0,
			'List::Util'              => 0,
		},
		recommends        => {
			'DBD::SQLite'             => 0,
			'File::Which'             => 0,
			'Net::FTP'                => 0,
			'Bio::Root::Version'      => '1.0069023',
			'Parallel::ForkManager'   => 1.02,
			'Set::IntervalTree'       => 0.10,
		},
		script_files => [
			'scripts/bam2wig.pl',
			'scripts/data2bed.pl',
			'scripts/data2fasta.pl',
			'scripts/data2gff.pl',
			'scripts/data2wig.pl',
			'scripts/db_setup.pl',
			'scripts/db_types.pl',
			'scripts/get_binned_data.pl',
			'scripts/get_datasets.pl',
			'scripts/get_features.pl',
			'scripts/get_feature_info.pl',
			'scripts/get_gene_regions.pl',
			'scripts/get_intersecting_features.pl',
			'scripts/get_relative_data.pl',
			'scripts/join_data_file.pl',
			'scripts/manipulate_datasets.pl',
			'scripts/merge_datasets.pl',
			'scripts/pull_features.pl',
			'scripts/split_data_file.pl',
			'scripts/ucsc_table2gff3.pl',
		],
	);
	return \%options;
}


sub check_useq {
	if ($] >= 5.010000) {
		# Bio::DB::USeq requires perl 5.10
		$options->{'recommends'}{'Bio::DB::USeq'} = 0.23;
	}
}


sub check_sam {
	# check to see if it is installed
	# request a minimum version if it is, otherwise recommend
	# we're going to prefer the new modern HTS library, but old sam one is ok
	my ($sam_ok, $hts_ok);
	eval {require Bio::DB::Sam; $sam_ok = 1;};
	eval {require Bio::DB::HTS; $hts_ok = 1;};
	if ($sam_ok and $hts_ok) {
		$options->{'requires'}{'Bio::DB::Sam'} = 1.36;
		$options->{'requires'}{'Bio::DB::HTS'} = 2.5;
	}
	elsif ($sam_ok and not $hts_ok) {
		# only old version, recommend new one
		$options->{'requires'}{'Bio::DB::Sam'} = 1.36;
		$options->{'recommends'}{'Bio::DB::HTS'} = 2.5;
	}
	elsif (not $sam_ok and $hts_ok) {
		# skip the old adapter
		$options->{'requires'}{'Bio::DB::HTS'} = 2.5;
	}
	else {
		$options->{'recommends'}{'Bio::DB::HTS'} = 2.5;
	}
}


sub check_big {
	
	# check to see if it is installed
	my $big_ok;
	eval {require Bio::DB::BigFile; $big_ok = 1;};
	if ($big_ok) {
		# BigFile support is currently installed
		# request a minimum version
		# if they don't meet this minimim, let's hope the user
		# knows how to rectify it.....
		$options->{'requires'}{'Bio::DB::BigFile'} = 1.07;
	}
	else {
		$options->{'recommends'}{'Bio::DB::BigFile'} = 1.07;
	}
}

