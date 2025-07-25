# /=====================================================================\ #
# |  LaTeXML::Core::Document                                            | #
# | Constructs the Document from digested material                      | #
# |=====================================================================| #
# | Part of LaTeXML:                                                    | #
# |  Public domain software, produced as part of work done by the       | #
# |  United States Government & not subject to copyright in the US.     | #
# |---------------------------------------------------------------------| #
# | Bruce Miller <bruce.miller@nist.gov>                        #_#     | #
# | http://dlmf.nist.gov/LaTeXML/                              (o o)    | #
# \=========================================================ooo==U==ooo=/ #

package LaTeXML::Core::Document;
use strict;
use warnings;
use LaTeXML::Global;
use LaTeXML::Common::Object;
use LaTeXML::Core::List;
use LaTeXML::Common::Error;
use LaTeXML::Common::XML;
use LaTeXML::Util::Radix;
use Unicode::Normalize;
use Data::Dumper;
use Scalar::Util qw(blessed);
use base         qw(LaTeXML::Common::Object);

#**********************************************************************
# These two element names are `leaks' of the document structure into
# the Core of LaTeXML... In principle, we should be more abstract!

our $FONT_ELEMENT_NAME = "ltx:text";
our $MATH_TOKEN_NAME   = "ltx:XMTok";
our $MATH_HINT_NAME    = "ltx:XMHint";
DebuggableFeature('document');

#**********************************************************************

# [could conceivable make more sense to let the Stomach create the Document?]

# Mystery attributes:
#    font :
#       Probably should keep font ONLY in extra properties,
#        THEN once complete, compute the relative font at each node that accepts
#       a font attribute, and add the attribute.
#   locator : a box

sub new {
  my ($class, $model) = @_;
  my $doc = XML::LibXML::Document->new("1.0", "UTF-8");
  # We'll set the DocType when the 1st Element gets added.
  return bless { document => $doc, node => $doc, model => $model,
    idstore    => {}, labelstore => {},
    node_fonts => {}, node_boxes => {}, node_properties => {},
    pending    => [], progress   => 0 }, $class; }

our $CONSTRUCTION_PROGRESS_QUANTUM = 500;

#**********************************************************************
# Basic Accessors

# This will be a node of type XML_DOCUMENT_NODE
sub getDocument     { my ($self) = @_; return $$self{document}; }
sub getModel        { my ($self) = @_; return $$self{model}; }
sub documentElement { my ($self) = @_; return $$self{document}->documentElement; }

# Get the node representing the current insertion point.
# The node will have nodeType of
#   XML_DOCUMENT_NODE if the document is empty, so far.
#   XML_ELEMENT_NODE  for normal elements.
#   XML_TEXT_NODE     if the last insertion was text
# The other node types will not appear here.
sub getNode { my ($self) = @_; return $$self{node}; }

sub setNode {
  my ($self, $node) = @_;
  closeText_internal($self);                # Close any open text node, so ligatures run.
  my $type = $node->nodeType;
  if ($type == XML_DOCUMENT_FRAG_NODE) {    # Whoops
    my @n = $node->childNodes;
    if (@n > 1) {
      Error('unexpected', 'multiple-nodes', $self,
        "Cannot set insertion point to a DOCUMENT_FRAG_NODE", Stringify($node)); }
    elsif (@n < 1) {
      Error('unexpected', 'empty-nodes', $self,
        "Cannot set insertion point to an empty DOCUMENT_FRAG_NODE"); }
    $node = $n[0]; }
  $$self{node} = $node;
  return; }

sub getLocator {
  my ($self) = @_;
  if (my $box = getNodeBox($self, $$self{node})) {
    return $box->getLocator; }
  else {
    return; } }    # well?

# Get the element at (or containing) the current insertion point.
sub getElement {
  my ($self) = @_;
  my $node = $$self{node};
  $node = $node->parentNode if $node->getType == XML_TEXT_NODE;
  return ($node->getType == XML_DOCUMENT_NODE ? undef : $node); }

# Get the child elements of the given $node
sub getChildElements {
  my ($self, $node) = @_;
  return (!$node ? () : grep { $_->nodeType == XML_ELEMENT_NODE } $node->childNodes); }

# Get the last element node (if any) in $node
sub getLastChildElement {
  my ($self, $node) = @_;
  if ($node->hasChildNodes) {
    my $n = $node->lastChild;
    while ($n && $n->nodeType != XML_ELEMENT_NODE) {
      $n = $node->previousSibling; }
    return $n; } }

# get the first element node (if any) in $node
sub getFirstChildElement {
  my ($self, $node) = @_;
  if ($node->hasChildNodes) {
    my $n = $node->firstChild;
    while ($n && $n->nodeType != XML_ELEMENT_NODE) {
      $n = $n->nextSibling; }
    return $n; }
  return; }

# get the second element node (if any) in $node
sub getSecondChildElement {
  my ($self, $node) = @_;
  my $first_child  = getFirstChildElement($self, $node);
  my $second_child = $first_child && $first_child->nextSibling;
  while ($second_child && $second_child->nodeType != XML_ELEMENT_NODE) {
    $second_child = $second_child->nextSibling; }
  return $second_child; }

# Find the nodes according to the given $xpath expression,
# the xpath is relative to $node (if given), otherwise to the document node.
sub findnodes {
  my ($self, $xpath, $node) = @_;
  return $$self{model}->getXPath->findnodes($xpath, ($node || $$self{document})); }

# Like findnodes, but only returns the first matched node
sub findnode {
  my ($self, $xpath, $node) = @_;
  my @nodes = $$self{model}->getXPath->findnodes($xpath, ($node || $$self{document}));
  return (@nodes ? $nodes[0] : undef); }

# Get the node's qualified name in standard form
# Ie. using the registered prefix for that namespace.
# NOTE: Reconsider how _Capture_ & _WildCard_ should be integrated!?!
# NOTE: Should Deprecate! (use model)
sub getNodeQName {
  my ($self, $node) = @_;
  return $node && $$self{model}->getNodeQName($node); }

#**********************************************************************
# Extensions of Model.

sub canContain {
  my ($self, $tag, $child) = @_;
  my $model = $$self{model};
  $tag   = $model->getNodeQName($tag)   if ref $tag;      # In case tag is a node.
  $child = $model->getNodeQName($child) if ref $child;    # In case child is a node.
  return $model->canContain($tag, $child); }

# Can an element with (qualified name) $tag contain a $childtag element indirectly?
# That is, by openning some number of autoOpen'able tags?
# And if so, return the tag to open.
sub canContainIndirect {
  my ($self, $tag, $child) = @_;
  my $model = $$self{model};
  $tag   = $model->getNodeQName($tag)   if ref $tag;      # In case tag is a node.
  $child = $model->getNodeQName($child) if ref $child;    # In case child is a node.
      # $imodel{$tag}{$child} => $intermediate || $child
  my $imodel = $STATE->lookupValue('INDIRECT_MODEL');
  if (!$imodel) {
    $imodel = computeIndirectModel($self);
    $STATE->assignValue(INDIRECT_MODEL => $imodel, 'global'); }
  return $$imodel{$tag}{$child}; }

# The indirect model includes all elements allowed as direct children,
# and all descendents of a node that can be inserted after autoOpen'ing intermediate elements.
# This model therefor includes information from the Schema, as well as
# autoOpen information that may be introduced in binding files.
# [Thus it should NOT be modifying the Model object, which may cover several documents in Daemon]
# $imodel{$tag}{$child} => $open means if in $tag, to open $child, we must first open $open
sub computeIndirectModel {
  my ($self) = @_;
  my $model  = $$self{model};
  my $imodel = {};
  # Determine any indirect paths to each descendent via an `autoOpen-able' tag.
  local %::OPENABILITY = ();
  foreach my $tag ($model->getTags) {
    my $x;
    if (($x = $STATE->lookupMapping('TAG_PROPERTIES', $tag)) && ($x = $$x{autoOpen})) {
      $::OPENABILITY{$tag} = ($x =~ /^\d*\.\d*$/ ? $x : 1); }
    else {
      $::OPENABILITY{$tag} = 0; } }
  foreach my $tag ($model->getTags) {
    local %::DESC = ();
    computeIndirectModel_aux($model, $tag, '', 1);
    foreach my $kid (sort keys %::DESC) {
      my $best = 0;    # Find best path to $kid.
      foreach my $start (sort keys %{ $::DESC{$kid} }) {
        if (($tag ne $kid) && ($tag ne $start) && ($::DESC{$kid}{$start} > $best)) {
          $$imodel{$tag}{$kid} = $start; $best = $::DESC{$kid}{$start}; } } } }
  # PATCHUP
  if ($$model{permissive}) {    # !!! Alarm!!!
    $$imodel{'#Document'}{'#PCDATA'} = 'ltx:p'; }
  return $imodel; }

sub computeIndirectModel_aux {
  my ($model, $tag, $start, $desirability) = @_;
  my $x;
  foreach my $kid ($model->getTagContents($tag)) {
    next                                  if $::DESC{$kid}{$start};    # Already solved
    $::DESC{$kid}{$start} = $desirability if $start;
    if (($kid ne '#PCDATA') && ($x = $::OPENABILITY{$kid})) {
      computeIndirectModel_aux($model, $kid, $start || $kid, $desirability * $x); } }
  return; }

sub canContainSomehow {
  my ($self, $tag, $child) = @_;
  my $model = $$self{model};
  $tag   = $model->getNodeQName($tag)   if ref $tag;      # In case tag is a node.
  $child = $model->getNodeQName($child) if ref $child;    # In case child is a node.
  return $model->canContain($tag, $child) || canContainIndirect($self, $tag, $child); }

sub canHaveAttribute {
  my ($self, $tag, $attrib) = @_;
  my $model = $$self{model};
  $tag = $model->getNodeQName($tag) if ref $tag;          # In case tag is a node.
  return $model->canHaveAttribute($tag, $attrib); }

sub canAutoOpen {
  my ($self, $tag) = @_;
  if (my $props = $STATE->lookupMapping('TAG_PROPERTIES', $tag)) {
    return $$props{autoOpen}; } }

# Dirty little secrets:
#  You can generically allow an element to autoClose using Tag.
# OR you can indicate a specific node can autoClose, or forbid it, using
# the _autoclose or _noautoclose attributes!
sub canAutoClose {
  my ($self, $node) = @_;
  my $t     = $node->nodeType;
  my $model = $$self{model};
  my $props;
  return ($t == XML_TEXT_NODE) || ($t == XML_COMMENT_NODE)    # text or comments auto close
    || (($t == XML_ELEMENT_NODE)                              # otherwise must be element
    && !$node->getAttribute('_noautoclose')                   # without _noautoclose
    && ($node->getAttribute('_autoclose')                     # and either with _autoclose
                                                              # OR it has autoClose set on tag properties
      || (($props = $STATE->lookupMapping('TAG_PROPERTIES', getNodeQName($self, $node)))
        && $$props{autoClose})));
}

# get the actions that should be performed on afterOpen or afterClose
sub getTagActionList {
  my ($self, $tag, $when) = @_;
  $tag = $$self{model}->getNodeQName($tag) if ref $tag;    # In case tag is a node.
  my ($p, $n) = (undef, $tag);
  if ($tag =~ /^([^:]+):(.+)$/) {
    ($p, $n) = ($1, $2); }
  my $when0   = $when . ':early';
  my $when1   = $when . ':late';
  my $taghash = $STATE->lookupMapping('TAG_PROPERTIES', $tag)                        || {};
  my $nshash  = ((defined $p) && $STATE->lookupMapping('TAG_PROPERTIES', $p . ':*')) || {};
  my $allhash = $STATE->lookupMapping('TAG_PROPERTIES', '*')                         || {};
  my $v;
  return (
    (($v = $$taghash{$when0}) ? @$v : ()),
    (($v = $$nshash{$when0})  ? @$v : ()),
    (($v = $$allhash{$when0}) ? @$v : ()),
    (($v = $$taghash{$when})  ? @$v : ()),
    (($v = $$nshash{$when})   ? @$v : ()),
    (($v = $$allhash{$when})  ? @$v : ()),
    (($v = $$taghash{$when1}) ? @$v : ()),
    (($v = $$nshash{$when1})  ? @$v : ()),
    (($v = $$allhash{$when1}) ? @$v : ()),
  ); }

#**********************************************************************
# This is a diagnostic tool that MIGHT help locate XML::LibXML bugs;
# It simply walks through the document tree. Use it before and after
# places where some sort of data corruption might have taken place.
sub doctest {
  my ($self, $when, $severe) = @_;
  local $LaTeXML::NNODES = 0;
  Debug("START DOC TEST $when.....");
  if (my $root = getDocument($self)->documentElement) {
    doctest_rec($self, undef, $root, $severe); }
  Debug("...(" . $LaTeXML::NNODES . " nodes)....DONE");
  return; }

sub doctest_rec {
  my ($self, $parent, $node, $severe) = @_;
  # Check consistency of document, parent & type, before proceeding
  doctest_head($self, $parent, $node, $severe);
  my $type = $node->nodeType;
  if ($type == XML_ELEMENT_NODE) {
    Debug("ELEMENT "
        . join(' ', "<" . $$self{model}->getNodeQName($node),
        (map { $_->nodeName . '="' . $_->getValue . '"' } $node->attributes)) . ">")
      if $severe;
    doctest_children($self, $node, $severe); }
  elsif ($type == XML_ATTRIBUTE_NODE) {
    Debug("ATTRIBUTE " . $node->nodeName . "=>" . $node->getValue) if $severe; }
  elsif ($type == XML_TEXT_NODE) {
    Debug("TEXT " . $node->textContent) if $severe; }
  elsif ($type == XML_CDATA_SECTION_NODE) {
    Debug("CDATA " . $node->textContent) if $severe; }
  #  elsif($type == XML_ENTITY_REF_NODE){}
  #  elsif($type == XML_ENTITY_NODE){}
  elsif ($type == XML_PI_NODE) {
    Debug("PI " . $node->localname . " " . $node->getData) if $severe; }
  elsif ($type == XML_COMMENT_NODE) {
    Debug("COMMENT " . $node->textContent) if $severe; }
  #  elsif($type == XML_DOCUMENT_NODE){}
  #  elsif($type == XML_DOCUMENT_TYPE_NODE){
  elsif ($type == XML_DOCUMENT_FRAG_NODE) {
    Debug("DOCUMENT_FRAG") if $severe;
    doctest_children($self, $node, $severe); }
  #  elsif($type == XML_NOTATION_NODE){}
  #  elsif($type == XML_HTML_DOCUMENT_NODE){}
  #  elsif($type == XML_DTD_NODE){}
  else {
    Debug("OTHER $type") if $severe; }
  return; }

