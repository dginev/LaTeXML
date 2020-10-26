# /=====================================================================\ #
# |  LaTeXML::Util::ObjectDB                                            | #
# | Database of Objects for crossreferencing, etc                       | #
# |=====================================================================| #
# | Part of LaTeXML:                                                    | #
# |  Public domain software, produced as part of work done by the       | #
# |  United States Government & not subject to copyright in the US.     | #
# |---------------------------------------------------------------------| #
# | Bruce Miller <bruce.miller@nist.gov>                        #_#     | #
# | http://dlmf.nist.gov/LaTeXML/                              (o o)    | #
# \=========================================================ooo==U==ooo=/ #
package LaTeXML::Util::ObjectDB;
use strict;
use warnings;
use LaTeXML::Util::Pathname;
use DB_File;
use Storable qw(nfreeze thaw);
use strict;
use Encode;
use Carp;
use base qw(Storable);
use LaTeXML::Util::ObjectDB::Entry;

#======================================================================
# NOTES:
#  (1) If we can do make-like processing, when an entry is marked as
#       modified, any referrers to it also need processing.
#      (and we could defer a save if nothing was dirty)
#======================================================================
# Some Definitions:
#  * Object: places a link will take you to.  Several types
#    * chunk: any significant document object with a reference
#       number: sectional chunks, equations, ...
#    * index : the target is the entry in the index itself.
#         a back reference can take you to where the \index was invoked.
#    * bib   : the target is the entry in the bibliography.
#         a back reference can take you to the \cite.
#
#======================================================================

#======================================================================
# Creating an ObjectDB object, hooking up initial database.
sub new {
  my ($class, %options) = @_;
  my $dbfile = $options{dbfile};
  if ($dbfile && $options{clean}) {
    warn "\nWARN: Removing Object database file $dbfile!!!\n";
    unlink($dbfile); }

  my $self = bless { dbfile => $dbfile,
    objects   => {}, externaldb => {},
    verbosity => $options{verbosity} || 0,
    readonly  => $options{readonly},
  }, $class;
  if ($dbfile) {
##    my $flags = ($options{read_write} ? O_RDWR|O_CREAT : O_RDONLY);
    my $flags = O_RDWR | O_CREAT;
    tie %{ $$self{externaldb} }, 'DB_File', $dbfile, $flags
      or die "Couldn't attach DB $dbfile for object table";
  }
  return $self; }

sub DESTROY {
  my ($self) = @_;
  $self->finish;
  return; }

sub status {
  my ($self) = @_;
  my $status = scalar(keys %{ $$self{objects} }) . "/" . scalar(keys %{ $$self{externaldb} }) . " objects";
  #  if($$self{dbfile}){ ...
  return $status; }

#======================================================================
# This saves the db

sub finish {
  my ($self) = @_;
  if ($$self{externaldb} && $$self{dbfile} && !$$self{readonly}) {
    my $n     = 0;
    my %types = ();
    foreach my $key (keys %{ $$self{objects} }) {
      my $row = $$self{objects}{$key};
      # Skip saving, unless there's some difference between stored value
      if (my $stored = $$self{externaldb}{ Encode::encode('utf8', $key) }) {    # Get the external object
        next if compare_hash($row, thaw($stored)); }
      $n++;
      my %item = %$row;
      $$self{externaldb}{ Encode::encode('utf8', $key) } = nfreeze({%item}); }

    print STDERR "ObjectDB Stored $n objects (" . scalar(keys %{ $$self{externaldb} }) . " total)\n"
      if $$self{verbosity} > 0;
    untie %{ $$self{externaldb} }; }

  $$self{externaldb} = undef;
  $$self{objects}    = undef;
  return }

sub compare {
  my ($a, $b) = @_;
  my $ra = ref $a;
  if (!$ra) {
    if (ref $b) {
      return 0; }
    else {
      return compare_scalar($a, $b); } }
  elsif ($ra ne ref $b) {
    return 0; }
  elsif ($ra eq 'HASH') {
    return compare_hash($a, $b); }
  elsif ($ra eq 'ARRAY') {
    return compare_array($a, $b); }
  else {
    return compare_scalar($a, $b); } }

