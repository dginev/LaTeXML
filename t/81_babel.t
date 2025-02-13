# -*- CPERL -*-
#**********************************************************************
# Test cases for LaTeXML
#**********************************************************************
use LaTeXML::Util::Test;

latexml_tests("t/babel",
  requires => { '*' => ['babel.sty', 'babel.def'],
    csquotes => { texlive_min => 2015,
      packages => ['csquotes.sty', 'frenchb.ldf', 'germanb.ldf'] },
    numprints => 'numprint.sty',
    german    => 'germanb.ldf',
    greek     => ['greek.ldf', 'lgrenc.def'],
    french    => { texlive_min => 2017,
      packages => ['frenchb.ldf', 'numprint.sty'] },
    page545 => ['germanb.ldf', 'frenchb.ldf'] },
# babel is a bit iffy between versions, especially in introducing/retracting line breaks in the language macros
# so compare it in a space-neutral manner
  compare => 'words');
