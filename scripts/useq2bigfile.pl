#!/usr/bin/perl

# This script will convert useq file to a big* file

use strict;
use Getopt::Long;
use Pod::Usage;
use File::Temp;
use Statistics::Lite qw(mean median sum max);
use FindBin qw($Bin);
use lib "$Bin/../lib";
use tim_db_helper qw(
	$TIM_CONFIG
	open_db_connection
);
use tim_file_helper qw(
	open_to_read_fh
	open_to_write_fh
);
use tim_db_helper::bigwig;
use tim_db_helper::bigbed;


print "\n This program will convert a useq archive to a bigwig/bigbed file\n\n";

### Quick help
unless (@ARGV) { 
	# when no command line options are present
	# print SYNOPSIS
	pod2usage( {
		'-verbose' => 0, 
		'-exitval' => 1,
	} );
}



### Get command line options and initialize values
my (
	$infile,
	$outfile,
	$to_bw,
	$to_bb,
	$bedgraph,
	$method,
	$strand,
	$database,
	$chromo_file,
	$useq_app_path,
	$big_app_path,
	$java_app_path,
	$help
);

# Command line options
GetOptions( 
	'in=s'      => \$infile, # the useq input data file
	'out=s'     => \$outfile, # name of output file 
	'bw'        => \$to_bw, # generate bigwig file
	'bb'        => \$to_bb, # generate bigbed file
	'gr!'       => \$bedgraph, # write a bedgraph file instead of wig
	'method=s'  => \$method, # method for combining duplicate lines
	'strand=s'  => \$strand, # take a specific strand
	'db=s'      => \$database, # name of database to get chromo info
	'chromof=s' => \$chromo_file, # name of a chromosome file
	'bigapp=s'  => \$big_app_path, # path to bigfile conversion utility
	'useqapp=s' => \$useq_app_path, # path to useq2text jar file
	'help'      => \$help # request help
);

# Print help
if ($help) {
	# print entire POD
	pod2usage( {
		'-verbose' => 2,
		'-exitval' => 1,
	} );
}



### Check for requirements
unless ($infile) {
	$infile = shift @ARGV or
		die " no input file! use --help for more information\n";
}
unless ($infile =~ /\.useq$/i) {
	die " input file does not have .useq extension!\n";
}
unless ($to_bw or $to_bb) {
	die " must specify either a BigBed or BigWig format! see help\n";
}
unless ($database or $chromo_file) {
	die " either a chromosome file or database with chromosome information is required!\n";
}

# determine the method subroutine
my $method_sub = determine_method_sub();

# check strand 
if ($strand) {
	unless ($strand eq 'f' or $strand eq 'r') {
		die " unrecognized strand option '$strand'! see help\n";
	}
}



### identify application paths
get_application_paths();




### Get chromosome sizes
my %chrom_sizes = get_chromosome_sizes();




### Convert the USeq archive to text
# using David's own converter utility
# what, you think I wrote my own parser? you're crazy!
print " Running USeqToText app...\n-----------\n";
system $java_app_path, '-Xmx1500M', '-jar', $useq_app_path, '-f', $infile;

# check the output bed file
my $input_bed = $infile;
$input_bed =~ s/\.useq$/.bed/i;
unless (-e $input_bed and -s $input_bed) {
	unlink $input_bed if -e $input_bed; # delete 0-byte file if exists
	die " USeqToText app must have failed! see STDERR for clues\n";
}
print "-----------\n";




### Process the text bed file
my $bigfile;
print " Checking for out of bound features and duplicates...\n";
if ($to_bw) {
	# write either a wig or bedgraph file
	# depends on the selected utility
	if ($big_app_path =~ /bedGraphToBigWig$/) {
		# write a bedgraph file
		print " Writing a temporary bedgraph file...\n";
		$bigfile = convert_to_bedgraph($input_bed);
	}
	elsif ($big_app_path =~ /wigToBigWig$/) {
		# write a wig file
		print " Writing a temporary variableStep wig file...\n";
		$bigfile = convert_to_wig($input_bed);
	}
	else {
		die " unknown bigwig conversion utility '$big_app_path'!\n";
	}
}
elsif ($to_bb) {
	# write a bed file
	print " Writing a temporary bed file...\n";
	$bigfile = convert_to_bed($input_bed);
}




### Clean up and finish
# delete chromosome temporary file
if ($chrom_sizes{'deleteMe'}) {
	unlink $chromo_file;
}