sub doctest_head {
  my ($self, $parent, $node, $severe) = @_;
  # Check consistency of document, parent & type, before proceeding
  Debug("  NODE $$node [") if $severe;    # BEFORE checking nodeType!
  if (!$node->ownerDocument->isSameNode(getDocument($self))) {
    Debug("d!") if $severe; }
  if ($parent && !$node->parentNode->isSameNode($parent)) {
    Debug("p!") if $severe; }
  my $type = $node->nodeType;
  Debug("t] ") if $severe;
  return; }

sub doctest_children {
  my ($self, $node, $severe) = @_;
  Debug("[fc") if $severe;
  my $c = $node->firstChild;
  while ($c) {
    Debug("]") if $severe;
    doctest_rec($self, $node, $c, $severe);
    Debug("[nc") if $severe;
    $c = $c->nextSibling; }
  Debug("]done") if $severe;
  return; }

#**********************************************************************
# This should be called before returning the final XML::LibXML::Document to the
# outside world.  It resolves the fonts for each node relative to it's ancestors.
# It removes the `helper' attributes that store fonts, source box, etc.
sub finalize {
  my ($self) = @_;
  pruneXMDuals($self);
  if (my $root = getDocument($self)->documentElement) {
    local $LaTeXML::FONT = LaTeXML::Common::Font->textDefault;
    finalize_rec($self, $root);
    set_RDFa_prefixes(getDocument($self), $STATE->lookupValue('RDFa_prefixes')); }
  #  return $$self{document}; }
  return $self; }

sub finalize_rec {
  my ($self, $node) = @_;
  my $model = $$self{model};
  no warnings 'recursion';
  my $qname = $model->getNodeQName($node);
  # _standalone_font is typically for metadata that gets extracted out of context
  my $declared_font = ($node->getAttribute('_standalone_font')
    ? LaTeXML::Common::Font->textDefault : $LaTeXML::FONT);
  my $desired_font        = $LaTeXML::FONT;
  my %pending_declaration = ();
  if (my $comment = $node->getAttribute('_pre_comment')) {
    $node->parentNode->insertBefore(XML::LibXML::Comment->new($comment), $node); }
  if (my $comment = $node->getAttribute('_comment')) {
    $node->parentNode->insertAfter(XML::LibXML::Comment->new($comment), $node); }

  if (my $font_attr = $node->getAttribute('_font')) {
    $desired_font        = $$self{node_fonts}{$font_attr};
    %pending_declaration = $desired_font->relativeTo($declared_font);
    if (($node->hasChildNodes || $node->getAttribute('_force_font'))
      && scalar(keys %pending_declaration)) {
      foreach my $attr (keys %pending_declaration) {
        # Add (or combine, for @class) the attributes to the current node.
        if ($model->canHaveAttribute($qname, $attr)) {
          my $value = $pending_declaration{$attr}{value};
          if ($attr eq 'class') {    # Generalize?
            if (my $ovalue = $node->getAttribute('class')) {
              $value .= ' ' . $ovalue; } }
          setAttribute($self, $node, $attr => $value);

          # Merge to set the font currently in effect
          $declared_font = $declared_font->merge(%{ $pending_declaration{$attr}{properties} });
          delete $pending_declaration{$attr}; } }
  } }
  # Optionally add ids to all nodes (AFTER all parsing, rearrangement, etc)
  if ($STATE && $STATE->lookupValue('GENERATE_IDS')
    && !$node->hasAttribute('xml:id')
    && canHaveAttribute($self, $qname, 'xml:id')
    && ($qname ne 'ltx:document')) {
    LaTeXML::Package::GenerateID($self, $node); }

  local $LaTeXML::FONT = $declared_font;
  foreach my $child ($node->childNodes) {
    my $type = $child->nodeType;
    if ($type == XML_ELEMENT_NODE) {
      my $was_forcefont = $child->getAttribute('_force_font');
      finalize_rec($self, $child);
      # Also check if child is  $FONT_ELEMENT_NAME  AND has no attributes
      # AND providing $node can contain that child's content, we'll collapse it.
      if (($model->getNodeQName($child) eq $FONT_ELEMENT_NAME)
        && !$was_forcefont && !$child->hasAttributes) {
        my @grandchildren = $child->childNodes;
        if (!grep { !canContain($self, $qname, $_) } @grandchildren) {
          replaceNode($self, $child, @grandchildren); } }
    }
    # On the other hand, if the font declaration has NOT been effected,
    # We'll need to put an extra wrapper around the text!
    # This is usually ltx:text, but Font information can override this (eg. for \emph)
    elsif ($type == XML_TEXT_NODE) {
      # Remove any pending declarations that can't be on $FONT_ELEMENT_NAME
      my $elementname = $pending_declaration{element}{value} || $FONT_ELEMENT_NAME;
      delete $pending_declaration{element};    # If any...
      foreach my $key (keys %pending_declaration) {
        delete $pending_declaration{$key} unless canHaveAttribute($self, $elementname, $key); }
      if (canContain($self, $qname, $elementname)
        && scalar(keys %pending_declaration)) {
        # Too late to do wrapNodes?
        my $text = wrapNodes($self, $elementname, $child);
        # Add (or combine) attributes
        foreach my $attr (keys %pending_declaration) {
          my $value = $pending_declaration{$attr}{value};
          if ($attr eq 'class') {    # Generalize?
            if (my $ovalue = $text->getAttribute('class')) {
              $value .= ' ' . $ovalue; } }
          setAttribute($self, $text, $attr => $value); }
        finalize_rec($self, $text);    # Now have to clean up the new node!
      }
  } }

  # Attributes (non-namespaced) that begin with "_" are for internal, temporary, Bookkeeping.
  # Remove them now.
  foreach my $attr ($node->attributes) {
    my $n = $attr->nodeName;
    $node->removeAttribute($n) if $n && $n =~ /^_/; }
  return; }

#======================================================================
# Experimental Serializer
# inserts formatting whitespace ONLY where allowed by the schema
#======================================================================
use Encode;

sub toString {
  #sub serialize {
  my ($self, $format) = @_;
  # This line is to use libxml2's built-in serializer w/indentation heuristic.
  # Apparently, libxml2 is giving us "binary" or byte strings which we'd prefer to have as text.
  #  return decode('UTF-8',getDocument($self)->toString($format)); }
  # This uses our own serializer emulating libxml2's heuristic indentation.
  #  return serialize_aux($self, getDocument($self), 0, 0, 1); }
  # This uses our own serializer w/ correct indentation rules.
  return serialize_aux($self, getDocument($self), 0, 0, 0); }

# We ought to try for something close to C14N (http://www.w3.org/TR/xml-c14n),
# but keep XML declaration, comments and don't convert empty elements.
sub serialize_aux {
  my ($self, $node, $depth, $noindent, $heuristic) = @_;
  no warnings 'recursion';
  my $type   = $node->nodeType;
  my $model  = $$self{model};
  my $indent = ('  ' x $depth);
  if ($type == XML_DOCUMENT_NODE) {
    my @children = $node->childNodes;
    return join('', '<?xml version="1.0" encoding="UTF-8"?>', "\n",
      (map { serialize_aux($self, $_, $depth, $noindent, $heuristic) } @children)); }
  elsif ($type == XML_ELEMENT_NODE) {
    my $tag      = $model->getNodeDocumentQName($node);
    my @children = $node->childNodes;
    # since we're pretty-printing, we _could_ wrap attributes to nominal line length!
    my @anodes  = $node->attributes;
    my %nsnodes = map { $model->getNodeDocumentQName($_) => serialize_attr($_->nodeValue) }
      grep { $_->nodeType == XML_NAMESPACE_DECL } @anodes;
    my %atnodes = map { $model->getNodeDocumentQName($_) => serialize_attr($_->nodeValue) }
      grep { $_->nodeType == XML_ATTRIBUTE_NODE } @anodes;
    my $start = join(' ',
      # start of tag
      '<' . $tag,
      # Namespace declarations
      (map { $_ . '="' . $nsnodes{$_} . '"' } sort keys %nsnodes),
      # Regular attributes
      (map { $_ . '="' . $atnodes{$_} . '"' } sort keys %atnodes)
    );
    my $noindent_children = ($heuristic
      # This emulates libxml2's heuristic
      #     ? $noindent || grep { $_->nodeType != XML_ELEMENT_NODE } @children
      ? $noindent || grep { $_->nodeType == XML_TEXT_NODE } @children
      # This is the "Correct" way to determine whether to add indentation
      : $model->canContain(getNodeQName($self, $node), '#PCDATA'));
    return join('',
      ($noindent ? '' : $indent), $start,
      (scalar(@children)    # with contents.
        ? ('>', ($noindent_children ? '' : "\n"),
          (map { serialize_aux($self, $_, $depth + 1, $noindent_children, $heuristic) } @children),
          ($noindent_children ? '' : $indent), '</' . $tag . '>', ($noindent ? '' : "\n"))
        : ('/>' . ($noindent ? '' : "\n")))); }    # empty element.
  elsif ($type == XML_TEXT_NODE) {                 # NO indentation!
    return serialize_string($node->textContent); }
  elsif ($type == XML_PI_NODE) {
    # should code this by hand, as well...
    return join('', ($noindent ? '' : $indent), $node->toString, ($noindent ? '' : "\n")); }
  elsif ($type == XML_COMMENT_NODE) {
    return join('', '<!-- ', serialize_string($node->textContent), '-->'); }
  else {
    return ''; } }

sub serialize_string {
  my ($string) = @_;
  # Basic entities
  $string =~ s/&/&amp;/g;
  $string =~ s/>/&gt;/g;
  $string =~ s/</&lt;/g;
 # Remove dis-allowed code-points.
 #  $string =~ s/(?:\x{00}-\x{08}|\x{0B}|\x{0C}|\x{0D}-\x{19}|\x{D800}-\x{DFFF}|\x{FFFE}-\x{FFFF})//g;
 # Hmm... the upper ranges gives warning in some Perls...
  $string =~ s/(?:\x{00}-\x{08}|\x{0B}|\x{0C}|\x{0D}-\x{19})//g;
  return $string; }

sub serialize_attr {
  my ($string) = @_;
  $string = serialize_string($string);
  # And escape any remaining special code points
  $string =~ s/"/&quot;/g;
  $string =~ s/\n/&#10;/gs;
  $string =~ s/\t/&#9;/gs;
  return $string; }

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
# Document construction at the Current Insertion Point.
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

#**********************************************************************
# absorb the given $box into the DOM (called from constructors).
# This will return a list of whatever nodes were created.
# Note that this may include nodes that are children of other nodes in the list
# or nodes that are no longer in the document.
# Also, note that when a text nodes is appended to, the complete text node is in the list,
# not just the portion that was added.
# [Note that recording the nodes being constructed isn't all that costly,
# but filtering them for parent/child relations IS, particularly since it usually isn't needed]
#
# A $box that is a Box, or List, or Whatsit, is responsible for carrying out
# its own insertion, but it should ultimately call methods of Document
# that will record the nodes that were created.
# $box can also be a plain string which will be inserted according to whatever
# font, mode, etc, are in %props.
sub absorb {
  my ($self, $object, %props) = @_;
  no warnings 'recursion';
  # Nothing? Skip it
  my @boxes   = ($object);
  my @results = ();
  while (@boxes) {
    my $box = shift(@boxes);
    next unless defined $box;
    # Simply unwind Lists to avoid unneccessary recursion; This occurs quite frequently!
    if (((ref $box) || 'nothing') eq 'LaTeXML::Core::List') {
      unshift(@boxes, $box->unlist);
      next; }
    # A Proper Box or Whatsit? It will handle it.
    if (ref $box) {
      local $LaTeXML::BOX = $box;
      # [ATTEMPT to] only record if we're running in NON-VOID context.
      # [but wantarray seems defined MUCH more than I would have expected!?]
      if ($LaTeXML::RECORDING_CONSTRUCTION || defined wantarray) {
        my @n = ();
        { local $LaTeXML::RECORDING_CONSTRUCTION = 1;
          local @LaTeXML::CONSTRUCTED_NODES = ();
          $box->beAbsorbed($self);
          @n = @LaTeXML::CONSTRUCTED_NODES; }    # These were created just now
        map { recordConstructedNode($self, $_) } @n;    # record these for OUTER caller!
        push(@results, @n); }                           # but return only the most recent set.
      else {
        push(@results, $box->beAbsorbed($self)); } }
    # Else, plain string in text mode.
    elsif (!$props{isMath}) {
      push(@results, openText($self, $box, $props{font} || ($LaTeXML::BOX && $LaTeXML::BOX->getFont))); }
    # Or plain string in math mode.
    # Note text nodes can ONLY appear in <XMTok> or <text>!!!
    # Have we already opened an XMTok? Then insert into it.
    elsif ($$self{model}->getNodeQName($$self{node}) eq $MATH_TOKEN_NAME) {
      push(@results, openMathText_internal($self, $box)); }
    # Else create the XMTok now.
    else {
      # Odd case: constructors that work in math & text can insert raw strings in Math mode.
      push(@results, insertMathToken($self, $box, font => $props{font})); } }
  return @results; }