sub compare_scalar {
  my ($a, $b) = @_;
  return ((!defined $a) && (!defined $b)) ||
    (defined $a && defined $b && $a eq $b); }

sub compare_hash {
  my ($a, $b) = @_;
  my %attr = ();
  map { $attr{$_} = 1 } keys %$a;
  map { $attr{$_} = 1 } keys %$b;
  return (grep { !((exists $$a{$_}) && (exists $$b{$_}) && compare($$a{$_}, $$b{$_})) }
      keys %attr) ? 0 : 1; }

sub compare_array {
  my ($a, $b) = @_;
  my @a = @$a;
  my @b = @$b;
  while (@a && @b) {
    return 0 unless compare(shift(@a), shift(@b)); }
  return (@a || @b ? 0 : 1); }

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
sub getKeys {
  my ($self) = @_;
  # Get union of all keys in externaldb & local objects.
  my %keys = ();
  map { $keys{$_} = 1 } keys %{ $$self{objects} };
  map { $keys{ Encode::decode('utf8', $_) } = 1 } keys %{ $$self{externaldb} };
  return (sort keys %keys); }

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
# Lookup of various kinds of things in the DB.
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

# Lookup the Object associated with label
# If it is not already fetched from the external db (if any), fetch it now.

sub lookup {
  my ($self, $key) = @_;
  return unless defined $key;
  my $entry = $$self{objects}{$key};    # Get the local copy.
  return $entry if $entry;
  $entry = $$self{externaldb}{ Encode::encode('utf8', $key) };    # Get the external object
  if ($entry) {
    $entry = thaw($entry);
    $$entry{key} = $key;
    bless $entry, 'LaTeXML::Util::ObjectDB::Entry';
    $$self{objects}{$key} = $entry; }
  return $entry; }

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
# Register various interesting document nodes.
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
# Register the labeled object $node, creating, or filling in, and
# returning a Chunk entry.
sub register {
  my ($self, $key, %props) = @_;
  carp("Missing key for object!") unless $key;
  my $entry = $self->lookup($key);
  if (!$entry) {
    $entry = { key => $key };
    bless $entry, 'LaTeXML::Util::ObjectDB::Entry';
    $$self{objects}{$key} = $entry; }
  $entry->setValues(%props);

  return $entry; }

sub unregister {
  my ($self, $key) = @_;
  delete $$self{objects}{$key};
  # Must remove external entry (if any) as well, else it'll get pulled back in!
  delete $$self{externaldb}{ Encode::encode('utf8', $key) } if $$self{externaldb};
  return; }

#======================================================================
use Data::Dump::Streamer;
use Sub::Identify ':all';
# Ensure subroutines that will be hosted by State can be frozen and thawed
sub freezable_any {
  my @freezable = ();
  for my $data (@_) {
    my $dref = ref $data;
    if (not($dref) or $dref eq 'Regexp' or $dref =~ /^LaTeXML::Common/ or $dref =~ /(Glue|Rewrite|Regexp)$/) {
      push(@freezable, $data); }
    elsif ($dref eq 'ARRAY' or $dref =~ /^LaTeXML::Core::Token/ or $dref =~ /Parameters$/) {
      my $idx = 0;
      for my $val (@$data) {
        $$data[$idx] = freezable_any($val) if ref $val;
        $idx++; }
      push(@freezable, $data); }
    elsif ($dref eq 'CODE') {
      push(@freezable, freezable_code($data)); }
    else {    # hash case is the default
      while (my ($key, $val) = each %$data) {
        $$data{$key} = freezable_any($val) if ref $val; }
      push(@freezable, $data); } }
  return wantarray ? @freezable : $freezable[0]; }

