#!/usr/bin/perl
#----------------------------------------------------------------------
#
# Generate node support files:
# - nodetags.h
# - copyfuncs
# - equalfuncs
# - readfuncs
# - outfuncs
#
# Portions Copyright (c) 1996-2022, PostgreSQL Global Development Group
# Portions Copyright (c) 1994, Regents of the University of California
#
# src/backend/nodes/gen_node_support.pl
#
#----------------------------------------------------------------------

use strict;
use warnings;

use File::Basename;

use FindBin;
use lib "$FindBin::RealBin/../catalog";

use Catalog;    # for RenameTempFile


# Test whether first argument is element of the list in the second
# argument
sub elem
{
	my $x = shift;
	return grep { $_ eq $x } @_;
}


# This list defines the canonical set of header files to be read by this
# script, and the order they are to be processed in.  We must have a stable
# processing order, else the NodeTag enum's order will vary, with catastrophic
# consequences for ABI stability across different builds.
#
# Currently, the various build systems also have copies of this list,
# so that they can do dependency checking properly.  In future we may be
# able to make this list the only copy.  For now, we just check that
# it matches the list of files passed on the command line.
my @all_input_files = qw(
  nodes/nodes.h
  nodes/primnodes.h
  nodes/parsenodes.h
  nodes/pathnodes.h
  nodes/plannodes.h
  nodes/execnodes.h
  access/amapi.h
  access/sdir.h
  access/tableam.h
  access/tsmapi.h
  commands/event_trigger.h
  commands/trigger.h
  executor/tuptable.h
  foreign/fdwapi.h
  nodes/extensible.h
  nodes/lockoptions.h
  nodes/replnodes.h
  nodes/supportnodes.h
  nodes/value.h
  utils/rel.h
);

# Nodes from these input files are automatically treated as nodetag_only.
# In the future we might add explicit pg_node_attr labeling to some of these
# files and remove them from this list, but for now this is the path of least
# resistance.
my @nodetag_only_files = qw(
  nodes/execnodes.h
  access/amapi.h
  access/sdir.h
  access/tableam.h
  access/tsmapi.h
  commands/event_trigger.h
  commands/trigger.h
  executor/tuptable.h
  foreign/fdwapi.h
  nodes/lockoptions.h
  nodes/replnodes.h
  nodes/supportnodes.h
);

# ARM ABI STABILITY CHECK HERE:
#
# In stable branches, set $last_nodetag to the name of the last node type
# that should receive an auto-generated nodetag number, and $last_nodetag_no
# to its number.  (Find these values in the last line of the current
# nodetags.h file.)  The script will then complain if those values don't
# match reality, providing a cross-check that we haven't broken ABI by
# adding or removing nodetags.
# In HEAD, these variables should be left undef, since we don't promise
# ABI stability during development.

my $last_nodetag    = undef;
my $last_nodetag_no = undef;

# output file names
my @output_files;

# collect node names
my @node_types = qw(Node);
# collect info for each node type
my %node_type_info;

# node types we don't want copy support for
my @no_copy;
# node types we don't want equal support for
my @no_equal;
# node types we don't want read support for
my @no_read;
# node types we don't want read/write support for
my @no_read_write;
# node types we don't want any support functions for, just node tags
my @nodetag_only;

# types that are copied by straight assignment
my @scalar_types = qw(
  bits32 bool char double int int8 int16 int32 int64 long uint8 uint16 uint32 uint64
  AclMode AttrNumber Cardinality Cost Index Oid RelFileNumber Selectivity Size StrategyNumber SubTransactionId TimeLineID XLogRecPtr
);

# collect enum types
my @enum_types;

# collect types that are abstract (hence no node tag, no support functions)
my @abstract_types = qw(Node);

# Special cases that either don't have their own struct or the struct
# is not in a header file.  We generate node tags for them, but
# they otherwise don't participate in node support.
my @extra_tags = qw(
  IntList OidList XidList
  AllocSetContext GenerationContext SlabContext
  TIDBitmap
  WindowObjectData
);

# This is a regular node, but we skip parsing it from its header file
# since we won't use its internal structure here anyway.
push @node_types, qw(List);
# Lists are specially treated in all four support files, too.
push @no_copy,       qw(List);
push @no_equal,      qw(List);
push @no_read_write, qw(List);

# Nodes with custom copy/equal implementations are skipped from
# .funcs.c but need case statements in .switch.c.
my @custom_copy_equal;

# Similarly for custom read/write implementations.
my @custom_read_write;