# Note that a box has been absorbed creating $node;
# This does book keeping so that we can return the sequence of nodes
# that were added by absorbing material.
sub recordConstructedNode {
  my ($self, $node) = @_;
  if ((defined $LaTeXML::RECORDING_CONSTRUCTION)    # If we're recording!
    && (!@LaTeXML::CONSTRUCTED_NODES                # and this node isn't already recorded
      || !$node->isSameNode($LaTeXML::CONSTRUCTED_NODES[-1]))) {
    push(@LaTeXML::CONSTRUCTED_NODES, $node); }
  return; }

sub filterDeletions {
  my ($self, @nodes) = @_;
  my $doc = $$self{document};
  # This test seems to successfully determine inclusion,
  # without requiring the (dangerous? & dubious?) unbindNode to be used.
  return grep { isDescendantOrSelf($_, $doc) } @nodes; }

# Given a list of nodes such as from ->absorb,
# filter out all the nodes that are children of other nodes in the list.
sub filterChildren {
  my ($self, @node) = @_;
  #  return @node;
  #  return ();
  return () unless @node;
  my @n = (shift(@node));
  foreach my $n (@node) {
    push(@n, $n) unless grep { isDescendantOrSelf($n, $_); } @n; }
  return @n; }

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

# Shorthand for open,absorb,close, but returns the new node.
sub insertElement {
  my ($self, $qname, $content, %attrib) = @_;
  my $node = openElement($self, $qname, %attrib);
  if (ref $content eq 'ARRAY') {
    map { absorb($self, $_) } @$content; }
  elsif (defined $content) {
    absorb($self, $content); }
  # In obscure situations, $node may have already gotten closed?
  # close it if it is still open.
  my $c = $$self{node};
  while ($c && ($c->nodeType != XML_DOCUMENT_NODE) && !$c->isSameNode($node)) {
    $c = $c->parentNode; }
  if ($c->isSameNode($node)) {
    closeElement($self, $qname); }
  return $node; }

sub insertMathToken {
  my ($self, $string, %attributes) = @_;
  $attributes{role} = 'UNKNOWN' unless $attributes{role};
  my $qname     = ($attributes{isSpace} ? $MATH_HINT_NAME : $MATH_TOKEN_NAME);
  my $cur_qname = $$self{model}->getNodeQName($$self{node});
  if ($attributes{isSpace} && (defined $string) && ($string =~ /^\s*$/)) {
    $string = undef; }    # Make empty hint, of only spaces
  if (($qname eq $MATH_TOKEN_NAME) && ($cur_qname eq $qname)) {    # Already INSIDE a token!
    openMathText_internal($self, $string) if defined $string;
    return $$self{node}; }
  else {
    my $node = openElement($self, $qname, %attributes);
    my $box  = $attributes{_box} || $LaTeXML::BOX;
    my $font = $attributes{font} || $box->getFont;
    setNodeFont($self, $node, $font);
    setNodeBox($self, $node, $box);
    openMathText_internal($self, $string) if defined $string;
    closeNode_internal($self, $node);    # Should be safe.
    return $node; } }

# Insert a new comment, or append to previous comment.
# Does NOT move the current insertion point to the Comment,
# but may move up past a text node.
sub insertComment {
  my ($self, $text) = @_;
  chomp($text);
  $text =~ s/\-\-+/__/g;
  my $comment;
  my $node     = getElement($self);
  my $prev     = $node && $node->lastChild;
  my $prevtype = $prev && $prev->nodeType;
  if ($$self{node}->nodeType == XML_DOCUMENT_NODE) {
    push(@{ $$self{pending} }, $comment = $$self{document}->createComment(' ' . $text . ' ')); }
  elsif ($prevtype && ($prevtype == XML_COMMENT_NODE)) {
    $comment = $prev;
    $comment->setData($comment->data . "\n     " . $text . ' '); }
  elsif ($prevtype && ($prevtype == XML_TEXT_NODE)) {    # Put comment BEFORE text node
    if (($comment = $prev->previousSibling) && ($comment->nodeType == XML_COMMENT_NODE)) {
      $comment = $node->appendChild($$self{document}->createComment(' ' . $text . ' ')); }
    else {
      $comment = $node->insertBefore($$self{document}->createComment(' ' . $text . ' '), $prev); } }
  else {
    $comment = $node->appendChild($$self{document}->createComment(' ' . $text . ' ')); }
  return $comment; }

# Insert a ProcessingInstruction of the form <?op attr=value ...?>
# Does NOT move the current insertion point to the PI,
# but may move up past a text node.
sub insertPI {
  my ($self, $op, %attrib) = @_;
  # We'll just put these on the document itself.
  # Put these in an attractive order, main "operator" first
  my @keys = ((map { ($attrib{$_} ? ($_) : ()) } qw(class package options)),
    (grep { $_ !~ /^(?:class|package|options)$/ } sort keys %attrib));
  my $data = join(' ', map { $_ . "=\"" . ToString($attrib{$_}) . "\"" } @keys);
  my $pi   = $$self{document}->createProcessingInstruction($op, $data);
  closeText_internal($self);    # Close any open text node
  if ($$self{node}->nodeType == XML_DOCUMENT_NODE) {
    push(@{ $$self{pending} }, $pi); }
  else {
    $$self{document}->insertBefore($pi, $$self{document}->documentElement); }
  return $pi; }

# Insert an empty element before a given node
# Does NOT move the current insertion point
sub insertElementBefore {
  my ($self, $point, $name, %attrib) = @_;
  my $new = $$self{document}->createElement($name);
  $new->setNamespace($LaTeXML::Common::Model::LTX_NAMESPACE, '', 1);
  for my $key (keys %attrib) {
    $new->setAttribute($key, $attrib{$key}); }
  return $point->parentNode->insertBefore($new, $point); }

#**********************************************************************
# Middle level, mostly public, API.
# Handlers for various construction operations.
# General naming: 'open' opens a node at current pos and sets it to current,
# 'close' closes current node(s), inserts opens & closes, ie. w/o moving current

# Tricky: Insert some text in a particular font.
# We need to find the current effective -- being the closest  _declared_ font,
# (ie. it will appear in the elements attributes).  We may also want
# to open/close some elements in such a way as to minimize the font switchiness.
# I guess we should only open/close "text" elements, though.
# [Actually, we'd like the user to _declare_ what element to use....
#  I don't like having "text" built in here!
#  AND, we've assumed that "font" names the relevant attribute!!!]

sub openText {
  my ($self, $text, $font) = @_;
  my $node = $$self{node};
  my $t    = $node->nodeType;
  return if ((!defined $text) || $text =~ /^\s*$/) &&
    (($t == XML_DOCUMENT_NODE)    # Ignore initial whitespace
    || (($t == XML_ELEMENT_NODE) && !canContain($self, $node, '#PCDATA')));
  return if $font->getFamily eq 'nullfont';
  Debug("openText \"$text\" /" . Stringify($font) . " at " . Stringify($node))
    if $LaTeXML::DEBUG{document};
  # Get the desired font attributes, particularly the desired element
  # (usually ltx:text, but let Font override, eg for \emph)
  my $declared_font       = getNodeFont($self, $node);
  my %pending_declaration = $font->relativeTo($declared_font);
  my $elementname         = $pending_declaration{element}{value} || $FONT_ELEMENT_NAME;
  if (($t != XML_DOCUMENT_NODE)    # If not at document begin
    && !(($t == XML_TEXT_NODE) &&    # And not appending text in same font.
      ($font->distance(getNodeFont($self, $node->parentNode)) == 0))) {
    # then we'll need to do some open/close to get fonts matched.
    $node = closeText_internal($self);    # Close text node, if any.
    my ($bestdiff, $closeto) = (99999, $node);
    my $n = $node;
    while ($n->nodeType != XML_DOCUMENT_NODE) {
      my $d = $font->distance(getNodeFont($self, $n));
      if ($d < $bestdiff) {
        $bestdiff = $d;
        $closeto  = $n;
        last if ($d == 0); }
      last if ($$self{model}->getNodeQName($n) ne $elementname) || $n->getAttribute('_noautoclose');
      $n = $n->parentNode; }
    closeToNode($self, $closeto) if $closeto ne $node;    # Move to best starting point for this text.
    openElement($self, $elementname, font => $font,
      _fontswitch => 1, _autoopened => 1, _autoclose => 1)
      if $bestdiff > 0;                                   # Open if needed.
  }
  # Finally, insert the darned text.
  my $tnode = openText_internal($self, $text);
  recordConstructedNode($self, $tnode);
  return $tnode; }

# Mystery:
#  How to deal with font declarations?
#  font vs _font; either must redirect to Font object until they are relativized, at end.
#  When relativizing, should it depend on font attribute on element and/or DTD allowed attribute?
sub openElement {
  my ($self, $qname, %attributes) = @_;
  ProgressStep() if ($$self{progress}++ % $CONSTRUCTION_PROGRESS_QUANTUM) == 0;
  Debug("openElement $qname at " . Stringify($$self{node})) if $LaTeXML::DEBUG{document};
  my $point = find_insertion_point($self, $qname);
  $attributes{_box} = $LaTeXML::BOX unless $attributes{_box};
  my $newnode = openElementAt($self, $point, $qname,
    _font => $attributes{font} || $attributes{_box}->getFont,
    %attributes);
  setNode($self, $newnode);
  return $newnode; }

# Note: This closes the deepest open node of a given type.
# This can cause problems with auto-opened nodes, esp. ones for fontswitches!
# Since this is an "explicit request", we're currently skipping over those nodes,
# ie. we're automatically closing them, even if they're the same type as we're asking to close!!!
# This is kinda risky! Maybe we should try to request closing of specific nodes.
sub closeElement {
  my ($self, $qname) = @_;
  Debug("closeElement $qname at " . Stringify($$self{node})) if $LaTeXML::DEBUG{document};
  closeText_internal($self);
  my ($node, @cant_close) = ($$self{node});
  while ($node->nodeType != XML_DOCUMENT_NODE) {
    my $t = $$self{model}->getNodeQName($node);
    # autoclose until node of same name BUT also close nodes opened' for font switches!
    last if ($t eq $qname) && !(($t eq $FONT_ELEMENT_NAME) && $node->getAttribute('_fontswitch'));
    push(@cant_close, $node) unless canAutoClose($self, $node);
    $node = $node->parentNode; }
  if ($node->nodeType == XML_DOCUMENT_NODE) {    # Didn't find $qname at all!!
    Error('malformed', $qname, $self,
      "Attempt to close " . ($qname eq '#PCDATA' ? $qname : '</' . $qname . '>') . ", which isn't open",
      "Currently in " . getInsertionContext($self));
    return; }
  else {                                         # Found node.
                                                 # Intervening non-auto-closeable nodes!!
    Error('malformed', $qname, $self,
      "Closing " . ($qname eq '#PCDATA' ? $qname : '</' . $qname . '>')
        . " whose open descendents do not auto-close",
      "Descendents are " . join(', ', map { Stringify($_) } @cant_close))
      if @cant_close;
    # So, now close up to the desired node.
    closeNode_internal($self, $node);
    return $node; } }

# Check whether it is possible to open $qname at this point,
# possibly by autoOpen'ing & autoClosing other tags.
sub isOpenable {
  my ($self, $qname) = @_;
  my $node = $$self{node};
  while ($node) {
    return 1 if canContainSomehow($self, $node, $qname);
    return 0 unless canAutoClose($self, $node);    # could close, then check if parent can contain
    $node = $node->parentNode; }
  return 0; }

# Check whether it is possible to close each element in @tags,
# any intervening nodes must be autocloseable.
# returning the last node that would be closed if it is possible,
# otherwise undef.
sub isCloseable {
  my ($self, @tags) = @_;
  my $node = $$self{node};
  $node = $node->parentNode if $node->nodeType == XML_TEXT_NODE;
  while (my $qname = shift(@tags)) {
    while (1) {
      return if $node->nodeType == XML_DOCUMENT_NODE;
      my $this_qname = $$self{model}->getNodeQName($node);
      last if $this_qname eq $qname;
      return unless canAutoClose($self, $node);
      $node = $node->parentNode; }
    $node = $node->parentNode if @tags; }
  return $node; }

# Close $qname, if it is closeable.
sub maybeCloseElement {
  my ($self, $qname) = @_;
  Debug("maybeCloseNode(int) $qname") if $LaTeXML::DEBUG{document};
  if (my $node = isCloseable($self, $qname)) {
    closeNode_internal($self, $node);
    return $node; } }

# This closes all nodes until $node becomes the current point.
sub closeToNode {
  my ($self, $node, $ifopen) = @_;
  my $model = $$self{model};
  my ($t, @cant_close) = ();
  my $n = $$self{node};
  my $lastopen;
  # go up the tree from current node, till we find $node
  while ((($t = $n->getType) != XML_DOCUMENT_NODE) && !$n->isSameNode($node)) {
    push(@cant_close, $n) unless canAutoClose($self, $n);
    $lastopen = $n;
    $n        = $n->parentNode; }
  if ($t == XML_DOCUMENT_NODE) {    # Didn't find $node at all!!
    Error('malformed', $model->getNodeQName($node), $self,
      "Attempt to close to " . Stringify($node) . ", which isn't open",
      "Currently in " . getInsertionContext($self)) unless $ifopen;
    return; }
  else {                            # Found node.
    Error('malformed', $model->getNodeQName($node), $self,
      "Closing to " . Stringify($node) . " whose open descendents do not auto-close",
      "Descendents are " . join(', ', map { Stringify($_) } @cant_close))
      if @cant_close;               # But found has intervening non-auto-closeable nodes!!
    closeNode_internal($self, $lastopen) if $lastopen; }
  return; }