sub freezable_code {
  my ($subref) = @_;
  return $subref if (ref $subref ne 'CODE');
  my $orig_body = Dump($subref)->Indent(0)->Out();
  my $body      = $orig_body;
  return if ($body =~ /^\s*\$CODE1=\\&/);    # skippable case (e.g. "our" variable)
      # print STDERR "\n\n\n\n original body: $orig_body\n\n\n\n" if $body=~/do_def/m;
  my $has_nested_sub = ($body =~ s/^\s*\$CODE1=sub\s*\{(?:.+)sub\s*\{//m);
  $body =~ s/^\s*\$CODE1=sub \{\s*//m;
  $body =~ s/\};\s*$//;
  # print STDERR "body 1 expansion: \n\n$body\n\n";

  # Twice for "good luck" -- correctly fixes 1-level nested subroutines.
  # TODO: In general we'd need to loop for as many nested cases as we have...
  # in practice, latexml uses 2 levels at most.
  my $newref;
  if ($has_nested_sub) {
    $newref = eval "{$body}";
    print STDERR "to_freezable eval 1 error: $@\n$orig_body\n" if $@;
    $body = Dump($newref)->Indent(0)->Out();
    $body =~ s/\$CODE1=//g;    # leave the anonymous subroutines anonymous
                               # print STDERR "body 2 expansion: \n\n$body\n\n";
  }
  $newref = eval "sub { $body }";
  print STDERR "to_freezable eval 2 error: $@\noriginal:\n $orig_body\nfinal:\n $body\n" if $@;
  return $newref; }

sub cache_state {
  my ($state, $basename) = @_;
# Why fork? Because carelessly calling freezable_code on a State, and then using that same State object,
# leads to tricky bugs... best to cache in a sandbox and avoid any weirdness - handle that when loading.
  if (my $pid = fork()) {
    waitpid($pid, 0);
    return;
  } else {
    local $Storable::Eval    = 1;
    local $Storable::Deparse = 1;

    # First, cache the Package::Pool namespace routines:
    my $pool_filename = "$basename.pool.cache";
    print STDERR "\n--- Caching Pool to $pool_filename...";
    my $pool = {};
    foreach my $subname (sort keys %LaTeXML::Package::Pool::) {
      next unless $subname =~ /^[a-z]/ or $subname eq 'DefAccent';
      my $coderef    = eval "\\\&LaTeXML::Package::Pool::$subname";
      my $stash_name = stash_name($coderef);
      if ($stash_name ne 'LaTeXML::Package::Pool') {
        # print STDERR "foreign $subname from $stash_name\n";
        next; }
      my $freezable = freezable_code($coderef);
      if ($freezable) {
        $$pool{$subname} = $freezable;
      } else {
        print STDERR "can't use code for $subname\n";
    } }
    open(my $pool_fh, '>', $pool_filename);
    Storable::nstore_fd($pool, $pool_fh);
    close $pool_fh;
    print STDERR " ...completed.\n";

    my $state_filename = "$basename.state.cache";
    print STDERR "\n--- Caching State to $state_filename...";
    $state = freezable_any($state);
    open(my $state_fh, '>', $state_filename);
    Storable::nstore_fd($state, $state_fh);
    close $state_fh;
    print STDERR " ...completed.\n";
    exit 0;
} }

sub load_state {
  my ($basename) = @_;
  return unless $basename;
  my $state_filename = "$basename.state.cache";
  my $pool_filename  = "$basename.pool.cache";
  if (-f $pool_filename && -f $state_filename) {
    local $Storable::Deparse = 1;
    local $Storable::Eval    = 1;
    print STDERR "\n--- Loading Pool from $pool_filename... ";
    my $pool = Storable::retrieve($pool_filename);
    for my $key (sort(keys %$pool)) {
      my $coderef = $$pool{$key};
      no strict 'refs';
      my $subname = "LaTeXML::Package::Pool::$key";
      *$subname = $coderef; }
    print STDERR " ...completed.\n";
    print STDERR "\n--- Loading State from $state_filename... ";
    my $state = Storable::retrieve($state_filename);
    print STDERR " ...completed.\n";
    return $state; }
  else {
    return; } }

#======================================================================
1;
