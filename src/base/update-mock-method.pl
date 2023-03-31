#!/usr/bin/perl
#
# This tool converts MOCK(_CONST)_METHODn(_T)(_WITH_CALLTYPE) macros to the new
# MOCK_METHOD macro (see go/totw/164) in an (almost) completely automated
# fashion.  See README.md for instructions.

use strict;

sub usage {
  my($message) = @_;
  print STDERR "$message\n" if $message;
  print STDERR "Usage: update-mock-method project_path\n";
  exit(1);
}

# Mock methods that intentionally do not exist in the base class and thus
# should not be declared "override".
my @mocks_not_override = qw(.*::Mock.*);

# If set, a glob matching prepared index files to look up whether a method is
# an override.
my $override_lines_files;

# Whether to run 'g4 fix' on modified files.
my $fixer = 'g4 fix';

# Directory containing files to convert.
my $project_path;

my @orig_argv = @ARGV;
while (my $arg = shift @ARGV) {
  if ($arg eq '--override-lines') {
    $override_lines_files = join(' ', glob(shift @ARGV || usage("--override-lines requires value")));
    usage("override-lines glob matched nothing") if !$override_lines_files;
  } elsif ($arg eq '--fixer') {
    $fixer = shift @ARGV || usage;
    usage if !$fixer;
  } elsif ($arg eq '--no-fixer') {
    $fixer = '';
  } else {
    usage("unknown arg $arg") if $arg =~ /^-/;
    usage("duplicate project path $project_path vs $arg") if $project_path;
    $project_path = $arg;
  }
}
usage("missing project path") if !$project_path;

# Accumulated methods not marked as override, with reason.
my %no_override_methods;
# Accumulated modified files.
my @modified_files;

my $mocks_not_override_re = '^(' . join('|', @mocks_not_override) . ')$';

###
# Swiped from sokolov@'s rewrite-mock-method.pl upon discovering that my
# simpler approach did not work.  (I didn't know he'd already written his
# script when I wrote mine.)  Thanks, sokolov@. :-)
###
# Matches nested () and <>. This is $RE{balanced}{-parens => "()<>"} from
# Regexp::Common::balanced but without dependency on Regexp::Common itself.
my $parentheses = qr/(?^:((?:\((?:(?>[^\(\)]+)|(?-1))*\))|(?:\<(?:(?>[^\<\>]+)|(?-1))*\>)))/;
# The same but only for ()
my $parentheses2 = qr/(?^:((?:\((?:(?>[^\(\)]+)|(?-1))*\))))/;
# The same but only for {}
my $braces = qr/(?^:((?:\{(?:(?>[^\{\}]+)|(?-1))*\})))/;
# Returns either the parameter, or parameter in () if it contains commas
sub comma_parentheses {
  my $s = shift;
  # Only commas outside () matter.
  my $simplified = $s;
  $simplified =~ s/$parentheses2//g;
  $s = "($s)" if ($simplified =~ /,|FLUME_COMMA/);
  return $s;
}
###
# End of swipe.
###

my $old_mock_re = qr{
  # no longer used
  (?<before>)
  # macro name
  MOCK_(?<const>CONST_)?METHOD(?<n>\d+)(?:_T)?(_WITH_CALLTYPE)?
  # start of macro args
  \s*\(\s*
  # call type, if _WITH_CALLTYPE is present
  (?(4)(?<calltype>([^,]+))\s*,\s*)
  # method name
  (?<name>[\w_]*?)
  # comma
  \s*,\s*
  # return type
  (?<return_type>.*?)
  # method args
  \s*(?<argsparens>$parentheses2)\s*
  # end of macro args
  \s*\)\s*;
  # match NO_?LINT macros, but do not pass them to mock_method()
  (?:[ \t]*//[ \t]*NO_?LINT[ \t]*(?=\n))?
}smx;
my $old_name_ofs_group = 7;

sub maybe_lookup_is_overridden_by_lineno {
  my($method, $file, $lineno) = @_;

  return 1 if !$override_lines_files;

  my $lookup = "$method,$file,$lineno";
  # print STDERR "look $lookup\n";
  my $cmd = "look --binary '$lookup' $override_lines_files >/dev/null";
  my $ret = system($cmd);
  #print STDERR "$ret: $cmd\n";
  return $ret == 0;
}

sub mock_method {
  my($file, $class_name, $derived, $parent_class,
     $return_type, $name, $args, $const, $specs, $calltype,
     $before, $after, $mock_lineno) = @_;
  my $match_name = "${class_name}::${name}";
  my $report_name = "${class_name}::${name}";
  my $comment;
  my(@specs);
  push(@specs, "const") if ($const =~ /CONST/);
  push(@specs, "const") if ($specs =~ /const/);
  my $reason;
  if (!$derived) {
    $reason = 'no base class';
  } elsif ($match_name =~ /$mocks_not_override_re/) {
    $reason = 'matches regexp';
  } else {
    my($name_reason, $lineno_reason);
    if (!maybe_lookup_is_overridden_by_lineno($name, $file, $mock_lineno)) {
      $lineno_reason = "Kythe lookup (line $mock_lineno)"
    }
    if ($name_reason && $lineno_reason) {
      $reason = join(' and ', $name_reason, $lineno_reason);
    }
  }
  if (!$reason) {
    push(@specs, "override");
  }
  else {
    $no_override_methods{$report_name} = $reason;
  }
  push(@specs, "Calltype($calltype)") if ($calltype);
  push(@specs, $1) if ($specs =~ /(Calltype\([^\)]*\))/);
  my $spec = join(", ", @specs);
  $spec = ", ($spec)" if ($spec ne "");

  $args = "" if $args eq "void";
  # strip any extra parens wrapping the whole arg string.
  1 while ($args =~ s/^\((.*)\)$/\1/s);

  # Surround every parameter with () if necessary.
  $args =~ s/(\s*)((?:$parentheses|[^,])+)/$1 . comma_parentheses($2)/sge;
  $return_type = "($return_type)" if ($return_type =~ /,/);

  $comment = " $comment" if $comment;

  my $new = "${before}MOCK_METHOD($return_type, $name, ($args)$spec$comment);$after";
  $new =~ s|[ \t]*//[ \t]*NO_?LINT[ \t]*(?=\n)||gs;
  return $new;
}