# This closes all nodes until $node is closed.
sub closeNode {
  my ($self, $node) = @_;
  my $model = $$self{model};
  my ($t, @cant_close) = ();
  my $n = $$self{node};
  Debug("To closeNode " . Stringify($node)) if $LaTeXML::DEBUG{document};
  while ((($t = $n->getType) != XML_DOCUMENT_NODE) && !$n->isSameNode($node)) {
    push(@cant_close, $n) unless canAutoClose($self, $n);
    $n = $n->parentNode; }
  if ($t == XML_DOCUMENT_NODE) {    # Didn't find $qname at all!!
    Error('malformed', $model->getNodeQName($node), $self,
      "Attempt to close " . Stringify($node) . ", which isn't open",
      "Currently in " . getInsertionContext($self)); }
  else {                            # Found node.
                                    # Intervening non-auto-closeable nodes!!
    Error('malformed', $model->getNodeQName($node), $self,
      "Closing " . Stringify($node) . " whose open descendents do not auto-close",
      "Descendents are " . join(', ', map { Stringify($_) } @cant_close))
      if @cant_close;
    closeNode_internal($self, $node); }
  return; }

sub maybeCloseNode {
  my ($self, $node) = @_;
  my $model = $$self{model};
  my ($t, @cant_close) = ();
  my $n = $$self{node};
  Debug("To closeNode " . Stringify($node)) if $LaTeXML::DEBUG{document};
  while ((($t = $n->getType) != XML_DOCUMENT_NODE) && !$n->isSameNode($node)) {
    push(@cant_close, $n) unless canAutoClose($self, $n);
    $n = $n->parentNode; }
  if ($t == XML_DOCUMENT_NODE) { }    # Didn't find $qname at all!!
  else {                              # Found node.
                                      # Intervening non-auto-closeable nodes!!
    Info('malformed', $model->getNodeQName($node), $self,
      "Closing " . Stringify($node) . " whose open descendents do not auto-close",
      "Descendents are " . join(', ', map { Stringify($_) } @cant_close))
      if @cant_close;
    closeNode_internal($self, $node); }
  return; }

# Add the given attribute to the nearest node that is allowed to have it.
sub addAttribute {
  my ($self, $key, $value) = @_;
  return unless defined $value;
  my $node = $$self{node};
  $node = $node->parentNode if $node->nodeType == XML_TEXT_NODE;
  while (($node->nodeType != XML_DOCUMENT_NODE) && !$$self{model}->canHaveAttribute($node, $key)) {
    $node = $node->parentNode; }
  if ($node->nodeType == XML_DOCUMENT_NODE) {
    Error('malformed', $key, $self,
      "Attribute $key not allowed in this node or ancestors"); }
  else {
    setAttribute($self, $node, $key, $value); }
  return; }

#**********************************************************************
# Low level internal interface

# Return a string indicating the path to the current insertion point in the document.
# if $levels is defined, show only that many levels
sub getInsertionContext {
  my ($self, $levels) = @_;
  if (!defined $levels) {    # Default depth is based on verbosity
    $levels = 5 if ($LaTeXML::Common::Error::VERBOSITY <= 1); }
  my $node = $$self{node};
  my $type = $node->nodeType;
  if (($type != XML_TEXT_NODE) && ($type != XML_ELEMENT_NODE) && ($type != XML_DOCUMENT_NODE)) {
    Error('internal', 'context', $self,
      "Insertion point is not an element, document or text: ", Stringify($node));
    return; }
  my $path = Stringify($node);
  while ($node = $node->parentNode) {
    if ((defined $levels) && (--$levels <= 0)) { $path = '...' . $path; last; }
    $path = Stringify($node) . $path; }
  return $path; }

# Find the node where an element with qualified name $qname can be inserted.
# This will move up the tree (closing auto-closable elements),
# or down (inserting auto-openable elements), as needed.
sub find_insertion_point {
  my ($self, $qname, $has_opened) = @_;
  closeText_internal($self);    # Close any current text node.
  my $cur_qname = $$self{model}->getNodeQName($$self{node});
  my $inter;
  # If $qname is allowed at the current point, we're done.
  if (canContain($self, $cur_qname, $qname)) {
    return $$self{node}; }
  # Else, if we can create an intermediate node that accepts $qname, we'll do that.
  elsif (($inter = canContainIndirect($self, $cur_qname, $qname))
    && ($inter ne $qname) && ($inter ne $cur_qname)) {
    Debug("Need intermediate $inter to open $qname") if $LaTeXML::DEBUG{document};
    openElement($self, $inter, _autoopened => 1,
      font => getNodeFont($self, $$self{node}));
    return find_insertion_point($self, $qname, $inter); }    # And retry insertion (should work now).
  elsif ($has_opened) {    # out of options if already inside an auto-open chain
    Error('malformed', $qname, $self,
      ($qname eq '#PCDATA' ? $qname : '<' . $qname . '>') . " failed auto-open through <$has_opened> at inadmissible <$cur_qname>",
      "Currently in " . getInsertionContext($self));
    return $$self{node}; }    # But we'll do it anyway, unless Error => Fatal.
  else {                      # Now we're getting more desparate...
                              # Check if we can auto close some nodes, and _then_ insert the $qname.
    my ($node, $closeto) = ($$self{node});
    while (($node->nodeType != XML_DOCUMENT_NODE) && canAutoClose($self, $node)) {
      my $parent = $node->parentNode;
      if (canContainSomehow($self, $parent, $qname)) {
        $closeto = $node; last; }
      $node = $parent; }
    if ($closeto) {
      my $closeto_qname = $$self{model}->getNodeQName($closeto);
      closeNode_internal($self, $closeto);             # Close the auto closeable nodes.
      return find_insertion_point($self, $qname); }    # Then retry, possibly w/auto open's
    else {                                             # Didn't find a legit place.
      Error('malformed', $qname, $self,
        ($qname eq '#PCDATA' ? $qname : '<' . $qname . '>') . " isn't allowed in <$cur_qname>",
        "Currently in " . getInsertionContext($self));
      return $$self{node}; } } }                       # But we'll do it anyway, unless Error => Fatal.

sub getInsertionCandidates {
  my ($node) = @_;
  my @nodes = ();
  # Check the current element FIRST, then build list of candidates.
  my $first = $node;
  $first = $first->parentNode if $first && $first->getType == XML_TEXT_NODE;
  my $isCapture = $first && ($first->localname || '') eq '_Capture_';
  push(@nodes, $first) if $first && $first->getType != XML_DOCUMENT_NODE && !$isCapture;
  # Collect previous siblings, if node is a text node.
  # OR if it is a effectively a text node (ltx:para/ltx:p/text)!!!
  my $do_sibs = $node->getType == XML_TEXT_NODE;
  # Now collect (element) node & ancestors
  while ($node && ($node->nodeType != XML_DOCUMENT_NODE)) {
    my $n = $node;
    if (($node->localname || '') eq '_Capture_') {
      push(@nodes, element_nodes($node)); }
    else {
      push(@nodes, $node); }
    if ($do_sibs && ($n = $node->previousSibling)) {
      $node = $n;
    }
    else {
      $node = $node->parentNode;
      my $t = $node->localname || '';
      $do_sibs = 0 unless ($t eq 'p') || ($t eq 'para');
  } }
  push(@nodes, $first) if $isCapture;
  return @nodes; }

# The following "floatTo" operations find an appropriate point
# within the document tree preceding the current insertion point.
# They return undef (& issue a warning) if such a point cannot be found.
# Otherwise, they move the current insertion point to the appropriate node,
# and return the previous insertion point.
# After you make whatever changes (insertions or whatever) to the tree,
# you should do
#   $document->setNode($savenode)
# to reset the insertion point to where it had been.

# Find a node in the document that can contain an element $qname
sub floatToElement {
  my ($self, $qname, $closeifpossible) = @_;
  my @candidates = getInsertionCandidates($$self{node});
  my $closeable  = 1;
  # If the current node can contain already, we're fine right here - just return
  if (@candidates && canContain($self, $candidates[0], $qname)) {
# Edge case: Don't resume at a text node, if it is current. Don't append more to it after other insertions.
    setNode($self, $candidates[0]) if $$self{node}->getType == XML_TEXT_NODE;
    return $candidates[0]; }
  while (@candidates && !canContain($self, $candidates[0], $qname)) {
    $closeable &&= canAutoClose($self, $candidates[0]);
    shift(@candidates); }
  if (my $n = shift(@candidates)) {
    if ($closeifpossible && $closeable) {
      closeToNode($self, $n); }
    else {
      my $savenode = $$self{node};
      setNode($self, $n);
      Debug("Floating from " . Stringify($savenode) . " to " . Stringify($n) . " for $qname")
        if ($$savenode ne $$n) && $LaTeXML::DEBUG{document};
      return $savenode; } }
  else {
    Warn('malformed', $qname, $self, "No open node can contain element '$qname'",
      getInsertionContext($self))
      unless canContainSomehow($self, $$self{node}, $qname); }
  return; }

# Find a node in the document that can accept the attribute $key
sub floatToAttribute {
  my ($self, $key) = @_;
  my @candidates = getInsertionCandidates($$self{node});
  while (@candidates && !canHaveAttribute($self, $candidates[0], $key)) {
    shift(@candidates); }
  if (my $n = shift(@candidates)) {
    my $savenode = $$self{node};
    setNode($self, $n);
    return $savenode; }
  else {
    Warn('malformed', $key, $self, "No open node can get attribute '$key'",
      getInsertionContext($self));
    return; } }

# find a node that can accept a label.
# A bit more than just whether the element can have the attribute, but
# whether it has an id (and ideally either a refnum or title)
# Moreover, can commonly occur after an already-closed (probably empty) element like bibliography
sub floatToLabel {
  my ($self) = @_;
  my $key    = 'labels';
  my $start  = $$self{node};
  if ($start && ($start->nodeType == XML_ELEMENT_NODE)) {
    if (my $last = $start->lastChild) {
      $start = $last; } }
  my @ancestors  = grep { $_->nodeType == XML_ELEMENT_NODE } getInsertionCandidates($start);
  my @candidates = @ancestors;
  # Should we only accept a node that already has an id, or should we create an id?
  while (@candidates
    && !(canHaveAttribute($self, $candidates[0], $key)
      && $candidates[0]->hasAttribute('xml:id'))) {
    shift(@candidates); }
  my $node = shift(@candidates);
  if (!$node) {    # No appropriate ancestor?
    my $sib = $ancestors[0] && $ancestors[0]->lastChild;
    if ($sib && canHaveAttribute($self, $sib, $key)
      && $sib->hasAttribute('xml:id')) {
      $node = $sib; }
    elsif (@ancestors) {    # just take root element?
      $node = $ancestors[-1]; } }
  if ($node) {
    my $savenode = $$self{node};
    setNode($self, $node);
    return $savenode; }
  else {
    Warn('malformed', $key, $self, "No open node with an xml:id can get attribute '$key'",
      getInsertionContext($self));
    return; } }

sub openText_internal {
  my ($self, $text) = @_;
  return $$self{node} unless defined $text;
  my ($qname, $p, $pp);
  if ($$self{node}->nodeType == XML_TEXT_NODE) {    # current node already is a text node.
    Debug("Appending text \"$text\" to " . Stringify($$self{node})) if $LaTeXML::DEBUG{document};
    my $parent = $$self{node}->parentNode;
    if ($LaTeXML::BOX && $parent->getAttribute('_autoopened')) {
      appendNodeBox($self, $parent, $LaTeXML::BOX); }
    $$self{node}->appendData($text); }
  elsif (($p = $$self{node}->lastChild) && ($p->nodeType == XML_COMMENT_NODE)
    && ($pp = $p->previousSibling) && ($pp->nodeType == XML_TEXT_NODE)) {
    # Avoid spliting text runs: Swap <text><comment> to <comment><text> and THEN append $text
    $$self{node}->insertAfter($pp, $p);
    $$self{node} = $pp;
    openText_internal($self, $text); }
  elsif (($text =~ /\S/)                            # If non space
    || canContain($self, $$self{node}, '#PCDATA')) {    # or text allowed here
    my $point = find_insertion_point($self, '#PCDATA');
    my $node  = $$self{document}->createTextNode($text);
    if ($point->getAttribute('_autoopened')) {
      appendNodeBox($self, $point, $LaTeXML::BOX); }
    Debug("Inserting text node for \"$text\" into " . Stringify($point))
      if $LaTeXML::DEBUG{document};
    $point->appendChild($node);
    setNode($self, $node); }
  return $$self{node}; }    # return the text node (current)

# Question: Why do I have math ligatures handled within openMathText_internal,
# but text ligatures handled within closeText_internal ???

sub openMathText_internal {
  my ($self, $string) = @_;
  # And if there's already text???
  my $node = $$self{node};
  my $font = getNodeFont($self, $node);
  $node->appendText($string);
  if (!$STATE->lookupValue('NOMATHPARSE')) {
    applyMathLigatures($self, $node); }
  return $node; }

# New stategy (but inefficient): apply ligatures until one succeeds,
# then remove it, and repeat until ALL (remaining) fail.
sub applyMathLigatures {
  my ($self, $node) = @_;
  if (my $ligatures = $STATE->lookupValue('MATH_LIGATURES')) {
    my @ligatures = @$ligatures;
    while (@ligatures) {
      my $matched = 0;
      foreach my $ligature (@ligatures) {
        if (applyMathLigature($self, $node, $ligature)) {
          @ligatures = grep { $_ ne $ligature } @ligatures;
          $matched   = 1;
          last; } }
      return unless $matched; } }
  return; }

# Apply ligature operation to $node, presumed the last insertion into it's parent(?)
# and presumably an ltx:XMTok
sub applyMathLigature {
  my ($self,     $node,      $ligature) = @_;
  my ($nmatched, $newstring, %attr)     = &{ $$ligature{matcher} }($self, $node);
  if ($nmatched) {
    my @boxes = (getNodeBox($self, $node));
    $node->firstChild->setData($newstring);
    my $prev = $node;
    for (my $i = 0 ; $i < $nmatched - 1 ; $i++) {
      my $remove = $prev->previousSibling;
      unshift(@boxes, getNodeBox($self, $remove));
      if ($remove->nodeType == XML_COMMENT_NODE) { $prev = $remove; }                # keep comments
      else                                       { removeNode($self, $remove); } }
## This fragment replaces the node's box by the composite boxes it replaces
## HOWEVER, this gets things out of sync because parent lists of boxes still
## have the old ones.  Unless we could recursively replace all of them, we'd better skip it(??)
    if (scalar(@boxes) > 1) {
      setNodeBox($self, $node, List(@boxes, mode => 'math')); }
    foreach my $key (sort keys %attr) {
      my $value = $attr{$key};
      if (defined $value) {
        $node->setAttribute($key => $value); }
      else {
        $node->removeAttribute($key); } }
    return 1; }
  else {
    return; } }

