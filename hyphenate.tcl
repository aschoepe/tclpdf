#
# tclpdf - PDF generation for Tcl
#
# hyphenate - where a word may be broken, per language
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
#   ::tclpdf::hyphenate load de-DE /usr/share/hyphen/hyph_de_DE.dic
#   ::tclpdf::hyphenate word de-DE Silbentrennung   ;# Sil ben tren nung
#
# NO PATTERNS ARE SHIPPED, and that is a licence decision rather than an
# oversight. Every published pattern set carries terms of its own - the German
# ones LGPL over LPPL, the American English ones a BSD-style notice over the
# plain TeX table, others the LaTeX Project Public License - and this package
# is MIT. Bundling them would make the smallest of the three licences the one a
# user has to read. So the caller loads the file, from wherever that machine
# keeps it, and the licence stays where the file is. A document set on a
# machine without patterns is set unhyphenated, not refused - unless the caller
# asked for a language by name, which is the one case that IS refused (see
# textBlock.tcl).
#
# THE ALGORITHM is Liang's, the one TeX has used since 1983 and the one every
# pattern file in the world is written for. A pattern is a short run of letters
# with numbers between them - ".a1be", "hy3ph", "n1en." - where the dot stands
# for the edge of the word. The word is padded with dots, every pattern that
# occurs anywhere in it is applied, and at each position between two letters
# the HIGHEST number any pattern put there wins. An odd number is a break, an
# even one is not; the even numbers exist to veto the odd ones a shorter
# pattern proposed. There is no dictionary and no morphology in it: the whole
# of German hyphenation is some 9 000 such patterns.
#
# THE FORMAT read here is libhyphen's ".dic" - what LibreOffice, Hunspell and
# the "hyphen" library install, hyph_de_DE.dic and hyph_en_US.dic and their
# fifty siblings. It was chosen over the TeX pattern files, which carry the
# same patterns, because it answers three questions the TeX files leave open:
# it names its own encoding in line one, it states LEFTHYPHENMIN and
# RIGHTHYPHENMIN as data instead of leaving them to a babel language file, and
# it is one pattern per line with no macro syntax to unpack. It is also the
# format already sitting on most machines. A TeX .pat.txt file is the same
# patterns one per line and can be handed to [load] once its first line is a
# encoding name - but that is a conversion, not a second reader, and this
# module has one reader.
#
# TWO-LEVEL FILES. libhyphen lets a file carry several pattern tables
# separated by NEXTLEVEL: the earlier ones mark compound boundaries and are
# driven by a compound algorithm of libhyphen's own, the LAST one is the plain
# Liang table. hyph_de_DE.dic is such a file - 69 000 compound entries, then
# NEXTLEVEL, then the 8 700 patterns of dehyphn.tex. This module reads the LAST
# table and nothing else, so what it does is Liang and only Liang: the same
# breaks TeX would set, which is the reference every one of these files was
# measured against. Measured on hyph_de_DE.dic 2017-01-12, that also makes the
# loaded table an order of magnitude smaller.
#
# WHAT IS NOT BROKEN, because a rule without brakes sets "A-bend": a word
# shorter than -min, a run of fewer letters than the language's left and right
# minimum, anything with a digit in it, a word written in capitals throughout,
# and anything shaped like a URL, an address or a file name - a core that still
# holds a dot, a colon, a slash or an at sign once its punctuation has been
# taken off its ends. What is left is broken; a word that carries a hyphen of
# its own is broken in each of its parts, but never AT the hyphen it already
# has - the line would end in two of them.
#
# U+00AD WINS. A word that already carries soft hyphens is handed back whole,
# not computed: those marks came from a database, an editor or a translator who
# knew the word, and mixing them with computed offers would produce breaks
# neither source asked for. It is one source or the other, never both.
#

package require Tcl 8.6.11-
package require tclpdf::option 1.0-

namespace eval ::tclpdf::hyphenate {
  namespace export {[a-z]*}
  namespace ensemble create

  # What [load] read, keyed by the lowercased language tag.
  variable loaded {}