# Track node types with manually assigned NodeTag numbers.
my %manual_nodetag_number;

# EquivalenceClasses are never moved, so just shallow-copy the pointer
push @scalar_types, qw(EquivalenceClass* EquivalenceMember*);

# This is a struct, so we can copy it by assignment.  Equal support is
# currently not required.
push @scalar_types, qw(QualCost);

# XXX various things we are not publishing right now to stay level
# with the manual system
push @no_read_write,
  qw(AccessPriv AlterTableCmd CreateOpClassItem FunctionParameter InferClause ObjectWithArgs OnConflictClause PartitionCmd RoleSpec VacuumRelation);
push @no_read, qw(A_ArrayExpr A_Indices A_Indirection AlterStatsStmt
  CollateClause ColumnDef ColumnRef CreateForeignTableStmt CreateStatsStmt
  CreateStmt FuncCall ImportForeignSchemaStmt IndexElem IndexStmt
  JsonAggConstructor JsonArgument JsonArrayAgg JsonArrayConstructor
  JsonArrayQueryConstructor JsonCommon JsonFuncExpr JsonKeyValue
  JsonObjectAgg JsonObjectConstructor JsonOutput JsonParseExpr JsonScalarExpr
  JsonSerializeExpr JsonTable JsonTableColumn JsonTablePlan LockingClause
  MultiAssignRef PLAssignStmt ParamRef PartitionElem PartitionSpec
  PlaceHolderVar PublicationObjSpec PublicationTable RangeFunction
  RangeSubselect RangeTableFunc RangeTableFuncCol RangeTableSample RawStmt
  ResTarget ReturnStmt SelectStmt SortBy StatsElem TableLikeClause
  TriggerTransition TypeCast TypeName WindowDef WithClause XmlSerialize);