# Closing a text node is a good time to apply regexps (aka. Ligatures)
sub closeText_internal {
  my ($self) = @_;
  my $node = $$self{node};
  if ($node->nodeType == XML_TEXT_NODE) {    # Current node is text?
    my $parent  = $node->parentNode;
    my $font    = getNodeFont($self, $parent);
    my $string  = $node->data;
    my $ostring = $string;
    my $fonttest;
    if (my $ligatures = $STATE->lookupValue('TEXT_LIGATURES')) {
      foreach my $ligature (@$ligatures) {
        next if ($fonttest = $$ligature{fontTest}) && !&$fonttest($font);
        $string = &{ $$ligature{code} }($string); } }
    $node->setData($string) unless $string eq $ostring;
    Debug("LIGATURE $ostring => $string") if $LaTeXML::DEBUG{document} && ($string ne $ostring);
    $$self{node} = $parent;    # Effectively closed (->setNode, but don't recurse)
    return $parent; }
  else {
    return $node; } }

# Close $node, and any current nodes below it.
# No checking! Use this when you've already verified that $node can be closed.
# and, of course, $node must be current or some ancestor of it!!!
sub closeNode_internal {
  my ($self, $node) = @_;
  my $closeto = $node->parentNode;            # Grab now in case afterClose screws the structure.
  my $n       = closeText_internal($self);    # Close any open text node.
  while ($n->nodeType == XML_ELEMENT_NODE) {
    closeElementAt($self, $n);
    autoCollapseChildren($self, $n);
    last if $node->isSameNode($n);
    $n = $n->parentNode; }
  Debug("closeNode(int) " . Stringify($$self{node})) if $LaTeXML::DEBUG{document};
  setNode($self, $closeto);
  #  autoCollapseChildren($self, $node);
  return $$self{node}; }

# If these attributes are present on both of two nodes,
# it should inhibit merging those two nodes  (typically a child into parent).
our %non_mergeable_attributes = map { $_ => 1; }
  qw(about aboutlabelref aboutidref
  resource resourcelabelref resourceidref
  property rel rev tyupeof datatype content
  data datamimetype dataencoding
  framed);

# Avoid redundant nesting of font switching elements:
# If we're closing a node that can take font switches and it contains
# a single FONT_ELEMENT_NAME node; pull it up.
sub autoCollapseChildren {
  my ($self, $node) = @_;
  my $model = $$self{model};
  my $qname = $model->getNodeQName($node);
  my @c;
  if (($qname ne 'ltx:_Capture_')
    && (scalar(@c = $node->childNodes) == 1)                 # with single child
    && ($model->getNodeQName($c[0]) eq $FONT_ELEMENT_NAME)
    # AND, $node can have all the attributes that the child has (but at least 'font')
    && !(grep { !$model->canHaveAttribute($qname, $_) }
      ('font', grep { /^[^_]/ } map { $_->nodeName } $c[0]->attributes))
    # AND, $node doesn't have any attributes which collide!
    && !(grep { $non_mergeable_attributes{ $_->nodeName }; } $c[0]->attributes)
    # BUT, it isn't being forced somehow
    && !$c[0]->hasAttribute('_force_font')) {
    my $c = $c[0];
    setNodeFont($self, $node, getNodeFont($self, $c));
    removeNode($self, $c);
    foreach my $gc ($c->childNodes) {
      $node->appendChild($gc);
      recordNodeIDs($self, $node); }
    # Merge the attributes from the child onto $node
    mergeAttributes($self, $c, $node); }
  return; }

# When merging attributes of two nodes, some attributes should be combined
our %merge_attribute_spacejoin = map { $_ => 1; }    # Merged space separated
  qw(class lists inlist labels);
our %merge_attribute_semicolonjoin = map { $_ => 1; }    # Merged ";" separated
  qw(cssstyle);
our %merge_attribute_sumlength = map { $_ => 1; }        # Summed lengths
  qw(xoffset yoffset lpadding rpadding xtranslate ytranslate);
# Merge the attributes from node $from into those of the node $to.
# The presumption is that node $from will be removed afterwards.
# If an attribute is already present on $to, it will be ignored, unless named in $override.
sub mergeAttributes {
  my ($self, $from, $to, $override) = @_;
  # Merge the attributes from the node $from onto the node $to
  foreach my $attr ($from->attributes()) {
    if ($attr->nodeType == XML_ATTRIBUTE_NODE) {
      my $key = $attr->nodeName;
      my $val = $attr->getValue;
      # Special case attributes
      if ($key eq 'xml:id') {    # Use the replacement id
        if (!$to->hasAttribute($key) || ($override && $$override{$key})) {
          # BUT: If $to DID have an attribute, we really should patch any idrefs!!!!!!!
          unRecordID($self, $val);    # presuming that $from will be going away.
          $val = recordID($self, $val, $to);
          $to->setAttribute($key, $val); } }
      elsif ($merge_attribute_spacejoin{$key}) {    # combine space separated values
        addSSValues($self, $to, $key, $val); }
      elsif ($merge_attribute_semicolonjoin{$key}) {    # combine space separated values
        my $oldval = $to->getAttribute($key);
        if ($oldval) {                                  # if duplicate?
          $to->setAttribute($key, $oldval . '; ' . $val); }
        else {
          $to->setAttribute($key, $val); } }
      # Several length attributes should be cummulative; sum them up, if present on both.
      elsif ($merge_attribute_sumlength{$key}) {
        if (my $val2 = $to->getAttribute($key)) {
          my $v1 = $val  =~ /^([\+\-\d\.]*)pt$/ && $1;
          my $v2 = $val2 =~ /^([\+\-\d\.]*)pt$/ && $1;
          $to->setAttribute($key => ($v1 + $v2) . 'pt'); }
        else {
          $to->setAttribute($key => $val); } }
      # Else if attribute not present on $to, or if we specificallly override it, just copy
      elsif ((!$to->hasAttribute($key)) || ($override && $$override{$key})) {
        if (my $ns = $attr->namespaceURI) {
          $to->setAttributeNS($ns, $attr->name, $val); }
        else {
          $to->setAttribute($attr->localname, $val); } } } }
  return; }

#======================================================================
# Make an ltx:ERROR node.
sub makeError {
  my ($self, $type, $content) = @_;
  my $savenode = undef;
  $savenode = floatToElement($self, 'ltx:ERROR')
    unless isOpenable($self, 'ltx:ERROR');
  openElement($self, 'ltx:ERROR', class => ToString($type));
  openText_internal($self, ToString($content));
  closeElement($self, 'ltx:ERROR');
  setNode($self, $savenode) if $savenode;
  return; }

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
# Document surgery (?)
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
# The following carry out DOM modification but NOT relative to any current
# insertion point (eg $$self{node}), but rather relative to nodes specified
# in the arguments.

# Set any allowed attribute on a node, decoding the prefix, if any.
# Also records, and checks, any id attributes.
# [xml:id and namespaced attributes are always allowed]
sub setAttribute {
  my ($self, $node, $key, $value) = @_;
  my $model = $$self{model};
  ## First, a couple of special case internal attributes
  if ($key eq '_box') {
    return $self->setNodeBox($node, $value); }
  elsif ($key eq '_font') {
    return $self->setNodeFont($node, $value); }
  ## Next, verify the attribute allowed by Model, else internal or namespaced
  elsif (($key =~ /:/) || ($key =~ /^_/)
    || $model->canHaveAttribute($model->getNodeQName($node), $key)) {
    ## OK, we're going to use the value, so make sure it's a string.
    if (ref $value) {
      if ((!blessed($value)) || !$value->can('toAttribute')) {
        Warn('unexpected', (ref $value), $self,
          "While setting attribute $key, Don't know how to encode $value",
          Dumper($value));
        return; }
      else {
        $value = $value->toAttribute; } }
    if ((!defined $value) || ($value eq '')) {    # Useless value, after all
      return; }
    if ($key eq 'xml:id') {                       # If it's an ID attribute
      $value = recordID($self, $value, $node);    # Do id book keeping
      ## and bypass all ns stuff
      $node->setAttributeNS($LaTeXML::Common::XML::XML_NS, 'id', $value); }
    elsif ($key =~ /:/) {                         # ANY namespaced attribute
      my ($ns, $name) = $model->decodeQName($key);
      if ($ns) {                                  # If namespaced attribute (must have prefix!
        my $prefix = $node->lookupNamespacePrefix($ns);    # already declared?
        if (!$prefix) {                                    # Nope, not yet!
          ## Create prefix to use, and declare it
          $prefix = $model->getDocumentNamespacePrefix($ns, 1);
          getDocument($self)->documentElement->setNamespace($ns, $prefix, 0); }
        if ($prefix eq '#default') {                       # Probably shouldn't happen...?
          $node->setAttribute($name => $value); }
        else {
          $node->setAttributeNS($ns, "$prefix:$name" => $value); } }
      else {
        $node->setAttribute($name => $value); } }
    else {    # Allowed (but NON-namespaced) or internal attribute
      $node->setAttribute($key => $value); } }
  return; }

sub addSSValues {
  my ($self, $node, $key, $values) = @_;
  $values = $values->toAttribute if ref $values;
  if ((defined $values) && ($values ne '')) {    # Skip if `empty'; but 0 is OK!
    my @values = split(/\s+/, $values);
    if (my $oldvalues = $node->getAttribute($key)) {    # previous values?
      my @old = split(/\s+/, $oldvalues);
      foreach my $new (@values) {
        push(@old, $new) unless grep { $_ eq $new } @old; }
      setAttribute($self, $node, $key => join(' ', sort @old)); }
    else {
      setAttribute($self, $node, $key => join(' ', sort @values)); } }
  return; }

sub addClass {
  my ($self, $node, $value) = @_;
  return addSSValues($self, $node, class => $value); }

sub removeSSValues {
  my ($self, $node, $key, $values) = @_;
  $values = $values->toAttribute if ref $values;
  my @to_remove = split(/\s+/, ($values || ''));
  return unless @to_remove;
  if (my $current_values = $node->getAttribute($key)) {
    my @current_values = split(/\s+/, $current_values);
    my @updated        = ();
    foreach my $current_value (@current_values) {
      push(@updated, $current_value) unless grep { $_ eq $current_value } @to_remove; }
    if (@updated) {
      setAttribute($self, $node, $key => join(' ', sort @updated)); }
    else {    # if no remaining values, delete the attribute
      $node->removeAttribute($key); } }
  return; }

sub removeClass {
  my ($self, $node, $value) = @_;
  removeSSValues($self, $node, class => $value);
  return; }

#**********************************************************************
# Association of nodes and ids (xml:id)

sub recordID {
  my ($self, $id, $node) = @_;
  if (my $prev = $$self{idstore}{$id}) {    # Whoops! Already assigned!!!
                                            # Can we recover?
    if (!$node->isSameNode($prev)) {
      my $badid = $id;
      $id = modifyID($self, $id);
      Info('malformed', 'id', $node, "Duplicated attribute xml:id",
        "Using id='$id' on " . Stringify($node),
        "id='$badid' already set on " . Stringify($prev)); } }
  $$self{idstore}{$id} = $node;
  return $id; }

sub unRecordID {
  my ($self, $id) = @_;
  delete $$self{idstore}{$id};
  return; }

# These are used to record or unrecord, in bulk, all the ids within a node (tree).
sub recordNodeIDs {
  my ($self, $node) = @_;
  foreach my $idnode (findnodes($self, 'descendant-or-self::*[@xml:id]', $node)) {
    if (my $id = $idnode->getAttribute('xml:id')) {
      my $newid = recordID($self, $id, $idnode);
      $idnode->setAttribute('xml:id' => $newid) if $newid ne $id; } }
  return; }

sub unRecordNodeIDs {
  my ($self, $node) = @_;
  foreach my $idnode (findnodes($self, 'descendant-or-self::*[@xml:id]', $node)) {
    if (my $id = $idnode->getAttribute('xml:id')) {
      unRecordID($self, $id); } }
  return; }

# Get a new, related, but unique id
# Sneaky option: try $LaTeXML::Core::Document::ID_SUFFIX as a suffix for id, first.
sub modifyID {
  my ($self, $id) = @_;
  if (my $prev = $$self{idstore}{$id}) {    # Whoops! Already assigned!!!
                                            # Can we recover?
    my $badid = $id;
    if (!$LaTeXML::Core::Document::ID_SUFFIX
      || $$self{idstore}{ $id = $badid . $LaTeXML::Core::Document::ID_SUFFIX }) {
      foreach my $s1 (1 .. 26 * 26 * 26) {    # Gotta give up, eventually; is 3 letters enough?
        return $id unless $$self{idstore}{ $id = $badid . radix_alpha($s1) }; }
      Error('malformed', 'id', $self, "Automatic incrementing of ID counters failed",
        "Last alternative for '$id' is '$badid'"); } }
  return $id; }

sub lookupID {
  my ($self, $id) = @_;
  return $$self{idstore}{$id}; }

#======================================================================
# Odd bit:
# In an XMDual, in each branch (content, presentation) there will be atoms
# that correspond to the input (one will be real, the other an XMRef to the first).
# But also there will be additional "decoration" (delimiters, punctuation, etc on the presentation
# side; other symbols, bindings, whatever, on the content side).
# These decorations should NOT be subject to rewrite rules,
# and in cross-linked parallel markup, they should be attributed to the
# upper containing object's ID, rather than left dangling.
#
# To determine this, we mark all math nodes as to whether they are "visible" from
# presentation, content or both (the default top-level being both).
# Decorations are the nodes that are visible to only one mode.
# Note that nodes that are not visible at all CAN occur (& do currently when the parser
# creates XMDuals), pruneXMDuals (below) gets rid of them.