  # What a file that says nothing is taken to mean: the plain TeX defaults,
  # \lefthyphenmin=2 and \righthyphenmin=3. Files differ in how much they say -
  # hyph_en_US.dic states both, hyph_de_DE.dic states neither although German
  # wants 2 and 2 - which is why -left and -right exist on [load] and why the
  # manual says to pass them for German.
  variable defaultMinima {left 2 right 3}

  # The shortest word that is broken at all, whatever the patterns say. Not
  # derived from left plus right: with 2 and 2 that would let a four letter
  # word break, and a line ending in "Of-" reads as a mistake even where the
  # rules allow it.
  variable defaultMin 5

  # The libhyphen spellings of encodings that Tcl knows under another name.
  # Everything else is passed through lowercased and checked against
  # [encoding names], so an unreadable file is named at the load rather than
  # turning into replacement characters inside the patterns.
  variable encodingNames {microsoft-cp1251 cp1251 microsoft-cp1252 cp1252}

  # The characters a word may be broken at only where the pattern file has not
  # forbidden them (NOHYPHEN), plus the one this package writes itself.
  variable softHyphen "­"
}

# Read a pattern file for a language.
#
#   ::tclpdf::hyphenate load de-DE ./hyph_de_DE.dic -left 2 -right 2
#
# The tag is RFC 3066, the same spelling [$doc language] takes, and it is what
# a lookup later matches against - exactly first, then by primary subtag, so
# patterns loaded as "de" serve "de-AT" and patterns loaded as "de-DE" serve a
# document whose language is "de". Loading a tag again replaces it.
#
# -left and -right are the minimum number of letters that must stay on either
# side of a break; without them what the file says is used, and without that
# 2 and 3. -min is the shortest word broken at all (5). -exceptions takes a
# list of words written with "-" at the breaks - "Ur-in-stinkt" - which are
# looked up before the patterns and are taken exactly as given, minima and all.
#
# Returns the tag as given.
proc ::tclpdf::hyphenate::load {tag path args} {
  variable loaded
  variable defaultMinima
  variable defaultMin
  set options [::tclpdf::option parse \
      [dict create left {} right {} min $defaultMin exceptions {}] \
      $args "hyphenate load"]
  Tag $tag
  foreach name {left right min} {
    set value [dict get $options $name]
    if {$value eq {}} {
      continue
    }
    if {![string is integer -strict $value] || $value < 1} {
      return -code error "tclpdf: -$name takes a whole number of 1 or more,\
          not \"$value\""
    }
  }
  set data [Read $path]
  foreach name {left right} {
    if {[dict get $options $name] ne {}} {
      dict set data $name [dict get $options $name]
    } elseif {[dict get $data $name] eq {}} {
      dict set data $name [dict get $defaultMinima $name]
    }
  }
  dict set data min [dict get $options min]
  dict set data tag $tag
  dict set data exceptions [Exceptions [dict get $options exceptions]]
  dict set loaded [string tolower $tag] $data
  return $tag
}

# The languages that are loaded, in the spelling they were loaded under - or,
# with a tag, what is known about that one: the tag it resolved to, how many
# patterns and exceptions it holds, and the three minima in force.
#
# It doubles as the question "is this language loaded", because a tag that is
# not raises TCLPDF HYPHENATE LANGUAGE - which is how [text -hyphenate] refuses
# a language before it sets a single line of it.
proc ::tclpdf::hyphenate::languages {{tag {}}} {
  variable loaded
  if {$tag eq {}} {
    return [lmap data [dict values $loaded] {dict get $data tag}]
  }
  set data [Data $tag]
  return [dict create tag [dict get $data tag] \
      patterns [dict get $data patterns] \
      exceptions [dict size [dict get $data exceptions]] \
      left [dict get $data left] right [dict get $data right] \
      min [dict get $data min]]
}

# Where a word may be broken, as the list of pieces it falls into.
#
#   ::tclpdf::hyphenate word en-US hyphenation   ;# hy phen ation
#
# The pieces always concatenate back to the word handed in, character for
# character - punctuation, quotes and any soft hyphens included - so a caller
# may join them with a hyphen to show the breaks, or cut the original string at
# their lengths without counting anything twice. A word that must not be broken
# comes back as a one element list, which is the same answer as "no break was
# found" on purpose: neither is a failure.
proc ::tclpdf::hyphenate::word {tag string} {
  return [Pieces [Data $tag] $string]
}