# delete input bed file generated by USeq2Text
unlink $input_bed;

# print outcome
if ($bigfile) {
	print " Conversion success!\n wrote file '$bigfile'\n";
}
else {
	print " Conversion failed!\n";
}










########################   Subroutines   ###################################


sub determine_method_sub {
	my $method_sub;
	if ($method eq 'mean') {
		$method_sub = \&mean;
	}
	elsif ($method eq 'median') {
		$method_sub = \&median;
	}
	elsif ($method eq 'sum') {
		$method_sub = \&sum;
	}
	elsif ($method eq 'max') {
		$method_sub = \&max;
	}
	else {
		print " using default method of mean for duplicate values\n";
		$method_sub = \&mean;
	}
	return $method_sub;
}


sub get_application_paths {
	
	# identify the java executable
	$java_app_path = $TIM_CONFIG->param('applications.java') || 
		`which java` || undef;
	if (defined $java_app_path) {
		chomp $java_app_path; # the which command will have a newline character
	}
	else {
		die " unable to identify java executable!\n";
	}
	
	# identify the USeq2Text jar file
	unless ($useq_app_path) {
		$useq_app_path = $TIM_CONFIG->param('applications.USeq2Text') || undef;
		unless ($useq_app_path) {
			die " Must define the path to the USeq java jar file USeq2Text! see help\n";
		}
	}
	
	
	
	## identify appropriate bigfile convertor
	
	# bigwig conversion
	if ($to_bw) {
		if ($big_app_path) {
			
			# check that it's the right utility
			if ($bedgraph) {
				unless ($big_app_path =~ /bedGraphToBigWig$/) {
					die " requested bedGraph but using '$big_app_path' utility!?\n";
				}
			}
			else {
				# default is to write a wig file, so $bedgraph may not be true or set
				# let's check to see what the user offered
				if ($big_app_path =~ /bedGraphToBigWig$/) {
					# user requested bedGraph, so let's use that
					$bedgraph = 1;
				}
				elsif ($big_app_path =~ /wigToBigWig$/) {
					# user is using wig
					$bedgraph = 0;
				}
				else {
					die " requested wig but using '$big_app_path' utility!?\n";
				}
			}
		}	
		
		# need to find the application path
		else {
			# depends on whether user requested bedgraph or not
			if ($bedgraph) {
				$big_app_path = 
					$TIM_CONFIG->param('applications.bedGraphToBigWig') || undef;
				
				# try looking in the environment path using external which 
				unless ($big_app_path) {
					$big_app_path = `which bedGraphToBigWig`;
					chomp $big_app_path;
				}
				
				# can't find anything
				unless ($big_app_path) {
					die " unable to find bedGraphToBigWig utility! see help\n";
				}
			}
			else {
				$big_app_path = 
					$TIM_CONFIG->param('applications.wigToBigWig') || undef;
				
				# try looking in the environment path using external which 
				unless ($big_app_path) {
					$big_app_path = `which wigToBigWig`;
					chomp $big_app_path;
				}
				
				# can't find anything
				unless ($big_app_path) {
					die " unable to find wigToBigWig utility! see help\n";
				}
			}	
		}
	}
	
	# bigbed conversion
	elsif ($to_bb) {
		if ($big_app_path) {
			unless ($big_app_path =~ /ToBigBed$/) {
				die " requested bigbed conversion but '$big_app_path' utility!?\n";
			}
		}
		
		# need to find the application path
		else {
			# need to use bedToBigBed
			$big_app_path = 
				$TIM_CONFIG->param('applications.bedToBigBed') || undef;
			unless ($big_app_path) {
				$big_app_path = `which bedToBigBed`;
				chomp $big_app_path;
			}
			unless ($big_app_path) {
				die " unable to find utility bedToBigBed! see help\n";
			}
		}
	}
}