sub mock_method_wrapper {
  my($file, $class_name, $class_lineno, $derived, $parent_class, $class,
     $matches_ref, $matches_start, $matches_end, $mock_ofs_group,
     $lines_removed_ref) = @_;
  my @matches_start = @{$matches_start};
  my @matches_end = @{$matches_end};
  my $matched_lines =
    substr($class, $matches_start->[0], $matches_end->[0]-$matches_start->[0])
    =~ tr/\n//;
  my %m = %{$matches_ref};
  my $mock_ofs = $matches_start->[$mock_ofs_group];
  my $mock_lineno = $class_lineno + substr($class, 0, $mock_ofs) =~ tr/\n//;
  my($args) = ($m{argsparens} =~ m/^\(\s*(.*)\s*\)$/s);
  my $replacement = mock_method($file, $class_name, $derived, $parent_class,
                                $m{return_type}, $m{name}, $args,
                                $m{const}, $m{specs}, $m{calltype}, $m{before},
                                '', $mock_lineno);
  my $replaced_lines = $replacement =~ tr/\n//;
  my $delta = ($matched_lines - $replaced_lines);
  ${$lines_removed_ref} += $delta;
  # print "$m{name}: $mock_ofs, $file:$mock_lineno (s $matches_start[0], e $matches_end[0], m $matched_lines, r $replaced_lines, d $delta, t $$lines_removed_ref)\n";
  $replacement;
}

sub clang_format {
  my($file) = @_;
  (system("$fixer $file") == 0) || die "$fixer returned non-zero status.\n";
}

my $file_list;
if ($project_path =~ /^@(.*)/) {
  $file_list = $1;
} else {
  $file_list = "find $project_path|";
}
open(FIND, $file_list) || die "Cannot read file list: $file_list: $!";
while (my $file = <FIND>) {
  chomp $file;
  next if $file !~ /\.(?:h|cc)$/;
  $file =~ s|^/google/src/files/head/depot/google3/||;

  my $fh;
  if (!open($fh, '<', $file)) {
    print "Can't read $file: $!\n";
    next;
  }
  my $content = do { local $/; <$fh> };
  my $orig_content = $content;
  my $lines_removed = 0;

  while ($content =~ /(?<class>(?<header>(?:[ \t]*class|struct)\s+(?<decl>[^{};]+))(?<body>$braces);)/gsm) {
    my ($start_ofs, $stop_ofs) = ($-[0], $+[0]);
    my $orig_class_lineno = 1  + $lines_removed + substr($content, 0, $start_ofs) =~ tr/\n//;
    my $class = $+{class};
    my $header = $+{header};
    my $derived = ($header =~ /[^:]:[^:]/);
    my($class_name) = ($header =~ /^(?:class|struct)\s+([^\s]+)/);
    my($parent_class);
    if ($derived) {
      my @words = split(/ /, $header);
      $parent_class = pop(@words);
      #print STDERR "header $header, parent $parent_class\n";
    }

    #print "CLASS $class_name: $orig_class_lineno (+ $lines_removed)\n";
    my $orig_class = $class;

    # MOCK_(CONST_)METHOD<n>(_T)
    $class =~ s{$old_mock_re}{mock_method_wrapper($file, $class_name,
                                                  $orig_class_lineno,
                                                  $derived,
                                                  $parent_class,
                                                  $orig_class,
                                                  \%+, \@-, \@+,
                                                  $old_name_ofs_group,
                                                  \$lines_removed)}ge;

    substr($content, $start_ofs, $stop_ofs-$start_ofs) = $class;
    pos($content) = $start_ofs + length($class);
  }

  # Process any remaning macros that are outside of classes.
  $content =~ s{$old_mock_re}{mock_method_wrapper($file, 'no_class_name',
                                                  'no_orig_class_lineno',
                                                  1, # $derived,
                                                  'no_parent_class',
                                                  'no_orig_class',
                                                  \%+, \@-, \@+,
                                                  $old_name_ofs_group,
                                                  \$lines_removed)}ge;

  if ($content ne $orig_content) {
    print "Updating $file\n";
    if (!open $fh, '>', $file) {
      print "CANNOT UPDATE $file: $!";
      next;
    }
    print $fh $content;
    close $fh;
    push(@modified_files, $file);
  }
}


if ($fixer) {
  clang_format(join(' ', @modified_files));
}

print "LSC: Replace the C++ MOCK_METHOD<n> family of macros with the new MOCK_METHOD in $project_path.  See go/totw/164.\n";
print "\n";
if (%no_override_methods) {
  print "Mock methods not marked 'override' because they are not overrides, and the source for that decision:\n";
  foreach my $key (sort keys %no_override_methods) {
    my $val = $no_override_methods{$key};
    printf("\t%14s: %s\n", $val, $key);
  }
  print "\n";
}

print "Converted with experimental/users/bjaspan/mock_method/update-mock-method.pl ".join(" ", @orig_argv)."\n";
print "#updatemockmethod #codehealth\n";