# What is loaded for a tag: the exact spelling, then the primary subtag, then
# any loaded language sharing that primary subtag. "de-DE" therefore answers
# for a document set in "de", and a machine that loaded "de" answers for
# "de-AT" - which is right for hyphenation, where the patterns of a language
# differ far less between its regions than they do between languages.
proc ::tclpdf::hyphenate::Data {tag} {
  variable loaded
  set key [string tolower $tag]
  if {[dict exists $loaded $key]} {
    return [dict get $loaded $key]
  }
  set primary [lindex [split $key -] 0]
  if {[dict exists $loaded $primary]} {
    return [dict get $loaded $primary]
  }
  dict for {known data} $loaded {
    if {[lindex [split $known -] 0] eq $primary} {
      return $data
    }
  }
  # What IS loaded, in the refusal itself: the mistake is nearly always a
  # spelling or a load that never ran, and both are answered by the list.
  set known "nothing is loaded"
  if {[dict size $loaded]} {
    set known "loaded are: [join [languages] {, }]"
  }
  return -code error -errorcode [list TCLPDF HYPHENATE LANGUAGE $tag] \
      "tclpdf: no hyphenation patterns are loaded for \"$tag\" - load a\
      pattern file with \[::tclpdf::hyphenate load $tag <path>\]; $known"
}

proc ::tclpdf::hyphenate::Tag {tag} {
  # The same shape [$doc language] takes, so that what is loaded and what a
  # document declares can be compared at all.
  if {![regexp {^[A-Za-z]{1,8}(-[A-Za-z0-9]{1,8})*$} $tag]} {
    return -code error "tclpdf: \"$tag\" is not a language tag - expected\
        something like de, de-DE or en-GB (RFC 3066)"
  }
  return $tag
}

# The exception list as it is looked up: the word without its markers, in
# lower case, against the positions the markers stood at.
proc ::tclpdf::hyphenate::Exceptions {words} {
  set exceptions {}
  foreach entry $words {
    set breaks {}
    set at 0
    foreach piece [split $entry -] {
      incr at [string length $piece]
      lappend breaks $at
    }
    dict set exceptions [string tolower [string map {- {}} $entry]] \
        [lrange $breaks 0 end-1]
  }
  return $exceptions
}

# Read a libhyphen .dic file. Answers everything about the language that comes
# out of the FILE - the pattern table, the two minima where it states them, the
# forbidden characters, and how many patterns there were.
proc ::tclpdf::hyphenate::Read {path} {
  variable encodingNames
  set channel [open $path r]
  try {
    # Line one names the encoding of the rest, and it is ASCII whatever it
    # says, so it is read through a single byte encoding first. Named
    # explicitly rather than left to the system default: a UTF-8 system
    # reading an ISO8859-1 file turns every German pattern into an error or a
    # replacement character, and the patterns that survive are the ones
    # without an umlaut - which hyphenates most of the language correctly and
    # the rest silently wrong.
    fconfigure $channel -encoding iso8859-1 -translation auto
    set declared [string trim [gets $channel]]
    set encoding [string tolower $declared]
    if {[dict exists $encodingNames $encoding]} {
      set encoding [dict get $encodingNames $encoding]
    }
    if {$encoding ni [encoding names]} {
      return -code error "tclpdf: [file tail $path] says it is written in\
          \"$declared\", which this Tcl has no encoding for - a libhyphen\
          pattern file names its encoding on its first line"
    }
    fconfigure $channel -encoding $encoding
    set data [Parse $channel [tell $channel]]
  } finally {
    close $channel
  }
  if {![dict get $data patterns]} {
    return -code error "tclpdf: [file tail $path] holds no hyphenation\
        patterns - expected a libhyphen .dic file, whose first line is an\
        encoding name and whose remaining lines are patterns like \".a1be\""
  }
  return $data
}

