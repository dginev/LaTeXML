<?xml version="1.0" encoding="utf-8"?>
<!--
/=====================================================================\
|  Auto-generated schema utility functions for XSLT;                  |
|   DO NOT EDIT BY HAND                                               |
|=====================================================================|
| Part of LaTeXML:                                                    |
|  Public domain software, produced as part of work done by the       |
|  United States Government & not subject to copyright in the US.     |
|=====================================================================|
| Bruce Miller <bruce.miller@nist.gov>                        #_#     |
| http://dlmf.nist.gov/LaTeXML/                              (o o)    |
\=========================================================ooo==U==ooo=/
-->
<xsl:stylesheet
    version     = "1.0"
    xmlns:xsl   = "http://www.w3.org/1999/XSL/Transform"
    xmlns:ltx   = "http://dlmf.nist.gov/LaTeXML"
    xmlns:exsl  = "http://exslt.org/common"
    xmlns:string= "http://exslt.org/strings"
    xmlns:func  = "http://exslt.org/functions"
    xmlns:f     = "http://dlmf.nist.gov/LaTeXML/functions"
    extension-element-prefixes="func f exsl string">
<xsl:param name="LATEXML_NSURI">http://dlmf.nist.gov/LaTeXML</xsl:param>
  <func:function name="f:is_in_schema_class_backmatter">
    <xsl:param name="name"/>
    <xsl:param name="nsuri"/>
    <func:result>
      <xsl:value-of select="not($nsuri and $nsuri != $LATEXML_NSURI) and ($name = 'ERROR' or $name = 'TOC' or $name = 'acknowledgements' or $name = 'appendix' or $name = 'bibliography' or $name = 'declare' or $name = 'figure' or $name = 'float' or $name = 'glossary' or $name = 'glossarydefinition' or $name = 'index' or $name = 'indexmark' or $name = 'navigation' or $name = 'note' or $name = 'pagination' or $name = 'para' or $name = 'proof' or $name = 'rdf' or $name = 'resource' or $name = 'table' or $name = 'theorem')"/>
    </func:result>
  </func:function>

  <func:function name="f:is_in_schema_class_bibentry">
    <xsl:param name="name"/>
    <xsl:param name="nsuri"/>
    <func:result>
      <xsl:value-of select="not($nsuri and $nsuri != $LATEXML_NSURI) and ($name = 'bib-data' or $name = 'bib-date' or $name = 'bib-edition' or $name = 'bib-extract' or $name = 'bib-identifier' or $name = 'bib-key' or $name = 'bib-language' or $name = 'bib-links' or $name = 'bib-name' or $name = 'bib-note' or $name = 'bib-organization' or $name = 'bib-part' or $name = 'bib-place' or $name = 'bib-publisher' or $name = 'bib-related' or $name = 'bib-review' or $name = 'bib-status' or $name = 'bib-subtitle' or $name = 'bib-title' or $name = 'bib-type' or $name = 'bib-url')"/>
    </func:result>
  </func:function>

  <func:function name="f:is_in_schema_class_block">
    <xsl:param name="name"/>
    <xsl:param name="nsuri"/>
    <func:result>
      <xsl:value-of select="not($nsuri and $nsuri != $LATEXML_NSURI) and ($name = 'block' or $name = 'description' or $name = 'enumerate' or $name = 'equation' or $name = 'equationgroup' or $name = 'itemize' or $name = 'listing' or $name = 'p' or $name = 'pagination' or $name = 'quote')"/>
    </func:result>
  </func:function>

  <func:function name="f:is_in_schema_class_caption">
    <xsl:param name="name"/>
    <xsl:param name="nsuri"/>
    <func:result>
      <xsl:value-of select="not($nsuri and $nsuri != $LATEXML_NSURI) and ($name = 'caption' or $name = 'toccaption')"/>
    </func:result>
  </func:function>

  <func:function name="f:is_in_schema_class_equationmeta">
    <xsl:param name="name"/>
    <xsl:param name="nsuri"/>
    <func:result>
      <xsl:value-of select="not($nsuri and $nsuri != $LATEXML_NSURI) and ($name = 'constraint')"/>
    </func:result>
  </func:function>

  <func:function name="f:is_in_schema_class_frontmatter">
    <xsl:param name="name"/>
    <xsl:param name="nsuri"/>
    <func:result>
      <xsl:value-of select="not($nsuri and $nsuri != $LATEXML_NSURI) and ($name = 'abstract' or $name = 'acknowledgements' or $name = 'classification' or $name = 'date' or $name = 'keywords' or $name = 'subtitle')"/>
    </func:result>
  </func:function>

  <func:function name="f:is_in_schema_class_inline">
    <xsl:param name="name"/>
    <xsl:param name="nsuri"/>
    <func:result>
      <xsl:value-of select="not($nsuri and $nsuri != $LATEXML_NSURI) and ($name = 'Math' or $name = 'anchor' or $name = 'bibref' or $name = 'cite' or $name = 'del' or $name = 'emph' or $name = 'glossaryref' or $name = 'ref' or $name = 'rule' or $name = 'sub' or $name = 'sup' or $name = 'text')"/>
    </func:result>
  </func:function>

  <func:function name="f:is_in_schema_class_math">
    <xsl:param name="name"/>
    <xsl:param name="nsuri"/>
    <func:result>
      <xsl:value-of select="not($nsuri and $nsuri != $LATEXML_NSURI) and ($name = 'XMath')"/>
    </func:result>
  </func:function>

  <func:function name="f:is_in_schema_class_meta">
    <xsl:param name="name"/>
    <xsl:param name="nsuri"/>
    <func:result>
      <xsl:value-of select="not($nsuri and $nsuri != $LATEXML_NSURI) and ($name = 'ERROR' or $name = 'declare' or $name = 'glossarydefinition' or $name = 'indexmark' or $name = 'navigation' or $name = 'note' or $name = 'rdf' or $name = 'resource')"/>
    </func:result>
  </func:function>

  <func:function name="f:is_in_schema_class_misc">
    <xsl:param name="name"/>
    <xsl:param name="nsuri"/>
    <func:result>
      <xsl:value-of select="not($nsuri and $nsuri != $LATEXML_NSURI) and ($name = 'break' or $name = 'graphics' or $name = 'inline-block' or $name = 'inline-description' or $name = 'inline-enumerate' or $name = 'inline-itemize' or $name = 'inline-para' or $name = 'picture' or $name = 'rawhtml' or $name = 'rawliteral' or $name = 'tabular' or $name = 'verbatim' or $name = 'svg:svg')"/>
    </func:result>
  </func:function>

  <func:function name="f:is_in_schema_class_para">
    <xsl:param name="name"/>
    <xsl:param name="nsuri"/>
    <func:result>
      <xsl:value-of select="not($nsuri and $nsuri != $LATEXML_NSURI) and ($name = 'TOC' or $name = 'figure' or $name = 'float' or $name = 'pagination' or $name = 'para' or $name = 'proof' or $name = 'table' or $name = 'theorem')"/>
    </func:result>
  </func:function>

  <func:function name="f:is_in_schema_class_person">
    <xsl:param name="name"/>
    <xsl:param name="nsuri"/>
    <func:result>
      <xsl:value-of select="not($nsuri and $nsuri != $LATEXML_NSURI) and ($name = 'contact' or $name = 'personname')"/>
    </func:result>
  </func:function>

  <func:function name="f:is_in_schema_class_picture">
    <xsl:param name="name"/>
    <xsl:param name="nsuri"/>
    <func:result>
      <xsl:value-of select="not($nsuri and $nsuri != $LATEXML_NSURI) and ($name = 'arc' or $name = 'bezier' or $name = 'circle' or $name = 'clip' or $name = 'curve' or $name = 'dots' or $name = 'ellipse' or $name = 'g' or $name = 'grid' or $name = 'line' or $name = 'parabola' or $name = 'path' or $name = 'polygon' or $name = 'rect' or $name = 'wedge' or $name = 'svg:svg')"/>
    </func:result>
  </func:function>

  <func:function name="f:is_in_schema_class_sectionalfrontmatter">
    <xsl:param name="name"/>
    <xsl:param name="nsuri"/>
    <func:result>
      <xsl:value-of select="not($nsuri and $nsuri != $LATEXML_NSURI) and ($name = 'creator' or $name = 'tags' or $name = 'title' or $name = 'toctitle')"/>
    </func:result>
  </func:function>

  <func:function name="f:is_in_schema_class_xmath">
    <xsl:param name="name"/>
    <xsl:param name="nsuri"/>
    <func:result>
      <xsl:value-of select="not($nsuri and $nsuri != $LATEXML_NSURI) and ($name = 'ERROR' or $name = 'XMApp' or $name = 'XMArg' or $name = 'XMArray' or $name = 'XMDual' or $name = 'XMHint' or $name = 'XMRef' or $name = 'XMText' or $name = 'XMTok' or $name = 'XMWrap')"/>
    </func:result>
  </func:function>
</xsl:stylesheet>