## check that we have the expected number of files on the command line
die "wrong number of input files, expected @all_input_files\n"
  if ($#ARGV != $#all_input_files);

## read input

my $next_input_file = 0;
foreach my $infile (@ARGV)
{
	my $in_struct;
	my $subline;
	my $is_node_struct;
	my $supertype;
	my $supertype_field;

	my $node_attrs = '';
	my $node_attrs_lineno;
	my @my_fields;
	my %my_field_types;
	my %my_field_attrs;

	# open file with name from command line, which may have a path prefix
	open my $ifh, '<', $infile or die "could not open \"$infile\": $!";

	# now shorten filename for use below
	$infile =~ s!.*src/include/!!;

	# check it against next member of @all_input_files
	die "wrong input file ordering, expected @all_input_files\n"
	  if ($infile ne $all_input_files[$next_input_file]);
	$next_input_file++;

	my $raw_file_content = do { local $/; <$ifh> };

	# strip C comments, preserving newlines so we can count lines correctly
	my $file_content = '';
	while ($raw_file_content =~ m{^(.*?)(/\*.*?\*/)(.*)$}s)
	{
		$file_content .= $1;
		my $comment = $2;
		$raw_file_content = $3;
		$comment =~ tr/\n//cd;
		$file_content .= $comment;
	}
	$file_content .= $raw_file_content;

	my $lineno = 0;
	foreach my $line (split /\n/, $file_content)
	{
		$lineno++;
		chomp $line;
		$line =~ s/\s*$//;
		next if $line eq '';
		next if $line =~ /^#(define|ifdef|endif)/;

		# we are analyzing a struct definition
		if ($in_struct)
		{
			$subline++;

			# first line should have opening brace
			if ($subline == 1)
			{
				$is_node_struct = 0;
				$supertype      = undef;
				next if $line eq '{';
				die "$infile:$lineno: expected opening brace\n";
			}
			# second line could be node attributes
			elsif ($subline == 2
				&& $line =~ /^\s*pg_node_attr\(([\w(), ]*)\)$/)
			{
				$node_attrs        = $1;
				$node_attrs_lineno = $lineno;
				# hack: don't count the line
				$subline--;
				next;
			}
			# next line should have node tag or supertype
			elsif ($subline == 2)
			{
				if ($line =~ /^\s*NodeTag\s+type;/)
				{
					$is_node_struct = 1;
					next;
				}
				elsif ($line =~ /\s*(\w+)\s+(\w+);/ and elem $1, @node_types)
				{
					$is_node_struct  = 1;
					$supertype       = $1;
					$supertype_field = $2;
					next;
				}
			}

			# end of struct
			if ($line =~ /^\}\s*(?:\Q$in_struct\E\s*)?;$/)
			{
				if ($is_node_struct)
				{
					# This is the end of a node struct definition.
					# Save everything we have collected.

					foreach my $attr (split /,\s*/, $node_attrs)
					{
						if ($attr eq 'abstract')
						{
							push @abstract_types, $in_struct;
						}
						elsif ($attr eq 'custom_copy_equal')
						{
							push @custom_copy_equal, $in_struct;
						}
						elsif ($attr eq 'custom_read_write')
						{
							push @custom_read_write, $in_struct;
						}
						elsif ($attr eq 'no_copy')
						{
							push @no_copy, $in_struct;
						}
						elsif ($attr eq 'no_equal')
						{
							push @no_equal, $in_struct;
						}
						elsif ($attr eq 'no_copy_equal')
						{
							push @no_copy,  $in_struct;
							push @no_equal, $in_struct;
						}
						elsif ($attr eq 'no_read')
						{
							push @no_read, $in_struct;
						}
						elsif ($attr eq 'nodetag_only')
						{
							push @nodetag_only, $in_struct;
						}
						elsif ($attr eq 'special_read_write')
						{
							# This attribute is called
							# "special_read_write" because there is
							# special treatment in outNode() and
							# nodeRead() for these nodes.  For this
							# script, it's the same as
							# "no_read_write", but calling the
							# attribute that externally would probably
							# be confusing, since read/write support
							# does in fact exist.
							push @no_read_write, $in_struct;
						}
						elsif ($attr =~ /^nodetag_number\((\d+)\)$/)
						{
							$manual_nodetag_number{$in_struct} = $1;
						}
						else
						{
							die
							  "$infile:$node_attrs_lineno: unrecognized attribute \"$attr\"\n";
						}
					}

					# node name
					push @node_types, $in_struct;

					# field names, types, attributes
					my @f  = @my_fields;
					my %ft = %my_field_types;
					my %fa = %my_field_attrs;

					# If there is a supertype, add those fields, too.
					if ($supertype)
					{
						my @superfields;
						foreach
						  my $sf (@{ $node_type_info{$supertype}->{fields} })
						{
							my $fn = "${supertype_field}.$sf";
							push @superfields, $fn;
							$ft{$fn} =
							  $node_type_info{$supertype}->{field_types}{$sf};
							if ($node_type_info{$supertype}
								->{field_attrs}{$sf})
							{
								# Copy any attributes, adjusting array_size field references
								my @newa = @{ $node_type_info{$supertype}
									  ->{field_attrs}{$sf} };
								foreach my $a (@newa)
								{
									$a =~
									  s/array_size\((\w+)\)/array_size(${supertype_field}.$1)/;
								}
								$fa{$fn} = \@newa;
							}
						}
						unshift @f, @superfields;
					}
					# save in global info structure
					$node_type_info{$in_struct}->{fields}      = \@f;
					$node_type_info{$in_struct}->{field_types} = \%ft;
					$node_type_info{$in_struct}->{field_attrs} = \%fa;

					# Propagate nodetag_only marking from files to nodes
					push @nodetag_only, $in_struct
					  if (elem $infile, @nodetag_only_files);

					# Propagate some node attributes from supertypes
					if ($supertype)
					{
						push @no_copy, $in_struct
						  if elem $supertype, @no_copy;
						push @no_equal, $in_struct
						  if elem $supertype, @no_equal;
						push @no_read, $in_struct
						  if elem $supertype, @no_read;
					}
				}

				# start new cycle
				$in_struct      = undef;
				$node_attrs     = '';
				@my_fields      = ();
				%my_field_types = ();
				%my_field_attrs = ();
			}
			# normal struct field
			elsif ($line =~
				/^\s*(.+)\s*\b(\w+)(\[\w+\])?\s*(?:pg_node_attr\(([\w(), ]*)\))?;/
			  )
			{
				if ($is_node_struct)
				{
					my $type       = $1;
					my $name       = $2;
					my $array_size = $3;
					my $attrs      = $4;

					# strip "const"
					$type =~ s/^const\s*//;
					# strip trailing space
					$type =~ s/\s*$//;
					# strip space between type and "*" (pointer) */
					$type =~ s/\s+\*$/*/;

					die
					  "$infile:$lineno: cannot parse data type in \"$line\"\n"
					  if $type eq '';

					my @attrs;
					if ($attrs)
					{
						@attrs = split /,\s*/, $attrs;
						foreach my $attr (@attrs)
						{
							if (   $attr !~ /^array_size\(\w+\)$/
								&& $attr !~ /^copy_as\(\w+\)$/
								&& $attr !~ /^read_as\(\w+\)$/
								&& !elem $attr,
								qw(equal_ignore equal_ignore_if_zero read_write_ignore
								write_only_relids write_only_nondefault_pathtarget write_only_req_outer)
							  )
							{
								die
								  "$infile:$lineno: unrecognized attribute \"$attr\"\n";
							}
						}
					}

					$type = $type . $array_size if $array_size;
					push @my_fields, $name;
					$my_field_types{$name} = $type;
					$my_field_attrs{$name} = \@attrs;
				}
			}
			else
			{
				if ($is_node_struct)
				{
					#warn "$infile:$lineno: could not parse \"$line\"\n";
				}
			}
		}
		# not in a struct
		else
		{
			# start of a struct?
			if ($line =~ /^(?:typedef )?struct (\w+)$/ && $1 ne 'Node')
			{
				$in_struct = $1;
				$subline   = 0;
			}
			# one node type typedef'ed directly from another
			elsif ($line =~ /^typedef (\w+) (\w+);$/ and elem $1, @node_types)
			{
				my $alias_of = $1;
				my $n        = $2;

				# copy everything over
				push @node_types, $n;
				my @f  = @{ $node_type_info{$alias_of}->{fields} };
				my %ft = %{ $node_type_info{$alias_of}->{field_types} };
				my %fa = %{ $node_type_info{$alias_of}->{field_attrs} };
				$node_type_info{$n}->{fields}      = \@f;
				$node_type_info{$n}->{field_types} = \%ft;
				$node_type_info{$n}->{field_attrs} = \%fa;
			}
			# collect enum names
			elsif ($line =~ /^typedef enum (\w+)(\s*\/\*.*)?$/)
			{
				push @enum_types, $1;
			}
		}
	}

	if ($in_struct)
	{
		die "runaway \"$in_struct\" in file \"$infile\"\n";
	}

	close $ifh;
}    # for each file