# The body of a .dic file, read TWICE: once for the directives and to find out
# where the last table begins, once for the patterns of that table alone.
# "start" is where the body begins - the position after the encoding line - and
# is where the second pass starts when the file has no NEXTLEVEL in it.
#
# Twice rather than once with a list of the lines, and never building the
# compound tables at all: hyph_de_DE.dic holds 69 000 compound entries in front
# of NEXTLEVEL and 8 718 patterns after it. Building all of them and throwing
# the first table away three lines later was measured at 430 ms and 110 MB
# resident against 60 ms this way.
proc ::tclpdf::hyphenate::Parse {channel start} {
  set left {}
  set right {}
  set nohyphen {}
  set patternsFrom $start
  while {[gets $channel line] >= 0} {
    set line [string trim $line]
    # "%" is the TeX comment character and "#" the one the German file uses;
    # libhyphen accepts both, and so does this.
    if {$line eq {} || [string index $line 0] in {% #}} {
      continue
    }
    switch -glob -- $line {
      NEXTLEVEL {
        # Everything up to here was a compound table, driven by an algorithm
        # of libhyphen's own; the LAST table in the file is the plain Liang
        # one and the only one this module runs. See the note at the top.
        set patternsFrom [tell $channel]
      }
      {LEFTHYPHENMIN *} {
        set left [lindex $line 1]
      }
      {RIGHTHYPHENMIN *} {
        set right [lindex $line 1]
      }
      {NOHYPHEN *} {
        # A comma separated list of characters no break may touch. Read
        # wherever it stands: hyph_de_DE.dic states it in its compound table
        # and says nothing in the last one.
        append nohyphen [join [split [lindex $line 1] ,] {}]
      }
    }
  }
  seek $channel $patternsFrom
  set trie {}
  set patterns 0
  while {[gets $channel line] >= 0} {
    set line [string trim $line]
    if {$line eq {} || [string index $line 0] in {% #}} {
      continue
    }
    # A directive in capitals - NEXTLEVEL cannot occur here, but
    # COMPOUNDLEFTHYPHENMIN, HYPHEN or REPLACEMENT may - belongs to a part of
    # libhyphen this module does not implement. Skipped rather than refused:
    # a file is not broken for carrying a feature we do not use, and a
    # pattern is never written in capitals.
    if {[string match {[A-Z][A-Z]*} $line]} {
      continue
    }
    lassign [Pattern $line] letters values
    Insert trie $letters $values
    incr patterns
  }
  return [dict create trie $trie patterns $patterns left $left right $right \
      nohyphen $nohyphen]
}

# One pattern, split into its letters and the numbers between them: ".a1be"
# becomes ".abe" and {0 0 1 0 0}. The value list is one longer than the letters
# - a number may stand before the first letter and after the last - and value k
# applies at the position IN FRONT of letter k.
proc ::tclpdf::hyphenate::Pattern {line} {
  set letters {}
  set values {}
  set pending 0
  foreach character [split $line {}] {
    if {[string match {[0-9]} $character]} {
      set pending $character
      continue
    }
    lappend values $pending
    set pending 0
    append letters $character
  }
  lappend values $pending
  # Trailing zeros say nothing and are the majority of them: dropping them
  # here is what the matching loop below does not have to do per word.
  while {[llength $values] && [lindex $values end] == 0} {
    set values [lrange $values 0 end-1]
  }
  return [list $letters $values]
}

# The pattern table is a trie held as ONE dictionary keyed by the pattern text:
# every proper prefix of a pattern is an entry with an empty value, every whole
# pattern an entry with its numbers. That is what lets the matching loop stop
# extending a candidate the moment no pattern begins that way, which is the
# whole point of a trie - and it costs one flat dictionary rather than a
# dictionary per node.
proc ::tclpdf::hyphenate::Insert {trieName letters values} {
  upvar 1 $trieName trie
  set length [string length $letters]
  for {set index 1} {$index < $length} {incr index} {
    set prefix [string range $letters 0 $index-1]
    if {![dict exists $trie $prefix]} {
      dict set trie $prefix {}
    }
  }
  dict set trie $letters $values
}

# Liang's matching pass over one padded word. Answers one number per position,
# position p being the place in front of character p - so the list is one
# longer than the word.
proc ::tclpdf::hyphenate::Points {trie padded} {
  set length [string length $padded]
  set weights [lrepeat [expr {$length + 1}] 0]
  for {set start 0} {$start < $length} {incr start} {
    set key {}
    for {set end $start} {$end < $length} {incr end} {
      append key [string index $padded $end]
      if {![dict exists $trie $key]} {
        break
      }
      set offset $start
      foreach value [dict get $trie $key] {
        if {$value > [lindex $weights $offset]} {
          lset weights $offset $value
        }
        incr offset
      }
    }
  }
  return $weights
}

# The break positions inside ONE run of letters, counted in characters from its
# start: 3 means "between the third and the fourth letter".
proc ::tclpdf::hyphenate::Breaks {data piece} {
  set left [dict get $data left]
  set right [dict get $data right]
  set length [string length $piece]
  if {$length < [dict get $data min] || $length < $left + $right} {
    return {}
  }
  set lower [string tolower $piece]
  if {[string length $lower] != $length} {
    # A case fold that changes the length would put every position after it
    # one place out. Nothing in a Latin pattern file does this; a word from
    # elsewhere might, and a wrong break is worse than none.
    return {}
  }
  set exceptions [dict get $data exceptions]
  if {[dict exists $exceptions $lower]} {
    # Taken exactly as the caller wrote it, minima included: an exception
    # exists because the patterns were wrong about this word, and a minimum
    # applied on top would overrule the correction as well.
    set breaks [dict get $exceptions $lower]
  } else {
    set weights [Points [dict get $data trie] ".$lower."]
    set breaks {}
    for {set at $left} {$at <= $length - $right} {incr at} {
      # Weight 0 sits in front of the leading dot, so the place in front of
      # letter "at" carries weight at + 1. Odd means break.
      if {[lindex $weights $at+1] % 2} {
        lappend breaks $at
      }
    }
  }
  set forbidden [dict get $data nohyphen]
  if {$forbidden eq {}} {
    return $breaks
  }
  set kept {}
  foreach at $breaks {
    if {[string first [string index $piece $at-1] $forbidden] >= 0
        || [string first [string index $piece $at] $forbidden] >= 0} {
      continue
    }
    lappend kept $at
  }
  return $kept
}

# The word, cut at its break positions - the answer of [word], and the reason
# every guard in this file exists.
proc ::tclpdf::hyphenate::Pieces {data string} {
  variable softHyphen
  if {[string first $softHyphen $string] >= 0} {
    # The caller's own offers win outright; see the note at the top.
    return [list $string]
  }
  # The core is what stands between the outermost letters: brackets, quotes,
  # a comma or a full stop belong to the sentence, not to the word, and a
  # pattern file has no letter for them.
  set length [string length $string]
  set from 0
  while {$from < $length && ![string is alpha [string index $string $from]]} {
    incr from
  }
  set to [expr {$length - 1}]
  while {$to >= $from && ![string is alpha [string index $string $to]]} {
    incr to -1
  }
  if {$to < $from} {
    return [list $string]
  }
  set core [string range $string $from $to]
  # The digit is looked for in the WHOLE word, not in the core: a trailing one
  # would otherwise be stripped off as punctuation and "version2" would come
  # back "ver-sion2". A word with a number anywhere in it is a part number, a
  # size, a footnote marker or a year - not a word of the language.
  if {[regexp {[[:digit:]]} $string]
      || [regexp {[./:\\@]} $core]
      || ([string toupper $core] eq $core && [string tolower $core] ne $core)} {
    # A part number, a version, a URL, an address, a file name, an
    # abbreviation set in capitals. None of them is a word of the language,
    # and the patterns would break them where no reader expects it.
    return [list $string]
  }
  # A word that carries hyphens of its own is broken inside its parts, never
  # at the hyphen it already has: a line ending there would show two.
  set positions {}
  set offset 0
  foreach piece [split $core -] {
    foreach at [Breaks $data $piece] {
      lappend positions [expr {$offset + $at}]
    }
    incr offset [expr {[string length $piece] + 1}]
  }
  set pieces {}
  set at 0
  foreach position $positions {
    set cut [expr {$from + $position}]
    lappend pieces [string range $string $at $cut-1]
    set at $cut
  }
  lappend pieces [string range $string $at end]
  return $pieces
}

package provide tclpdf::hyphenate 1.0