# NOTE: This should ultimately be in a base Document class,
# since it is also needed before conversion to parallel markup!
sub markXMNodeVisibility {
  my ($self) = @_;
  my @xmath = findnodes($self, '//ltx:XMath/*');
  foreach my $math (@xmath) {
    foreach my $node (findnodes($self, 'descendant-or-self::*[@_pvis or @_cvis]', $math)) {
      $node->removeAttribute('_pvis');
      $node->removeAttribute('_cvis'); } }
  foreach my $math (@xmath) {
    markXMNodeVisibility_aux($self, $math, 1, 1); }
  return; }

sub markXMNodeVisibility_aux {
  no warnings 'recursion';
  my ($self, $node, $cvis, $pvis) = @_;
  my $qname = getNodeQName($self, $node);
  return if (!$cvis || $node->getAttribute('_cvis')) && (!$pvis || $node->getAttribute('_pvis'));
  # Special case: for XMArg used to wrap "formal" arguments on the content side,
  # mark them as visible as presentation as well.
  $pvis = 1 if $cvis && ($qname eq 'ltx:XMArg');
  $node->setAttribute('_cvis' => 1) if $cvis;
  $node->setAttribute('_pvis' => 1) if $pvis;
  if ($qname eq 'ltx:XMDual') {
    my ($c, $p) = element_nodes($node);
    markXMNodeVisibility_aux($self, $c, 1, 0) if $cvis;
    markXMNodeVisibility_aux($self, $p, 0, 1) if $pvis; }
  elsif ($qname eq 'ltx:XMRef') {
    #    markXMNodeVisibility_aux($self, realizeXMNode($self, $node),$cvis,$pvis); }
    my $id = $node->getAttribute('idref');
    if (!$id) {
      my $key = $node->getAttribute('_xmkey');
      Warn('expected', 'id', $self, "Missing idref on ltx:XMRef",
        ($key ? ("_xmkey is $key") : ()));
      return; }
    my $reffed = lookupID($self, $id);
    if (!$reffed) {
      Warn('expected', 'node', $self, "No node found with id=$id (referred to from ltx:XMRef)");
      return; }
    markXMNodeVisibility_aux($self, $reffed, $cvis, $pvis); }
  else {
    foreach my $child (element_nodes($node)) {
      markXMNodeVisibility_aux($self, $child, $cvis, $pvis); } }
  return; }

# Reduce any ltx:XMDual's to just the visible branch, if the other is not visible
# (according to markXMNodeVisibility)
# If we could be 100% sure that the marking had stayed consistent (after various doc surgery)
# we could avoid re-marking, but we'd better be sure before removing nodes!
sub pruneXMDuals {
  my ($self) = @_;
  # RE-mark visibility!
  markXMNodeVisibility($self);
  # will reversing keep from problems removing nodes from trees that already have been removed?
  foreach my $dual (reverse findnodes($self, 'descendant-or-self::ltx:XMDual')) {
    my ($content, $presentation) = element_nodes($dual);
    if (!findnode($self, 'descendant-or-self::*[@_pvis or @_cvis]', $content)) {    # content never seen
      collapseXMDual($self, $dual, $presentation); }
    elsif (!findnode($self, 'descendant-or-self::*[@_pvis or @_cvis]', $presentation)) {    # pres.
      collapseXMDual($self, $dual, $content); }
    else {    # compact aligned structures, where possible
      compactXMDual($self, $dual, $content, $presentation); } }
  return; }

our $content_transfer_overrides = { map { ($_ => 1) } qw(decl_id meaning name omcd) };
our $dual_transfer_overrides    = { %$content_transfer_overrides,
  map { ($_ => 1) } qw(xml:id role) };

sub compactXMDual {
  my ($self, $dual, $content, $presentation) = @_;
  my $c_name = getNodeQName($self, $content);
  my $p_name = getNodeQName($self, $presentation);
  # 1.Quick fix: merge two tokens
  if (($c_name eq 'ltx:XMTok') && ($p_name eq 'ltx:XMTok')) {
    mergeAttributes($self, $content, $presentation, $content_transfer_overrides);
    mergeAttributes($self, $dual,    $presentation, $dual_transfer_overrides);
    replaceNode($self, $dual, $presentation);
    return; }

  # 2.For now, only main use case is compacting mirror XMApp nodes
  return if ($c_name ne 'ltx:XMApp') || ($p_name ne 'ltx:XMApp');
  my @content_args = element_nodes($content);
  my @pres_args    = element_nodes($presentation);
  return if scalar(@content_args) != scalar(@pres_args);

  my @new_args = ();
  # walk the corresponding children, and double-check they are referenced in the same order
  while ((my $c_arg = shift(@content_args)) and (my $p_arg = shift(@pres_args))) {
    my $c_idref = $c_arg->getAttribute('idref');
    if ($c_idref && ($c_idref eq ($p_arg->getAttribute('xml:id') || ''))) {
      push @new_args, $p_arg;
      next; }    # content-refs-pres, OK
    my $p_idref = $p_arg->getAttribute('idref');
    if ($p_idref && ($p_idref eq ($c_arg->getAttribute('xml:id') || ''))) {
      push @new_args, $c_arg;
      next; }    # pres-refs-content, OK

    # we can handle content-side XMToks, to any XM* presentation subtree differing for now.
    if (getNodeQName($self, $c_arg) ne 'ltx:XMTok') {
      return; }
    else { # otherwise we can compact this case. but delay actual libxml changes until we are *sure* the entire tree is compactable
      push(@new_args, [$c_arg, $p_arg]); } }

# If we made it here, this is a dual with two mirrored applications and a single XMTok difference, compact it.
  my $compact_apply = openElementAt($self, $dual->parentNode, 'ltx:XMApp');
  for my $n_arg (@new_args) {
    # one of the args has our dual node that needs compacting
    if (ref $n_arg eq 'ARRAY') {
      my ($c_arg, $p_arg) = @$n_arg;
      mergeAttributes($self, $c_arg, $p_arg, $content_transfer_overrides);
      $n_arg = $p_arg; }
    $n_arg->unbindNode;
    $compact_apply->appendChild($n_arg); }
  # if the dual has any attributes migrate them to the new XMApp
  mergeAttributes($self, $dual, $compact_apply, $dual_transfer_overrides);
  replaceNode($self, $dual, $compact_apply);
  closeElementAt($self, $compact_apply);
  return; }

# Replace an XMDual with one of its branches
sub collapseXMDual {
  my ($self, $dual, $branch) = @_;
  # The other branch is not visible, nor referenced,
  # but the dual may have an id and be referenced
  if (my $dualid = $dual->getAttribute('xml:id')) {
    unRecordID($self, $dualid);    # We'll move or remove the ID from the dual
    if (my $branchid = $branch->getAttribute('xml:id')) {    # branch has id too!
      foreach my $ref (findnodes($self, "//*[\@idref='$dualid']")) {
        $ref->setAttribute(idref => $branchid); } }          # Change dualid refs to branchid
    else {
      $branch->setAttribute('xml:id' => $dualid);            # Just use same ID on the branch
      recordID($self, $dualid => $branch); } }
  replaceTree($self, $branch, $dual);
  return; }

#**********************************************************************
# Record the Box that created this node.
# $box should be a Box/List/Whatsit object; else a previously recorded string
sub setNodeBox {
  my ($self, $node, $box) = @_;
  return unless $box;
  my $boxid = "$box";    # Effectively the address
  if (ref $box) {
    $$self{node_boxes}{$boxid} = $box; }
  elsif (!$$self{node_boxes}{$box}) {
    # Could get string for $box when copying nodes; should already be internned
    Warn('internal', 'nonbox', $self,
      "setNodeBox recording unknown source box: $box"); }
  return $node->setAttribute(_box => $boxid); }

sub getNodeBox {
  my ($self, $node) = @_;
  return unless $node;
  my $t = $node->nodeType;
  return if $t != XML_ELEMENT_NODE;
  if (my $boxid = $node->getAttribute('_box')) {
    return $$self{node_boxes}{$boxid}; } }

# When material is added to an element, especially an autoopened one,
# we need to adjust the record of boxes that created the node.
# (while attempting to avoid duplication)
sub appendNodeBox {
  my ($self, $node, $box) = @_;
  return unless $box;
  $box = $$self{node_boxes}{$box} unless ref $box;
  do {
    my $origbox = getNodeBox($self, $node);
    if(! $origbox){
      setNodeBox($self, $node, $box); }
    elsif (($box eq $origbox) || ($box eq ($origbox->unlist)[-1])) {
      }                         # Already there
    else {
      setNodeBox($self, $node, List($origbox, $box,
        mode => $origbox->getProperty('mode'))); }
    $node = $node->parentNode;
  } while($node && ($node->nodeType == XML_ELEMENT_NODE)
        && $node->getAttribute('_autoopened'));
  return; }

# Similarly when you remove an node, fixup the parent's nodeBox
sub removeNodeBox {
  my ($self, $node, $box) = @_;
  return unless $box;
  $box = $$self{node_boxes}{$box} unless ref $box;
  do {
    my $origbox = getNodeBox($self, $node);
#    Debug("Remove $box (".ToString($box).") from $origbox (".ToString($origbox).")?");
    if(!$origbox){}
    elsif($origbox eq $box){
      $node->removeAttribute('_box'); }
    else {
      my @b = $origbox->unlist;
      # Note that this does NOT see (or remove) boxes embedded within a parent's Whatsit
      if (grep { $_ eq $box; } @b) {
        setNodeBox($self,$node, List((grep { $_ ne $box; } @b),
          mode => $origbox->getProperty('mode'))); } }
    $node = $node->parentNode;
  } while($node && ($node->nodeType == XML_ELEMENT_NODE)
        && $node->getAttribute('_autoopened'));
  return; }

# Record the font used on this node.
# $font should be a Font object; else a previously recorded string
sub setNodeFont {
  my ($self, $node, $font) = @_;
  my $fontid = (ref $font ? $font->toString : $font);
  return unless $font;    # ?
  if ($node->nodeType == XML_ELEMENT_NODE) {
    if (ref $font) {
      $$self{node_fonts}{$fontid} = $font; }
    elsif (!$$self{node_fonts}{$font}) {
      # Could get string for $font when copying nodes; should already be internned
      Warn('internal', 'nonfont', $self,
        "setNodeFont recording unknown font: $font"); }
    $node->setAttribute(_font => $fontid); }
  return; }

# Possibly a sign of a design flaw; Set the node's font & all children that HAD the same font.
sub mergeNodeFontRec {
  my ($self, $node, $font) = @_;
  return unless ref $font;    # ?
  my $oldfont = getNodeFont($self, $node);
  my %props   = $oldfont->purestyleChanges($font);
  my @nodes   = ($node);
  while (my $n = shift(@nodes)) {
    if ($n->nodeType == XML_ELEMENT_NODE) {
      setNodeFont($self, $n, getNodeFont($self, $n)->merge(%props));
      push(@nodes, $n->childNodes); } }
  return; }

sub getNodeFont {
  my ($self, $node) = @_;
  my $t;
  while ($node && (($t = $node->nodeType) != XML_ELEMENT_NODE)) {
    $node = $node->parentNode; }
  my $f;
  return ($node && ($t == XML_ELEMENT_NODE)
      && ($f = $node->getAttribute('_font')) && $$self{node_fonts}{$f})
    || LaTeXML::Common::Font->textDefault(); }

sub getNodeLanguage {
  my ($self, $node) = @_;
  my ($font, $lang);
  while ($node && ($node->nodeType == XML_ELEMENT_NODE)
    && !(($lang = $node->getAttribute('xml:lang'))
      || (($font = $$self{node_fonts}{ $node->getAttribute('_font') })
        && ($lang = $font->getLanguage)))) {
    $node = $node->parentNode; }
  return $lang || 'en'; }

sub decodeFont {
  my ($self, $fontid) = @_;
  return $$self{node_fonts}{$fontid} || LaTeXML::Common::Font->textDefault(); }

# Remove a node from the document (from it's parent)
sub removeNode {
  my ($self, $node) = @_;
  if ($node) {
    my $chopped = $$self{node}->isSameNode($node);    # Note if we're removing insertion point
    my $parent = $node->parentNode;
    if ($node->nodeType == XML_ELEMENT_NODE) {        # If an element, do ID bookkeeping.
      if (my $id = $node->getAttribute('xml:id')) {
        unRecordID($self, $id); }
      if (my $box = getNodeBox($self,$node)) {
        removeNodeBox($self,$parent, $box); }
      $chopped ||= grep { removeNode_aux($self, $_) } $node->childNodes; }
    if ($chopped) {                                   # Don't remove insertion point!
      setNode($self, $parent); }
    $parent->removeChild($node);
  }
  return $node; }

sub removeNode_aux {
  my ($self, $node) = @_;
  my $chopped = $$self{node}->isSameNode($node);
  if ($node->nodeType == XML_ELEMENT_NODE) {    # If an element, do ID bookkeeping.
    if (my $id = $node->getAttribute('xml:id')) {
      unRecordID($self, $id); }
    $chopped ||= grep { removeNode_aux($self, $_) } $node->childNodes; }
  return $chopped; }

#**********************************************************************
# Inserting new nodes at random points into the document,
# typically, later in the process or during some kind of rearrangement.

# This is a somewhat strange situation; There are commands and environments
# that do some interesting thing to their contents. This include things like
# center, flushleft, or rotate, or ...
# Naively one is tempted to create a containing block with appropriate type & attributes.
# However, since these things can be allowed in so many places by LaTeX, that
# one has a difficult time creating a sensible document model.
# The purpose of transformingBlock is to set the contents (possibly creating a
# consistent <p> around them, if called for), and returning the list of newly
# created nodes. These nodes can then have appropriate attributes added as needed
# for each specific case.

# Since this situation can occur in both LaTeX and AmSTeX type documents,
# we'll put it in the TeX pool so it can be reused.