## write output

my $tmpext = ".tmp$$";

# opening boilerplate for output files
my $header_comment =
  '/*-------------------------------------------------------------------------
 *
 * %s
 *    Generated node infrastructure code
 *
 * Portions Copyright (c) 1996-2022, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * NOTES
 *  ******************************
 *  *** DO NOT EDIT THIS FILE! ***
 *  ******************************
 *
 *  It has been GENERATED by src/backend/nodes/gen_node_support.pl
 *
 *-------------------------------------------------------------------------
 */
';


# nodetags.h

push @output_files, 'nodetags.h';
open my $nt, '>', 'nodetags.h' . $tmpext or die $!;

printf $nt $header_comment, 'nodetags.h';

my $tagno    = 0;
my $last_tag = undef;
foreach my $n (@node_types, @extra_tags)
{
	next if elem $n, @abstract_types;
	if (defined $manual_nodetag_number{$n})
	{
		# do not change $tagno or $last_tag
		print $nt "\tT_${n} = $manual_nodetag_number{$n},\n";
	}
	else
	{
		$tagno++;
		$last_tag = $n;
		print $nt "\tT_${n} = $tagno,\n";
	}
}

# verify that last auto-assigned nodetag stays stable
die "ABI stability break: last nodetag is $last_tag not $last_nodetag\n"
  if (defined $last_nodetag && $last_nodetag ne $last_tag);
die
  "ABI stability break: last nodetag number is $tagno not $last_nodetag_no\n"
  if (defined $last_nodetag_no && $last_nodetag_no != $tagno);

close $nt;