sub get_chromosome_sizes {
	my %sizes;
	
	# we'll determine the chromosome lengths either from a database or file
	
	# from text file
	# format should be chromosome  size
	if ($chromo_file) {
		my $fh = open_to_read_fh($chromo_file) or 
			die " unable to chromosome sizes file '$chromo_file'!\n";
		
		# collect sizes from file
		while (my $line = $fh->getline) {
			next if $line =~ /^#/; # in case of comments, unlikely 
			chomp $line;
			my ($chr, $size) = split /\s+/, $line;
			unless ($chr and $size) {
				die " chromosome sizes file doesn't look right!\n";
			}
			unless ($size =~ /^\d+$/) {
				die " chromosome $chr length is non-numeric!\n";
			}
			$sizes{$chr} = $size;
		}
		$fh->close;
		
		# set key to indicate this was a user provided file
		$sizes{'deleteMe'} = 0;
	}
	
	# from database
	elsif ($database) {
		
		# open connection
		my $db = open_db_connection($database) or 
			die " unable to open database connection to '$database'!\n";
		
		# determine reference sequence type
		my $ref_seq_type = 
			$TIM_CONFIG->param("$database\.reference_sequence_type") ||
			$TIM_CONFIG->param('default_db.reference_sequence_type') ||
			'chromosome'; # relatively safe default
		
		# collect the reference sequences
		my @chromos = $db->features(-type => $ref_seq_type);
		unless (@chromos) {
			die " no '$ref_seq_type' features identified in database!\n";
		}
		
		# collect lengths
		foreach (@chromos) {
			my $chr = $_->name;
			my $size = $_->length;
			$sizes{$chr} = $size;
		}
		
		# we're going to need the chromosome sizes file, 
		# so go ahead and write it now
		my $chr_fh = new File::Temp(
			'UNLINK'   => 0,
			'TEMPLATE' => 'chr_sizesXXXXX',
		);
		$chromo_file = $chr_fh->filename;
		foreach my $chr (sort {$a cmp $b} keys %sizes) {
			$chr_fh->print("$chr\t$sizes{$chr}\n");
		}
		$chr_fh->close;
		
		# set key to indicate this is a temporary chromosome file to be deleted
		$sizes{'deleteMe'} = 1;
	}
	
	return %sizes;
}



sub convert_to_bedgraph {
	my $bedfile = shift;
	
	# open input bed file
	my $bed_fh = open_to_read_fh($bedfile) or 
		die " unable to open bed file '$bedfile'!\n";
	
	# generate outfile name
	unless ($outfile) {
		$outfile = $infile;
		$outfile =~ s/\.bed$//;
	}
	unless ($outfile =~ /\.bedgraph$/) {
		$outfile .= '.bedgraph';
	}
	my $out_fh = open_to_write_fh($outfile) or 
		die " unable to open output file '$outfile'!\n";
	
	# convert to bedgraph
	# check the file for coordinate problems
	my $previous_pos;
	my @scores;
	while (my $line = $bed_fh->getline) {
		next if $line =~ /^#/;
		
		chomp $line;
		my @data = split /\t/, $line;
		
		# check strand
		if ($strand) {
			# we need to skip specific strand combinations
			next if ($strand eq 'f' and $data[5] eq '-');
			next if ($strand eq 'r' and $data[5] eq '+');
		}

		# verify we're still on the chromosome
		unless (exists $chrom_sizes{ $data[0] }) {
			die " no chromosome length recorded for chromosome '$data[0]'!\n";
		}
		if ($data[1] > $chrom_sizes{ $data[0] } ) {
			# the start position is off the end of the chromosome!
			next;
		}
		elsif ($data[2] > $chrom_sizes{ $data[0] } ) {
			# the end position is off the end of the chromosome!
			# set to the end?
			$data[2] = $chrom_sizes{ $data[0] };
		}

		# since we're working with a bedgraph that has both start and stop
		# positions, we'll simply record both
		# but first need to verify there are no duplicates
		if (defined $previous_pos) {
			my $position = $data[0] . ':' . $data[1] . ':' . $data[2];
			
			# check with the same position or different
			if ($position eq $previous_pos) {
				# we have a duplicate position
				# add the score
				push @scores, $data[4];
			}
			else {
				# non duplicate position
				# we can now write the previous value
				
				# get the score for the previous position(s)
				my $score;
				if (scalar @scores > 1) {
					$score = &{$method_sub}(@scores);
				}
				else {
					$score = shift @scores;
				}
				
				# break out the coordinates
				my ($chr, $start, $end) = split /:/, $previous_pos;
				
				# write to the bedgraph
				$out_fh->print( 
					join("\t", ($chr, $start, $end, $score) ) . "\n" );
				
				# now add the current line data
				$previous_pos = $position;
				@scores = ( $data[4] );
			}
		}
		
		# not defined previous position
		else {
			$previous_pos = $data[0] . ':' . $data[1] . ':' . $data[2];
			@scores = ( $data[4] );
		}
		
	}
	
	# done with the files
	$bed_fh->close;
	$out_fh->close;
	
	# now convert to bigwig
	my $bw_file = wig_to_bigwig_conversion( {
		'wig'       => $outfile,
		'chromo'    => $chromo_file,
		'bwapppath' => $big_app_path,
	} );
	
	if ($bw_file) {
		# a bigwig file was successfully generated
		unlink $outfile; # no longer need the converted bedgraph file
	}
	return $bw_file;
}