# Tricky bit for creating nodes late in the game,
######
### See createElementAt
# This opens a new element at the _specified_ point, rather than the current insertion point.
# This is useful during document rearrangement or augmentation that may be needed later
# in the process.
sub openElementAt {
  my ($self, $point, $qname, %attributes) = @_;
  my ($ns, $tag) = $$self{model}->decodeQName($qname);
  my $newnode;
  my $font = $attributes{_font} || $attributes{font};
  # If this will be the document root node, things are slightly more involved.
  if ($point->nodeType == XML_DOCUMENT_NODE) {    # First node! (?)
    $$self{model}->addSchemaDeclaration($self, $tag);
    map { $$self{document}->appendChild($_) } @{ $$self{pending} };    # Add saved comments, PI's
    $newnode = $$self{document}->createElement($tag);
    recordConstructedNode($self, $newnode);
    $$self{document}->setDocumentElement($newnode);
    if ($ns) {
      # Here, we're creating the initial, document element, which will hold ALL of the namespace declarations.
      # If there is a default namespace (no prefix), that will also be declared, and applied here.
      # However, if there is ALSO a prefix associated with that namespace, we have to declare it FIRST
      # due to the (apparently) buggy way that XML::LibXML works with namespaces in setAttributeNS.
      my $prefix    = $$self{model}->getDocumentNamespacePrefix($ns);
      my $attprefix = $$self{model}->getDocumentNamespacePrefix($ns, 1, 1);
      if (!$prefix && $attprefix) {
        $newnode->setNamespace($ns, $attprefix, 0); }
      $newnode->setNamespace($ns, $prefix, 1); } }
  else {
    $font    = getNodeFont($self, $point) unless $font;
    $newnode = openElement_internal($self, $point, $ns, $tag); }

  foreach my $key (sort keys %attributes) {
    next if $key eq 'font';       # !!!
    next if $key eq 'locator';    # !!!
    setAttribute($self, $newnode, $key, $attributes{$key}); }
  setNodeFont($self, $newnode, $font)                                      if $font;
  if (my $box = $attributes{_box} || getNodeBox($self,$point) || $LaTeXML::BOX) {
    appendNodeBox($self,$newnode,$box); }
  Debug("Inserting " . Stringify($newnode) . " into " . Stringify($point)) if $LaTeXML::DEBUG{document};
  # Run afterOpen operations
  afterOpen($self, $newnode);
  return $newnode; }

sub openElement_internal {
  my ($self, $point, $ns, $tag) = @_;
  my $newnode;
  if ($ns) {
    if (!defined $point->lookupNamespacePrefix($ns)) {    # namespace not already declared?
      getDocument($self)->documentElement
        ->setNamespace($ns, $$self{model}->getDocumentNamespacePrefix($ns), 0); }
    $newnode = $point->addNewChild($ns, $tag); }
  else {
    $newnode = $point->appendChild($$self{document}->createElement($tag)); }
  recordConstructedNode($self, $newnode);
  return $newnode; }

# Whenever a node has been created using openElementAt,
# closeElementAt ought to be used to close it, when you're finished inserting into $node.
# Basically, this just runs any afterClose operations.
sub closeElementAt {
  my ($self, $node) = @_;
  return afterClose($self, $node); }

sub afterOpen {
  my ($self, $node) = @_;
  # Set current point to this node, just in case the afterOpen's use it.
  my $savenode = $$self{node};
  setNode($self, $node);
  my $box = getNodeBox($self, $node);
  map { &$_($self, $node, $box) } getTagActionList($self, $node, 'afterOpen');
  setNode($self, $savenode);
  return $node; }

sub afterClose {
  my ($self, $node) = @_;
  # Should we set point to this node? (or to last child, or something ??
  my $savenode = $$self{node};
  my $box      = getNodeBox($self, $node);
  map { &$_($self, $node, $box) } getTagActionList($self, $node, 'afterClose');
  setNode($self, $savenode);
  return $node; }

#**********************************************************************
# Appending clones of nodes

# Inserting clones of nodes into the document.
# Nodes that exist in some other part of the document (or some other document)
# will need to be cloned so that they can be part of the new document;
# otherwise, they would be removed from thier previous document.
# Also, we want to have a clean namespace node structure
# (otherwise, libxml2 has a tendency to introduce annoying "default" namespace prefix declarations)
# And, finally, we need to modify any id's present in the old nodes,
# since otherwise they may be duplicated.

# Should have variants here for prepend, insert before, insert after.... ???
sub appendClone {
  my ($self, $node, @newchildren) = @_;
  # Expand any document fragments
  @newchildren = map { ($_->nodeType == XML_DOCUMENT_FRAG_NODE ? $_->childNodes : $_) } @newchildren;
  # Now find all xml:id's in the newchildren and record replacement id's for them
  local %LaTeXML::Core::Document::IDMAP = ();
  # Find all id's defined in the copy and change the id.
  foreach my $child (@newchildren) {
    foreach my $idnode (findnodes($self, './/@xml:id', $child)) {
      my $id = $idnode->getValue;
      $LaTeXML::Core::Document::IDMAP{$id} = modifyID($self, $id); } }
  # Now do the cloning (actually copying) and insertion.
  appendClone_aux($self, $node, @newchildren);
  return $node; }

sub appendClone_aux {
  my ($self, $node, @newchildren) = @_;
  foreach my $child (@newchildren) {
    my $type = $child->nodeType;
    if ($type == XML_ELEMENT_NODE) {
      my $new = openElement_internal($self, $node, $child->namespaceURI, $child->localname);
      foreach my $attr ($child->attributes) {
        if ($attr->nodeType == XML_ATTRIBUTE_NODE) {
          my $key = $attr->nodeName;
          if ($key eq 'xml:id') {    # Use the replacement id
            my $newid = $LaTeXML::Core::Document::IDMAP{ $attr->getValue };
            $newid = recordID($self, $newid, $new);
            $new->setAttribute($key, $newid); }
          elsif ($key eq 'idref') {    # Refer to the replacement id if it was replaced
            my $id = $attr->getValue;
            $new->setAttribute($key, $LaTeXML::Core::Document::IDMAP{$id} || $id); }
          elsif (my $ns = $attr->namespaceURI) {
            $new->setAttributeNS($ns, $attr->name, $attr->getValue); }
          else {
            $new->setAttribute($attr->localname, $attr->getValue); } }
      }
      afterOpen($self, $new);
      appendClone_aux($self, $new, $child->childNodes);
      afterClose($self, $new); }
    elsif ($type == XML_TEXT_NODE) {
      $node->appendTextNode($child->textContent); } }
  return $node; }

#**********************************************************************
# Wrapping & Unwrapping nodes by another element.

# Wrap @nodes with an element named $qname, making the new element replace the first $node,
# and all @nodes becomes the child of the new node.
# [this makes most sense if @nodes are a sequence of siblings]
# Returns undef if $qname isn't allowed in the parent, or if @nodes aren't allowed in $qname,
# otherwise, returns the newly created $qname.
# This executes ->afterClose, only if one of the wrapped nodes is the current node.
sub wrapNodes {
  my ($self, $qname, @nodes) = @_;
  return unless @nodes;
  my $leave_open = 0;
  # Check if any of @nodes, or any of it's children, are the current node, and thus still "open"
  foreach my $n (@nodes) {
    if (isOpen($self, $n)) {
      $leave_open = 1;
      last; } }
  my $model  = $$self{model};
  my $parent = $nodes[0]->parentNode;
  my ($ns, $tag) = $model->decodeQName($qname);
  my $new = openElement_internal($self, $parent, $ns, $tag);
  afterOpen($self, $new);
  $parent->replaceChild($new, $nodes[0]);

  if (my $font = getNodeFont($self, $parent)) {
    setNodeFont($self, $new, $font); }
  if (my $box = getNodeBox($self, $parent)) {
    setNodeBox($self, $new, $box); }
  foreach my $node (@nodes) {
    $new->appendChild($node); }
  afterClose($self, $new) unless $leave_open;
  return $new; }

# Check if $node, or any of it's children, are the current node, and thus still "open"
# Maybe a better way, such as explicitly marking _open ?
sub isOpen {
  my ($self, $node) = @_;
  my $current = $$self{node};
  if ($node->isSameNode($current)) {
    return 1; }
  else {
    foreach my $n ($node->childNodes) {
      return 1 if isOpen($self, $n); }
    return 0; } }

# Unwrap the children of $node, by replacing $node by its children.
sub unwrapNodes {
  my ($self, $node) = @_;
  return replaceNode($self, $node, $node->childNodes); }

# Replace $node by @nodes (presumably descendants of some kind?)
sub replaceNode {
  my ($self, $node, @nodes) = @_;
  my $parent = $node->parentNode;
  my $c0;
  while (my $c1 = shift(@nodes)) {
    if ($c0) { $parent->insertAfter($c1, $c0); }
    else     { $parent->replaceChild($c1, $node); }
    $c0 = $c1; }
  removeNode($self, $node);
  map { appendNodeBox($self,$parent, getNodeBox($self,$_)); } @nodes;
  return $node; }

# initially since $node->setNodeName was broken in XML::LibXML 1.58
# but this can provide for more options & correctness?
sub renameNode {
  my ($self, $node, $newname, $reinsert) = @_;
  my $model = $$self{model};
  my ($ns, $tag) = $model->decodeQName($newname);
  my $parent = $node->parentNode;
  my $new    = openElement_internal($self, $parent, $ns, $tag);
  my $id;
  # Move to the position AFTER $node
  $parent->insertAfter($new, $node);
  # Copy ALL attributes from $node to $newnode
  foreach my $attr ($node->attributes) {
    my $key   = $attr->getName;
    my $value = $node->getAttribute($key);
    $id = $value if $key eq 'xml:id';    # Save to register after removal of old node.
    $new->setAttribute($key, $value) if $model->canHaveAttribute($newname, $key); }
  # AND move all content from $node to $newnode
  if (!$reinsert) {
    foreach my $child ($node->childNodes) {
      $new->appendChild($child); } }
  else {
    my $savenode = $$self{node};
    $$self{node} = $new;
    foreach my $child ($node->childNodes) {
      if ($child->nodeType == XML_TEXT_NODE) {
        openText_internal($self, $child->data);
        closeText_internal($self); }
      else {
        my $point = find_insertion_point($self, getNodeQName($self, $child));
        $point->appendChild($child); } }
    $$self{node} = $savenode; }
  ## THEN call afterOpen... ?
  # It would normally be called before children added,
  # but how can we know if we're duplicated auto-added stuff?
  afterOpen($self, $new);
  afterClose($self, $new);
  # Finally, remove the old node
  removeNode($self, $node);
  # and FINALLY, we can register the new node under the id.
  if ($id) {
    my $newid = recordID($self, $id, $new);
    $new->setAttribute('xml:id' => $newid) if $newid ne $id; }
  return $new; }

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
# Finally, another set of surgery methods
# These take an array representation of the XML Tree to append
#   [tagname,{attributes..}, children]
# THESE SHOULD BE PART OF A COMMON BASE CLASS; DUPLICATED IN Post::Document
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

sub replaceTree {
  my ($self, $new, $old) = @_;
  my $parent    = $old->parentNode;
  my @following = ();                 # Collect the matching and following nodes
  while (my $sib = $parent->lastChild) {
    last if $sib->isSameNode($old);
    $parent->removeChild($sib);       # We're putting these back, in a moment!
    unshift(@following, $sib); }
  removeNode($self, $old);
  appendTree($self, $parent, $new);
  my $inserted = $parent->lastChild;
  map { $parent->appendChild($_) } @following;    # No need for clone
  return $inserted; }

sub appendTree {
  no warnings 'recursion';
  my ($self, $node, @data) = @_;
  foreach my $child (@data) {
    if (ref $child eq 'ARRAY') {
      my ($tag, $attributes, @children) = @$child;
      if (!$tag && !$attributes) {
        appendTree($self, $node, @children); }
      else {
        my $new = openElementAt($self, $node, $tag, ($attributes ? %$attributes : ()));
        appendTree($self, $new, @children);
        closeElementAt($self, $new); } }
    elsif ((ref $child) =~ /^XML::LibXML::/) {
      my $type = $child->nodeType;
      if ($type == XML_ELEMENT_NODE) {
        my $tag = getNodeQName($self, $child);
        my %attributes = map { $_->nodeType == XML_ATTRIBUTE_NODE ? (getNodeQName($self, $_) => $_->getValue) : () }
          $child->attributes;
        # DANGER: REMOVE the xml:id attribute from $child!!!!
        # This protects against some versions of XML::LibXML that warn against duplicate id's
        # Hopefully, you shouldn't be using the node any more
        if (my $id = $attributes{'xml:id'}) {
          $child->removeAttribute('xml:id');
          unRecordID($self, $id); }
        my $new = openElementAt($self, $node, $tag, %attributes);
        appendTree($self, $new, $child->childNodes);
        closeElementAt($self, $new); }
      elsif ($type == XML_DOCUMENT_FRAG_NODE) {
        appendTree($self, $node, $child->childNodes); }
      elsif ($type == XML_TEXT_NODE) {
        $node->appendTextNode($child->textContent); }
    }
    elsif ((ref $child) && $child->isaBox) {
      my $savenode = getNode($self);
      setNode($self, $node);
      absorb($self, $child);
      setNode($self, $savenode); }
    elsif (ref $child) {
      Warn('malformed', $child, $node, "Dont know how to add '$child' to document; ignoring"); }
    elsif (defined $child) {
      $node->appendTextNode($child); } }
  return; }

#**********************************************************************
1;

__END__

=pod

=head1 NAME

C<LaTeXML::Core::Document> - represents an XML document under construction.

=head1 DESCRIPTION

A C<LaTeXML::Core::Document> represents an XML document being constructed by LaTeXML,
and also provides the methods for constructing it.
It extends L<LaTeXML::Common::Object>.