# make #include lines necessary to pull in all the struct definitions
my $node_includes = '';
foreach my $infile (sort @ARGV)
{
	$infile =~ s!.*src/include/!!;
	$node_includes .= qq{#include "$infile"\n};
}


# copyfuncs.c, equalfuncs.c

push @output_files, 'copyfuncs.funcs.c';
open my $cff, '>', 'copyfuncs.funcs.c' . $tmpext or die $!;
push @output_files, 'equalfuncs.funcs.c';
open my $eff, '>', 'equalfuncs.funcs.c' . $tmpext or die $!;
push @output_files, 'copyfuncs.switch.c';
open my $cfs, '>', 'copyfuncs.switch.c' . $tmpext or die $!;
push @output_files, 'equalfuncs.switch.c';
open my $efs, '>', 'equalfuncs.switch.c' . $tmpext or die $!;

printf $cff $header_comment, 'copyfuncs.funcs.c';
printf $eff $header_comment, 'equalfuncs.funcs.c';
printf $cfs $header_comment, 'copyfuncs.switch.c';
printf $efs $header_comment, 'equalfuncs.switch.c';

# add required #include lines to each file set
print $cff $node_includes;
print $eff $node_includes;

foreach my $n (@node_types)
{
	next if elem $n, @abstract_types;
	next if elem $n, @nodetag_only;
	my $struct_no_copy  = (elem $n, @no_copy);
	my $struct_no_equal = (elem $n, @no_equal);
	next if $struct_no_copy && $struct_no_equal;

	print $cfs "\t\tcase T_${n}:\n"
	  . "\t\t\tretval = _copy${n}(from);\n"
	  . "\t\t\tbreak;\n"
	  unless $struct_no_copy;

	print $efs "\t\tcase T_${n}:\n"
	  . "\t\t\tretval = _equal${n}(a, b);\n"
	  . "\t\t\tbreak;\n"
	  unless $struct_no_equal;

	next if elem $n, @custom_copy_equal;

	print $cff "
static $n *
_copy${n}(const $n *from)
{
\t${n} *newnode = makeNode($n);

" unless $struct_no_copy;

	print $eff "
static bool
_equal${n}(const $n *a, const $n *b)
{
" unless $struct_no_equal;

	# print instructions for each field
	foreach my $f (@{ $node_type_info{$n}->{fields} })
	{
		my $t            = $node_type_info{$n}->{field_types}{$f};
		my @a            = @{ $node_type_info{$n}->{field_attrs}{$f} };
		my $copy_ignore  = $struct_no_copy;
		my $equal_ignore = $struct_no_equal;

		# extract per-field attributes
		my $array_size_field;
		my $copy_as_field;
		foreach my $a (@a)
		{
			if ($a =~ /^array_size\(([\w.]+)\)$/)
			{
				$array_size_field = $1;
			}
			elsif ($a =~ /^copy_as\(([\w.]+)\)$/)
			{
				$copy_as_field = $1;
			}
			elsif ($a eq 'equal_ignore')
			{
				$equal_ignore = 1;
			}
		}

		# override type-specific copy method if copy_as is specified
		if (defined $copy_as_field)
		{
			print $cff "\tnewnode->$f = $copy_as_field;\n"
			  unless $copy_ignore;
			$copy_ignore = 1;
		}

		# select instructions by field type
		if ($t eq 'char*')
		{
			print $cff "\tCOPY_STRING_FIELD($f);\n"    unless $copy_ignore;
			print $eff "\tCOMPARE_STRING_FIELD($f);\n" unless $equal_ignore;
		}
		elsif ($t eq 'Bitmapset*' || $t eq 'Relids')
		{
			print $cff "\tCOPY_BITMAPSET_FIELD($f);\n" unless $copy_ignore;
			print $eff "\tCOMPARE_BITMAPSET_FIELD($f);\n"
			  unless $equal_ignore;
		}
		elsif ($t eq 'int' && $f =~ 'location$')
		{
			print $cff "\tCOPY_LOCATION_FIELD($f);\n"    unless $copy_ignore;
			print $eff "\tCOMPARE_LOCATION_FIELD($f);\n" unless $equal_ignore;
		}
		elsif (elem $t, @scalar_types or elem $t, @enum_types)
		{
			print $cff "\tCOPY_SCALAR_FIELD($f);\n" unless $copy_ignore;
			if (elem 'equal_ignore_if_zero', @a)
			{
				print $eff
				  "\tif (a->$f != b->$f && a->$f != 0 && b->$f != 0)\n\t\treturn false;\n";
			}
			else
			{
				# All CoercionForm fields are treated as equal_ignore
				print $eff "\tCOMPARE_SCALAR_FIELD($f);\n"
				  unless $equal_ignore || $t eq 'CoercionForm';
			}
		}
		# scalar type pointer
		elsif ($t =~ /(\w+)\*/ and elem $1, @scalar_types)
		{
			my $tt = $1;
			if (!defined $array_size_field)
			{
				die "no array size defined for $n.$f of type $t\n";
			}
			if ($node_type_info{$n}->{field_types}{$array_size_field} eq
				'List*')
			{
				print $cff
				  "\tCOPY_POINTER_FIELD($f, list_length(from->$array_size_field) * sizeof($tt));\n"
				  unless $copy_ignore;
				print $eff
				  "\tCOMPARE_POINTER_FIELD($f, list_length(a->$array_size_field) * sizeof($tt));\n"
				  unless $equal_ignore;
			}
			else
			{
				print $cff
				  "\tCOPY_POINTER_FIELD($f, from->$array_size_field * sizeof($tt));\n"
				  unless $copy_ignore;
				print $eff
				  "\tCOMPARE_POINTER_FIELD($f, a->$array_size_field * sizeof($tt));\n"
				  unless $equal_ignore;
			}
		}
		# node type
		elsif ($t =~ /(\w+)\*/ and elem $1, @node_types)
		{
			print $cff "\tCOPY_NODE_FIELD($f);\n"    unless $copy_ignore;
			print $eff "\tCOMPARE_NODE_FIELD($f);\n" unless $equal_ignore;
		}
		# array (inline)
		elsif ($t =~ /\w+\[/)
		{
			print $cff "\tCOPY_ARRAY_FIELD($f);\n"    unless $copy_ignore;
			print $eff "\tCOMPARE_ARRAY_FIELD($f);\n" unless $equal_ignore;
		}
		elsif ($t eq 'struct CustomPathMethods*'
			|| $t eq 'struct CustomScanMethods*')
		{
			# Fields of these types are required to be a pointer to a
			# static table of callback functions.  So we don't copy
			# the table itself, just reference the original one.
			print $cff "\tCOPY_SCALAR_FIELD($f);\n"    unless $copy_ignore;
			print $eff "\tCOMPARE_SCALAR_FIELD($f);\n" unless $equal_ignore;
		}
		else
		{
			die
			  "could not handle type \"$t\" in struct \"$n\" field \"$f\"\n";
		}
	}

	print $cff "
\treturn newnode;
}
" unless $struct_no_copy;
	print $eff "
\treturn true;
}
" unless $struct_no_equal;
}

close $cff;
close $eff;
close $cfs;
close $efs;


# outfuncs.c, readfuncs.c

push @output_files, 'outfuncs.funcs.c';
open my $off, '>', 'outfuncs.funcs.c' . $tmpext or die $!;
push @output_files, 'readfuncs.funcs.c';
open my $rff, '>', 'readfuncs.funcs.c' . $tmpext or die $!;
push @output_files, 'outfuncs.switch.c';
open my $ofs, '>', 'outfuncs.switch.c' . $tmpext or die $!;
push @output_files, 'readfuncs.switch.c';
open my $rfs, '>', 'readfuncs.switch.c' . $tmpext or die $!;

printf $off $header_comment, 'outfuncs.funcs.c';
printf $rff $header_comment, 'readfuncs.funcs.c';
printf $ofs $header_comment, 'outfuncs.switch.c';
printf $rfs $header_comment, 'readfuncs.switch.c';

print $off $node_includes;
print $rff $node_includes;

foreach my $n (@node_types)
{
	next if elem $n, @abstract_types;
	next if elem $n, @nodetag_only;
	next if elem $n, @no_read_write;

	# XXX For now, skip all "Stmt"s except that ones that were there before.
	if ($n =~ /Stmt$/)
	{
		my @keep =
		  qw(AlterStatsStmt CreateForeignTableStmt CreateStatsStmt CreateStmt DeclareCursorStmt ImportForeignSchemaStmt IndexStmt NotifyStmt PlannedStmt PLAssignStmt RawStmt ReturnStmt SelectStmt SetOperationStmt);
		next unless elem $n, @keep;
	}

	my $no_read = (elem $n, @no_read);

	# output format starts with upper case node type name
	my $N = uc $n;

	print $ofs "\t\t\tcase T_${n}:\n"
	  . "\t\t\t\t_out${n}(str, obj);\n"
	  . "\t\t\t\tbreak;\n";

	print $rfs "\telse if (MATCH(\"$N\", "
	  . length($N) . "))\n"
	  . "\t\treturn_value = _read${n}();\n"
	  unless $no_read;

	next if elem $n, @custom_read_write;

	print $off "
static void
_out${n}(StringInfo str, const $n *node)
{
\tWRITE_NODE_TYPE(\"$N\");

";

	print $rff "
static $n *
_read${n}(void)
{
\tREAD_LOCALS($n);

" unless $no_read;

	# print instructions for each field
	foreach my $f (@{ $node_type_info{$n}->{fields} })
	{
		my $t = $node_type_info{$n}->{field_types}{$f};
		my @a = @{ $node_type_info{$n}->{field_attrs}{$f} };

		# extract per-field attributes
		my $read_write_ignore = 0;
		my $read_as_field;
		foreach my $a (@a)
		{
			if ($a =~ /^read_as\(([\w.]+)\)$/)
			{
				$read_as_field = $1;
			}
			elsif ($a eq 'read_write_ignore')
			{
				$read_write_ignore = 1;
			}
		}

		if ($read_write_ignore)
		{
			# nothing to do if no_read
			next if $no_read;
			# for read_write_ignore with read_as(), emit the appropriate
			# assignment on the read side and move on.
			if (defined $read_as_field)
			{
				print $rff "\tlocal_node->$f = $read_as_field;\n";
				next;
			}
			# else, bad specification
			die "$n.$f must not be marked read_write_ignore\n";
		}

		# select instructions by field type
		if ($t eq 'bool')
		{
			print $off "\tWRITE_BOOL_FIELD($f);\n";
			print $rff "\tREAD_BOOL_FIELD($f);\n" unless $no_read;
		}
		elsif ($t eq 'int' && $f =~ 'location$')
		{
			print $off "\tWRITE_LOCATION_FIELD($f);\n";
			print $rff "\tREAD_LOCATION_FIELD($f);\n" unless $no_read;
		}
		elsif ($t eq 'int'
			|| $t eq 'int32'
			|| $t eq 'AttrNumber'
			|| $t eq 'StrategyNumber')
		{
			print $off "\tWRITE_INT_FIELD($f);\n";
			print $rff "\tREAD_INT_FIELD($f);\n" unless $no_read;
		}
		elsif ($t eq 'uint32'
			|| $t eq 'bits32'
			|| $t eq 'AclMode'
			|| $t eq 'BlockNumber'
			|| $t eq 'Index'
			|| $t eq 'SubTransactionId')
		{
			print $off "\tWRITE_UINT_FIELD($f);\n";
			print $rff "\tREAD_UINT_FIELD($f);\n" unless $no_read;
		}
		elsif ($t eq 'uint64')
		{
			print $off "\tWRITE_UINT64_FIELD($f);\n";
			print $rff "\tREAD_UINT64_FIELD($f);\n" unless $no_read;
		}
		elsif ($t eq 'Oid' || $t eq 'RelFileNumber')
		{
			print $off "\tWRITE_OID_FIELD($f);\n";
			print $rff "\tREAD_OID_FIELD($f);\n" unless $no_read;
		}
		elsif ($t eq 'long')
		{
			print $off "\tWRITE_LONG_FIELD($f);\n";
			print $rff "\tREAD_LONG_FIELD($f);\n" unless $no_read;
		}
		elsif ($t eq 'char')
		{
			print $off "\tWRITE_CHAR_FIELD($f);\n";
			print $rff "\tREAD_CHAR_FIELD($f);\n" unless $no_read;
		}
		elsif ($t eq 'double')
		{
			print $off "\tWRITE_FLOAT_FIELD($f, \"%.6f\");\n";
			print $rff "\tREAD_FLOAT_FIELD($f);\n" unless $no_read;
		}
		elsif ($t eq 'Cardinality')
		{
			print $off "\tWRITE_FLOAT_FIELD($f, \"%.0f\");\n";
			print $rff "\tREAD_FLOAT_FIELD($f);\n" unless $no_read;
		}
		elsif ($t eq 'Cost')
		{
			print $off "\tWRITE_FLOAT_FIELD($f, \"%.2f\");\n";
			print $rff "\tREAD_FLOAT_FIELD($f);\n" unless $no_read;
		}
		elsif ($t eq 'QualCost')
		{
			print $off "\tWRITE_FLOAT_FIELD($f.startup, \"%.2f\");\n";
			print $off "\tWRITE_FLOAT_FIELD($f.per_tuple, \"%.2f\");\n";
			print $rff "\tREAD_FLOAT_FIELD($f.startup);\n"   unless $no_read;
			print $rff "\tREAD_FLOAT_FIELD($f.per_tuple);\n" unless $no_read;
		}
		elsif ($t eq 'Selectivity')
		{
			print $off "\tWRITE_FLOAT_FIELD($f, \"%.4f\");\n";
			print $rff "\tREAD_FLOAT_FIELD($f);\n" unless $no_read;
		}
		elsif ($t eq 'char*')
		{
			print $off "\tWRITE_STRING_FIELD($f);\n";
			print $rff "\tREAD_STRING_FIELD($f);\n" unless $no_read;
		}
		elsif ($t eq 'Bitmapset*' || $t eq 'Relids')
		{
			print $off "\tWRITE_BITMAPSET_FIELD($f);\n";
			print $rff "\tREAD_BITMAPSET_FIELD($f);\n" unless $no_read;
		}
		elsif (elem $t, @enum_types)
		{
			print $off "\tWRITE_ENUM_FIELD($f, $t);\n";
			print $rff "\tREAD_ENUM_FIELD($f, $t);\n" unless $no_read;
		}
		# arrays
		elsif ($t =~ /(\w+)(\*|\[)/ and elem $1, @scalar_types)
		{
			my $tt = uc $1;
			my $array_size_field;
			foreach my $a (@a)
			{
				if ($a =~ /^array_size\(([\w.]+)\)$/)
				{
					$array_size_field = $1;
					last;
				}
			}
			if (!defined $array_size_field)
			{
				die "no array size defined for $n.$f of type $t\n";
			}
			if ($node_type_info{$n}->{field_types}{$array_size_field} eq
				'List*')
			{
				print $off
				  "\tWRITE_${tt}_ARRAY($f, list_length(node->$array_size_field));\n";
				print $rff
				  "\tREAD_${tt}_ARRAY($f, list_length(local_node->$array_size_field));\n"
				  unless $no_read;
			}
			else
			{
				print $off
				  "\tWRITE_${tt}_ARRAY($f, node->$array_size_field);\n";
				print $rff
				  "\tREAD_${tt}_ARRAY($f, local_node->$array_size_field);\n"
				  unless $no_read;
			}
		}
		# Special treatments of several Path node fields
		elsif ($t eq 'RelOptInfo*' && elem 'write_only_relids', @a)
		{
			print $off
			  "\tappendStringInfoString(str, \" :parent_relids \");\n"
			  . "\toutBitmapset(str, node->$f->relids);\n";
		}
		elsif ($t eq 'PathTarget*' && elem 'write_only_nondefault_pathtarget',
			@a)
		{
			(my $f2 = $f) =~ s/pathtarget/parent/;
			print $off "\tif (node->$f != node->$f2->reltarget)\n"
			  . "\t\tWRITE_NODE_FIELD($f);\n";
		}
		elsif ($t eq 'ParamPathInfo*' && elem 'write_only_req_outer', @a)
		{
			print $off
			  "\tappendStringInfoString(str, \" :required_outer \");\n"
			  . "\tif (node->$f)\n"
			  . "\t\toutBitmapset(str, node->$f->ppi_req_outer);\n"
			  . "\telse\n"
			  . "\t\toutBitmapset(str, NULL);\n";
		}
		# node type
		elsif ($t =~ /(\w+)\*/ and elem $1, @node_types)
		{
			print $off "\tWRITE_NODE_FIELD($f);\n";
			print $rff "\tREAD_NODE_FIELD($f);\n" unless $no_read;
		}
		elsif ($t eq 'struct CustomPathMethods*'
			|| $t eq 'struct CustomScanMethods*')
		{
			print $off q{
	/* CustomName is a key to lookup CustomScanMethods */
	appendStringInfoString(str, " :methods ");
	outToken(str, node->methods->CustomName);
};
			print $rff q!
	{
		/* Lookup CustomScanMethods by CustomName */
		char	   *custom_name;
		const CustomScanMethods *methods;
		token = pg_strtok(&length); /* skip methods: */
		token = pg_strtok(&length); /* CustomName */
		custom_name = nullable_string(token, length);
		methods = GetCustomScanMethods(custom_name, false);
		local_node->methods = methods;
	}
! unless $no_read;
		}
		else
		{
			die
			  "could not handle type \"$t\" in struct \"$n\" field \"$f\"\n";
		}

		# for read_as() without read_write_ignore, we have to read the value
		# that outfuncs.c wrote and then overwrite it.
		if (defined $read_as_field)
		{
			print $rff "\tlocal_node->$f = $read_as_field;\n" unless $no_read;
		}
	}

	print $off "}
";
	print $rff "
\tREAD_DONE();
}
" unless $no_read;
}

close $off;
close $rff;
close $ofs;
close $rfs;


# now rename the temporary files to their final names
foreach my $file (@output_files)
{
	Catalog::RenameTempFile($file, $tmpext);
}


# Automatically clean up any temp files if the script fails.
END
{
	# take care not to change the script's exit value
	my $exit_code = $?;

	if ($exit_code != 0)
	{
		foreach my $file (@output_files)
		{
			unlink($file . $tmpext);
		}
	}

	$? = $exit_code;
}