sub convert_to_wig {
	my $bedfile = shift;
	
	# open input bed file
	my $bed_fh = open_to_read_fh($bedfile) or 
		die " unable to open bed file '$bedfile'!\n";
	
	# generate outfile name
	unless ($outfile) {
		$outfile = $infile;
		$outfile =~ s/\.bed$//;
	}
	unless ($outfile =~ /\.wig$/) {
		$outfile .= '.wig';
	}
	my $out_fh = open_to_write_fh($outfile) or 
		die " unable to open output file '$outfile'!\n";
	
	# convert to variableStep wig file
	# we're writing a variableStep file because it's too hard to figure out 
	# if the data is fixedStep - any deviation can fail the conversion
	# check the file for coordinate problems
	my $previous_chr;
	my $previous_pos;
	my @scores;
	while (my $line = $bed_fh->getline) {
		next if $line =~ /^#/;
		
		chomp $line;
		my @data = split /\t/, $line;
		
		# check strand
		if ($strand) {
			# we need to skip specific strand combinations
			next if ($strand eq 'f' and $data[5] eq '-');
			next if ($strand eq 'r' and $data[5] eq '+');
		}

		# verify we're still on the chromosome
		unless (exists $chrom_sizes{ $data[0] }) {
			die " no chromosome length recorded for chromosome '$data[0]'!\n";
		}
		
		# wig files are 1-based, convert from 0-based
		$data[1] += 1;
		
		# wig files only work with one coordinate, so we're going to use 
		# the midpoint of the defined fragment
		my $position;
		if ($data[1] == $data[2]) {
			$position = $data[1];
		}
		else {
			$position = int( ($data[1] + $data[2]) / 2);
		}
		
		# check to see the coordinate isn't off the end of the chromosome
		if ($position > $chrom_sizes{ $data[0] } ) {
			# the position is off the end of the chromosome!
			next;
		}
		
		# check for duplicate data
		if (defined $previous_pos) {
			
			# check with the same position or different
			if ($position eq $previous_pos) {
				# we have a duplicate position
				# add the score
				push @scores, $data[4];
			}
			else {
				# non duplicate position
				# we can now write the previous value
				
				# get the score for the previous position(s)
				my $score;
				if (scalar @scores > 1) {
					$score = &{$method_sub}(@scores);
				}
				else {
					$score = shift @scores;
				}
				
				# write to the variableStep wig file
				$out_fh->print("$previous_pos $score\n");
				
				# now add the current line data to the running variables
				if ($previous_chr ne $data[0]) {
					# print a new definition line for a new chromosome
					$out_fh->print('variableStep chrom=' . $data[0] . "\n");
					$previous_chr = $data[0];
				}
				$previous_pos = $position;
				@scores = ( $data[4] );
			}
		}
		
		# not defined previous position
		else {
			# check whether we need to write the definition line
			if (!defined $previous_chr) {
				$out_fh->print('variableStep chrom=' . $data[0] . "\n");
				$previous_chr = $data[0];
			}
			
			# add the current position to the running previous position
			$previous_pos = $position;
			@scores = ( $data[4] );
		}
		
	}
	
	# done with the files
	$bed_fh->close;
	$out_fh->close;
	
	# now convert to bigwig
	my $bw_file = wig_to_bigwig_conversion( {
		'wig'       => $outfile,
		'chromo'    => $chromo_file,
		'bwapppath' => $big_app_path,
	} );
	
	if ($bw_file) {
		# a bigwig file was successfully generated
		unlink $outfile; # no longer need the converted wig file
	}
	return $bw_file;
}