LaTeXML will have digested the source material resulting in a L<LaTeXML::Core::List> (from a L<LaTeXML::Core::Stomach>)
of  L<LaTeXML::Core::Box>s, L<LaTeXML::Core::Whatsit>s and sublists.  At this stage, a document is created
and it is responsible for `absorbing' the digested material.
Generally, the L<LaTeXML::Core::Box>s and L<LaTeXML::Core::List>s create text nodes,
whereas the L<LaTeXML::Core::Whatsit>s create C<XML> document fragments, elements
and attributes according to the defining L<LaTeXML::Core::Definition::Constructor>.

Most document construction occurs at a I<current insertion point> where material will
be added, and which moves along with the inserted material.
The L<LaTeXML::Common::Model>, derived from various declarations and document type,
is consulted to determine whether an insertion is allowed and when elements may need
to be automatically opened or closed in order to carry out a given insertion.
For example, a C<subsection> element will typically be closed automatically when it
is attempted to open a C<section> element.

In the methods described here, the term C<$qname> is used for XML qualified names.
These are tag names with a namespace prefix.  The prefix should be one
registered with the current Model, for use within the code.  This prefix is
not necessarily the same as the one used in any DTD, but should be mapped
to the a Namespace URI that was registered for the DTD.

The arguments named C<$node> are an XML::LibXML node.

The methods here are grouped into three sections covering basic access to the
document, insertion methods at the current insertion point,
and less commonly used, lower-level, document manipulation methods.

=head2 Accessors

=over 4

=item C<< $doc = $document->getDocument; >>

Returns the C<XML::LibXML::Document> currently being constructed.

=item C<< $doc = $document->getModel; >>

Returns the C<LaTeXML::Common::Model> that represents the document model used for this document.

=item C<< $node = $document->getNode; >>

Returns the node at the I<current insertion point> during construction.  This node
is considered still to be `open'; any insertions will go into it (if possible).
The node will be an C<XML::LibXML::Element>, C<XML::LibXML::Text>
or, initially, C<XML::LibXML::Document>.

=item C<< $node = $document->getElement; >>

Returns the closest ancestor to the current insertion point that is an Element.

=item C<< $node = $document->getChildElement($node); >>

Returns a list of the child elements, if any, of the C<$node>.

=item C<< @nodes = $document->getLastChildElement($node); >>

Returns the last child element of the C<$node>, if it has one, else undef.

=item C<< $node = $document->getFirstChildElement($node); >>

Returns the first child element of the C<$node>, if it has one, else undef.

=item C<< @nodes = $document->findnodes($xpath,$node); >>

Returns a list of nodes matching the given C<$xpath> expression.
The I<context node> for C<$xpath> is C<$node>, if given,
otherwise it is the document element.

=item C<< $node = $document->findnode($xpath,$node); >>

Returns the first node matching the given C<$xpath> expression.
The I<context node> for C<$xpath> is C<$node>, if given,
otherwise it is the document element.

=item C<< $node = $document->getNodeQName($node); >>

Returns the qualified name (localname with namespace prefix)
of the given C<$node>.  The namespace prefix mapping is the
code mapping of the current document model.

=item C<< $boolean = $document->canContain($tag,$child); >>

Returns whether an element C<$tag> can contain a child C<$child>.
C<$tag> and C<$child> can be nodes, qualified names of nodes
(prefix:localname), or one of a set of special symbols
C<#PCDATA>, C<#Comment>, C<#Document> or C<#ProcessingInstruction>.

=item C<< $boolean = $document->canContainIndirect($tag,$child); >>

Returns whether an element C<$tag> can contain a child C<$child>
either directly, or after automatically opening one or more autoOpen-able
elements.

=item C<< $boolean = $document->canContainSomehow($tag,$child); >>

Returns whether an element C<$tag> can contain a child C<$child>
either directly, or after automatically opening one or more autoOpen-able
elements.

=item C<< $boolean = $document->canHaveAttribute($tag,$attrib); >>

Returns whether an element C<$tag> can have an attribute named C<$attrib>.

=item C<< $boolean = $document->canAutoOpen($tag); >>

Returns whether an element C<$tag> is able to be automatically opened.

=item C<< $boolean = $document->canAutoClose($node); >>

Returns whether the node C<$node> can be automatically closed.

=back

=head2 Construction Methods

These methods are the most common ones used for construction of documents.
They generally operate by creating new material at the I<current insertion point>.
That point initially is just the document itself, but it moves along to
follow any new insertions.  These methods also adapt to the document model so as to
automatically open or close elements, when it is required for the pending insertion
and allowed by the document model (See L<Tag>).

=over 4

=item C<< $xmldoc = $document->finalize; >>

This method finalizes the document by cleaning up various temporary
attributes, and returns the L<XML::LibXML::Document> that was constructed.


=item C<< @nodes = $document->absorb($digested); >>

Absorb the C<$digested> object into the document at the current insertion point
according to its type.  Various of the the other methods are invoked as needed,
and document nodes may be automatically opened or closed according to the document
model.

This method returns the nodes that were constructed.
Note that the nodes may include children of other nodes,
and nodes that may already have been removed from the document
(See filterChildren and filterDeleted).
Also, text insertions are often merged with existing text nodes;
in such cases, the whole text node is included in the result.

=item C<< $document->insertElement($qname,$content,%attributes); >>

This is a shorthand for creating an element C<$qname> (with given attributes),
absorbing C<$content> from within that new node, and then closing it.
The C<$content> must be digested material, either a single box, or
an array of boxes, which will be absorbed into the element.
This method returns the newly created node,
although it will no longer be the current insertion point.

=item C<< $document->insertMathToken($string,%attributes); >>

Insert a math token (XMTok) containing the string C<$string> with the given attributes.
Useful attributes would be name, role, font.
Returns the newly inserted node.

=item C<< $document->insertComment($text); >>

Insert, and return, a comment with the given C<$text> into the current node.

=item C<< $document->insertPI($op,%attributes); >>

Insert, and return,  a ProcessingInstruction into the current node.

=item C<< $document->openText($text,$font); >>

Open a text node in font C<$font>, performing any required automatic opening
and closing of intermedate nodes (including those needed for font changes)
and inserting the string C<$text> into it.

=item C<< $document->openElement($qname,%attributes); >>

Open an element, named C<$qname> and with the given attributes.
This will be inserted into the current node while  performing
any required automatic opening and closing of intermedate nodes.
The new element is returned, and also becomes the current insertion point.
An error (fatal if in C<Strict> mode) is signalled if there is no allowed way
to insert such an element into the current node.

=item C<< $document->closeElement($qname); >>

Close the closest open element named C<$qname> including any intermedate nodes that
may be automatically closed.  If that is not possible, signal an error.
The closed node's parent becomes the current node.
This method returns the closed node.

=item C<< $node = $document->isOpenable($qname); >>

Check whether it is possible to open a C<$qname> element
at the current insertion point.

=item C<< $node = $document->isCloseable($qname); >>

Check whether it is possible to close a C<$qname> element,
returning the node that would be closed if possible,
otherwise undef.

=item C<< $document->maybeCloseElement($qname); >>

Close a C<$qname> element, if it is possible to do so,
returns the closed node if it was found, else undef.

=item C<< $document->addAttribute($key=>$value); >>

Add the given attribute to the node nearest to the current insertion point
that is allowed to have it. This does not change the current insertion point.

=item C<< $document->closeToNode($node); >>

This method closes all children of C<$node> until C<$node>
becomes the insertion point. Note that it closes any
open nodes, not only autoCloseable ones.

=back

=head3 Internal Insertion Methods

These are described as an aide to understanding the code;
they rarely, if ever, should be used outside this module.

=over 4

=item C<< $document->setNode($node); >>

Sets the I<current insertion point> to be  C<$node>.
This should be rarely used, if at all; The construction methods of document
generally maintain the notion of insertion point automatically.
This may be useful to allow insertion into a different part of the document,
but you probably want to set the insertion point back to the previous
node, afterwards.

=item C<< $string = $document->getInsertionContext($levels); >>

For debugging, return a string showing the context of the current insertion point;
that is, the string of the nodes leading up to it.
if C<$levels> is defined, show only that many nodes.

=item C<< $node = $document->find_insertion_point($qname); >>

This internal method is used to find the appropriate point,
relative to the current insertion point, that an element with
the specified C<$qname> can be inserted.  That position may
require automatic opening or closing of elements, according
to what is allowed by the document model.

=item C<< @nodes = getInsertionCandidates($node); >>

Returns a list of elements where an arbitrary insertion might take place.
Roughly this is a list starting with C<$node>,
followed by its parent and the parents siblings (in reverse order),
followed by the grandparent and siblings (in reverse order).

=item C<< $node = $document->floatToElement($qname); >>

Finds the nearest element at or preceding the current insertion point
(see C<getInsertionCandidates>), that can accept an element C<$qname>;
it moves the insertion point to that point, and returns the previous insertion point.
Generally, after doing whatever you need at the new insertion point,
you should call C<< $document->setNode($node); >> to
restore the insertion point.
If no such point is found, the insertion point is left unchanged,
and undef is returned.

=item C<< $node = $document->floatToAttribute($key); >>

This method works the same as C<floatToElement>, but find
the nearest element that can accept the attribute C<$key>.

=item C<< $node = $document->openText_internal($text); >>

This is an internal method,  used by C<openText>, that assumes the insertion point has
been appropriately adjusted.)

=item C<< $node = $document->openMathText_internal($text); >>

This internal method appends C<$text> to the current insertion point,
which is assumed to be a math node.  It checks for math ligatures and
carries out any combinations called for.

=item C<< $node = $document->closeText_internal(); >>

This internal method closes the current node, which should be a text node.
It carries out any text ligatures on the content.

=item C<< $node = $document->closeNode_internal($node); >>

This internal method closes any open text or element nodes starting
at the current insertion point, up to and including C<$node>.
Afterwards, the parent of C<$node> will be the current insertion point.
It condenses the tree to avoid redundant font switching elements.

=item C<< $document->afterOpen($node); >>

Carries out any afterOpen operations that have been recorded (using C<Tag>)
for the element name of C<$node>.

=item C<< $document->afterClose($node); >>

Carries out any afterClose operations that have been recorded (using C<Tag>)
for the element name of C<$node>.

=back

=head2 Document Modification

The following methods are used to perform various sorts of modification
and rearrangements of the document, after the normal flow of insertion
has taken place.  These may be needed after an environment (or perhaps the whole document)
has been completed and one needs to analyze what it contains to decide
on the appropriate representation.

=over 4

=item C<< $document->setAttribute($node,$key,$value); >>

Sets the attribute C<$key> to C<$value> on C<$node>.
This method is preferred over the direct LibXML one, since it
takes care of decoding namespaces (if C<$key> is a qname),
and also manages recording of xml:id's.

=item C<< $document->recordID($id,$node); >>

Records the association of the given C<$node> with the C<$id>,
which should be the C<xml:id> attribute of the C<$node>.
Usually this association will be maintained by the methods
that create nodes or set attributes.

=item C<< $document->unRecordID($id); >>

Removes the node associated with the given C<$id>, if any.
This might be needed if a node is deleted.

=item C<< $document->modifyID($id); >>

Adjusts C<$id>, if needed, so that it is unique.
It does this by appending a letter and incrementing until it
finds an id that is not yet associated with a node.

=item C<< $node = $document->lookupID($id); >>

Returns the node, if any, that is associated with the given C<$id>.

=item C<< $document->setNodeBox($node,$box); >>

Records the C<$box> (being a Box, Whatsit or List), that
was (presumably) responsible for the creation of the element C<$node>.
This information is useful for determining source locations,
original TeX strings, and so forth.

=item C<< $box = $document->getNodeBox($node); >>

Returns the C<$box> that was responsible for creating the element C<$node>.

=item C<< $document->setNodeFont($node,$font); >>

Records the font object that encodes the font that should be
used to display any text within the element C<$node>.

=item C<< $font = $document->getNodeFont($node); >>

Returns the font object associated with the element C<$node>.

=item C<< $node = $document->openElementAt($point,$qname,%attributes); >>

Opens a new child element in C<$point> with the qualified name C<$qname>
and with the given attributes.  This method is not affected by, nor does
it affect, the current insertion point.  It does manage namespaces,
xml:id's and associating a box, font and locator with the new element,
as well as running any C<afterOpen> operations.

=item C<< $node = $document->closeElementAt($node); >>

Closes C<$node>.  This method is not affected by, nor does
it affect, the current insertion point.
However, it does run any C<afterClose> operations, so any element
that was created using the lower-level C<openElementAt> should
be closed using this method.

=item C<< $node = $document->appendClone($node,@newchildren); >>

Appends clones of C<@newchildren> to C<$node>.
This method modifies any ids found within C<@newchildren>
(using C<modifyID>), and fixes up any references to those ids
within the clones so that they refer to the modified id.

=item C<< $node = $document->wrapNodes($qname,@nodes); >>

This method wraps the C<@nodes> by a new element with qualified name C<$qname>,
that new node replaces the first of C<@node>.
The remaining nodes in C<@nodes> must be following siblings of the first one.

NOTE: Does this need multiple nodes?
If so, perhaps some kind of movenodes helper?
Otherwise, what about attributes?

=item C<< $node = $document->unwrapNodes($node); >>

Unwrap the children of C<$node>, by replacing C<$node> by its children.

=item C<< $node = $document->replaceNode($node,@nodes); >>

Replace C<$node> by C<@nodes>; presumably they are some sort of descendant nodes.

=item C<< $node = $document->renameNode($node,$newname); >>

Rename C<$node> to the tagname C<$newname>; equivalently replace C<$node> by
a new node with name C<$newname> and copy the attributes and contents.
It is assumed that C<$newname> can contain those attributes and contents.

=item C<< @nodes = $document->filterDeletions(@nodes); >>

This function is useful with C<$doc->absorb($box)>,
when you want to filter out any nodes that have been deleted and
no longer appear in the document.

=item C<< @nodes = $document->filterChildren(@nodes); >>

This function is useful with C<$doc->absorb($box)>,
when you want to filter out any nodes that are children of other nodes in C<@nodes>.

=back

=head1 AUTHOR

Bruce Miller <bruce.miller@nist.gov>

=head1 COPYRIGHT

Public domain software, produced as part of work done by the
United States Government & not subject to copyright in the US.

=cut