sub convert_to_bed {
	my $bedfile = shift;
	
	# while this may seem straight forward, we still need to check for 
	# features which may extend off the end of the chromosome, which will 
	# cause the conversion to bigbed to fail
	# so we need to open up the bed file and parse through
	
	
	# open input bed file
	my $bed_fh = open_to_read_fh($bedfile) or 
		die " unable to open bed file '$bedfile'!\n";
	
	# open output bed file
	my $out_fh = new File::Temp(
		'UNLINK'   => 0,
		'TEMPLATE' => 'fixed_bedXXXXX',
		'SUFFIX'   => '.bed',
	);
	my $tempfile = $out_fh->filename;
	
	# initialize warnings
	my $non_score_warn = 0;
	my $below_0_warn = 0;
	my $above_1k_warn = 0;
	my $truncation_warn = 0;
	
	# parse
	while (my $line = $bed_fh->getline) {
		next if $line =~ /^#/;
		
		chomp $line;
		my @data = split /\t/, $line;
		
		# check strand
		if ($strand) {
			# we need to skip specific strand combinations
			next if ($strand eq 'f' and $data[5] eq '-');
			next if ($strand eq 'r' and $data[5] eq '+');
		}

		# check to see the coordinate isn't off the end of the chromosome
		if ($data[1] > $chrom_sizes{ $data[0] } ) {
			# the start position is off the end of the chromosome!
			next;
		}
		elsif ($data[2] > $chrom_sizes{ $data[0] } ) {
			# the end position is off the end of the chromosome!
			# set to the end?
			$data[2] = $chrom_sizes{ $data[0] };
		}
		
		# check the score
		if ($data[4] eq '.') {
			unless ($non_score_warn) {
				warn "  null scores of '.' not allowed, converting all to 0\n";
				$non_score_warn = 1;
			}
			# I don't think it tolerates periods
			$data[4] = 0;
		}
		elsif ($data[4] < 0) {
			unless ($below_0_warn) {
				warn "  negative scores such as '$data[4]' at line " .
					$bed_fh->tell . "\n   not allowed, converting all to 0\n";
				$below_0_warn = 1;
			}
			# set to 0 all negative scores
			$data[4] = 0;
		}
		elsif ($data[4] > 1000) {
			unless ($above_1k_warn) {
				warn "  scores above 1000 such as '$data[4]' at line " .
					$bed_fh->tell . "\n   not allowed, converting all to 1000\n";
				$above_1k_warn = 1;
			}
			# set to maximum of 1000
			$data[4] = 1000;
		}
		elsif ($data[4] =~ m/^(\d+)\..*/) {
			unless ($truncation_warn) {
				warn "  non-integer scores such as '$data[4]' at line " .
					$bed_fh->tell . "\n   not allowed, truncating all\n";
				$truncation_warn = 1;
			}
			# take only the integer value
			$data[4] = $1;
		}
		else {
			# something else!?
			warn "  unrecognized data value '$data[4]' at line " . 
				$bed_fh->tell . "! setting to 0\n";
			$data[4] = 0;
		}
		
		# check strand
		if ($data[5] eq '.') {
			# artificially constrain no strand to plus strand
			$data[5] = '+';
		}
		
		# write to temp bed file
		$out_fh->print( join("\t", @data) . "\n");
	}
	
	# done with the files
	$bed_fh->close;
	$out_fh->close;
	
	# now convert to bigwig
	my $bb_file = bed_to_bigbed_conversion( {
		'bed'       => $tempfile,
		'chromo'    => $chromo_file,
		'bbapppath' => $big_app_path,
	} );
	
	# generate outfile name
	unless ($outfile) {
		$outfile = $bedfile;
		$outfile =~ s/\.bed$//;
	}
	unless ($outfile =~ /\.bb$/) {
		$outfile .= '.bb';
	}
	
	# return
	if ($bb_file) {
		# we need to rename output bigbed file to match 
		# the requested output name
		rename $bb_file, $outfile;
		unlink $tempfile; # no longer need
		return $outfile;
	}
	else {
		return;
	}
}









__END__

=head1 NAME

useq2bigfile.pl

=head1 SYNOPSIS

useq2bigfile.pl --bw|bb [--options] <filename.useq>
  
  Options:
  --in <filename.useq>
  --bw
  --bb
  --gr
  --method [mean|median|sum|max]
  --strand [f|r]
  --chromof <chromosome_sizes_filename>
  --db <database>
  --bigapp </path/to/bigFileConverter>
  --useqapp </path/to/USeq2Text>
  --out <filename>
  --help

=head1 OPTIONS

The command line flags and descriptions:

=over 4

=item --in <filename>

Specify the input useq archive file. The file must have an .useq extension.

=item --bw

=item --bb

Specify the output format of the big file to be generated. A bigWig file (bw) 
may be generated, or a bigBed (bb) file may be generated. 

=item --gr

When generating a bigWig file, specify that a source bedgraph file should be 
written. This requires the application bedGraphToBigWig. If the source data 
represents regions (> 1 bp) with scores, it is best to use bedGraph. The 
default is to write a variableStep wig file (regions are converted to the 
midpoint position), in which case the application wigToBigWig is used instead. 

=item --method [mean|median|sum|max]

Specify the method for dealing with multiple values at identical positions. 
USeq and Bar files tolerate multiple values at identical positions, but Wig 
and BigWig files do not. Hence, the values at these positions must be combined 
mathematically. This does not apply to BigBed files. The default is to take 
the mean value.

=item --strand [f|r]

Specify that only one strand of data should be taken. The strand should be 
specified as either 'f' (forward or +) or 'r' (reverse or -). Unstranded 
data is always kept. The default is to keep all data and merge the data.

=item --chromof <chromosome_sizes_filename>

A chromosome sizes file may be provided. This is a simple text file 
comprised of two columns separated by whitespace. The first column is the 
chromosome name, the second column is the chromosome length in bp. There is 
no header. This file is required by the BigFile converter applications.

=item --db <database>

As an alternative to specifying the chromosome sizes file, a database may 
be specified from which to collect the chromosome lengths. A GFF3 file or 
SQLite database file may also be provided.

=item --bigapp </path/to/bigFileConverter>

Specify the path to the appropriate BigFile converter application. Supported 
applications include wigToBigWig, bedGraphToBigWig, and bedToBigBed. These 
may be obtained from UCSC. The default is check the tim_db_helper.cfg 
configuration file, followed by the default environment path using the 
'which' command. The appropriate utility is selected based on the selected 
output format. When generating bigWig files, the bedGraph source format can 
be specified using the --gr option.

=item --useqapp </path/to/USeq2Text>

Specify the path to David Nix's USeq2Text application, part of the USeq 
package. The default is check the tim_db_helper.cfg configuration file.

=item --out <filename>

Specify the output filename. By default it uses the input base name.

=item --help

Display this POD documentation.

=back

=head1 DESCRIPTION

This program will convert a USeq archive into a Big file format, either
bigWig or bigBed. This program is essentially a wrapper around two other
converter applications with some text manipulation in between. The first is
a java application from David Nix's USeq package, USeq2Text, which extracts
the coordinates, scores, and text from the USeq archive and writes a
6-column bed file. The bed file is then parsed to remove anomolous data and
prepared for conversion to a big file format. The second convertor
application, one of three utilities developed by Jim Kent, is then used to
convert to the appropriate big file.

Two different output formats are possible, bigWig and bigBed. The bigWig 
format is best used with data that contains scores at discrete genomic 
positions or intervals. The bigBed format can also support scores at 
discrete positions, as well as genomic intervals (features) of varying 
lengths that may or may not include text (names) and/or scores.

The intermediate bed file is screened for anomolous data, including multiple 
scores at identical genomic positions (not supported with wig, bedGraph, or 
BigWig files) and positions outside of the genomic coordinates (greater than 
the chromosome length). These will cause the conversion to a big file format 
to fail.

Two converters are supported for generating bigWig files: bedGraphToBigWig 
and wigToBigWig. The bedGraphToBigWig converter uses slightly less memory 
but generates larger bigWig files. It also handles scored regions > 1 bp. 
The wigToBigWig converter produces smaller files but requires more memory, 
and in this case only works with point data (for regions it uses the 
midpoint).

For converting to bigBed files, the bedToBigBed convertor is used. Note
that bigBed files have stricter requirements for the score value, which
should be an integer between 0 and 1000. Score values which do not meet
these requirements are converted and warnings are issued. If these are
important to you, you may wish to manually scale the scores using
L<manipulate_datasets.pl> or convert to bigWig instead.

More information about bigWig files may be found here L<
http://genome.ucsc.edu/goldenPath/help/bigWig.html>. More information about 
bigBed files may be found here 
L<http://genome.ucsc.edu/goldenPath/help/bigBed.html>. More information about 
the USeq archive may be found here L<
http://useq.sourceforge.net/useqArchiveFormat.html>.



=head1 AUTHOR

 Timothy J. Parnell, PhD
 Howard Hughes Medical Institute
 Dept of Oncological Sciences
 Huntsman Cancer Institute
 University of Utah
 Salt Lake City, UT, 84112

This package is free software; you can redistribute it and/or modify
it under the terms of the GPL (either version 1, or at your option,
any later version) or the Artistic License 2.0.  
