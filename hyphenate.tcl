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
# COMBINING MARKS. A word may reach this module precomposed or decomposed, and
# Unicode calls the two spellings equal; Liang's algorithm does not, because a
# pattern file is written with one character per accented letter. So the word
# is canonically COMPOSED before the patterns see it and the break positions
# are counted back to the caller's own characters, and what no composition can
# fold in is at least counted as what it is - part of the letter in front of
# it, never a letter of its own, and never a place to break. The table that
# does the composing, what is in it and what is deliberately not, stands at
# [compositionTable] below. TWO LIMITS ARE NAMED THERE AND BOTH ARE
# DELIBERATE: the table stops at the Latin, Greek and Cyrillic letters, and
# the canonical ORDER of two marks on one letter (UAX #15) is not restored -
# marks are read as they were written.
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

  # CANONICAL COMPOSITION, as much of it as hyphenation needs.
  #
  # A pattern file is written in precomposed letters - hyph_de_DE.dic is an
  # ISO8859-1 file and its patterns hold one character for each umlaut - while
  # the same word may reach this module decomposed, as a letter followed by a
  # combining mark. Unicode calls the two canonically equivalent and the
  # manual calls the decomposed spelling an equal input, but Liang's algorithm
  # does not: no pattern holding an umlaut matches a "u" plus U+0308, the
  # patterns that would have vetoed a break do not match either, and the word
  # comes out broken somewhere else. Measured over the 12 561 German words
  # with an umlaut in them, a third were broken differently and 218 ended up
  # with fewer than two letters in front of the break - "herueber" written
  # with the umlaut gave "her-ueber" precomposed and "he-rue-ber" decomposed,
  # which is wrong in German twice over.
  #
  # So a word is COMPOSED before the patterns see it, and the break positions
  # are counted back to the characters the caller handed in.
  #
  # WHAT IS IN THE TABLE: every canonical composition of a LETTER with a mark
  # of the Combining Diacritical Marks block (U+0300..U+036F) whose result is
  # a letter below U+1E00 - Latin-1 Supplement, Latin Extended-A and -B, IPA,
  # Greek and Cyrillic, 326 pairs, which is the alphabet of every language a
  # published .dic file exists for. Composition exclusions are already
  # applied: a pair stands here only where Unicode itself composes it.
  #
  # WHAT IS NOT, named rather than left to be discovered: Latin Extended
  # Additional (U+1E00..U+1EFF, the Vietnamese tone letters) and polytonic
  # Greek. A word written with those decomposed is still hyphenated, just not
  # identically to its precomposed spelling - and a mark that stays uncomposed
  # is at least counted as what it is, part of the letter in front of it
  # rather than a letter of its own.
  #
  # NOR IS THE CANONICAL ORDER of two marks on one letter (UAX #15): the
  # composition below reads one pair at a time and left to right, so a mark
  # standing in front of the one that would compose blocks it - which is what
  # NFC does too, except that NFC sorts the marks by combining class first and
  # this does not. That would need a combining class table, and no pattern
  # file in the world is written for a letter carrying two marks.
  #
  # {mark bases composed} triples, the two strings read one character against
  # one character. A mark occurs on several lines and the parts are joined,
  # which is what lets an alphabet of 87 letters stay inside the margin.
  variable compositionTable "
    \u0300 \u0041\u0045\u0049\u004E\u004F \u00C0\u00C8\u00CC\u01F8\u00D2
    \u0300 \u0055\u0061\u0065\u0069\u006E \u00D9\u00E0\u00E8\u00EC\u01F9
    \u0300 \u006F\u0075\u00DC\u00FC\u0415 \u00F2\u00F9\u01DB\u01DC\u0400
    \u0300 \u0418\u0435\u0438 \u040D\u0450\u045D
    \u0301 \u0041\u0043\u0045\u0047\u0049 \u00C1\u0106\u00C9\u01F4\u00CD
    \u0301 \u004C\u004E\u004F\u0052\u0053 \u0139\u0143\u00D3\u0154\u015A
    \u0301 \u0055\u0059\u005A\u0061\u0063 \u00DA\u00DD\u0179\u00E1\u0107
    \u0301 \u0065\u0067\u0069\u006C\u006E \u00E9\u01F5\u00ED\u013A\u0144
    \u0301 \u006F\u0072\u0073\u0075\u0079 \u00F3\u0155\u015B\u00FA\u00FD
    \u0301 \u007A\u00C5\u00C6\u00D8\u00DC \u017A\u01FA\u01FC\u01FE\u01D7
    \u0301 \u00E5\u00E6\u00F8\u00FC\u0391 \u01FB\u01FD\u01FF\u01D8\u0386
    \u0301 \u0395\u0397\u0399\u039F\u03A5 \u0388\u0389\u038A\u038C\u038E
    \u0301 \u03A9\u03B1\u03B5\u03B7\u03B9 \u038F\u03AC\u03AD\u03AE\u03AF
    \u0301 \u03BF\u03C5\u03C9\u03CA\u03CB \u03CC\u03CD\u03CE\u0390\u03B0
    \u0301 \u03D2\u0413\u041A\u0433\u043A \u03D3\u0403\u040C\u0453\u045C
    \u0302 \u0041\u0043\u0045\u0047\u0048 \u00C2\u0108\u00CA\u011C\u0124
    \u0302 \u0049\u004A\u004F\u0053\u0055 \u00CE\u0134\u00D4\u015C\u00DB
    \u0302 \u0057\u0059\u0061\u0063\u0065 \u0174\u0176\u00E2\u0109\u00EA
    \u0302 \u0067\u0068\u0069\u006A\u006F \u011D\u0125\u00EE\u0135\u00F4
    \u0302 \u0073\u0075\u0077\u0079 \u015D\u00FB\u0175\u0177
    \u0303 \u0041\u0049\u004E\u004F\u0055 \u00C3\u0128\u00D1\u00D5\u0168
    \u0303 \u0061\u0069\u006E\u006F\u0075 \u00E3\u0129\u00F1\u00F5\u0169
    \u0304 \u0041\u0045\u0049\u004F\u0055 \u0100\u0112\u012A\u014C\u016A
    \u0304 \u0059\u0061\u0065\u0069\u006F \u0232\u0101\u0113\u012B\u014D
    \u0304 \u0075\u0079\u00C4\u00C6\u00D5 \u016B\u0233\u01DE\u01E2\u022C
    \u0304 \u00D6\u00DC\u00E4\u00E6\u00F5 \u022A\u01D5\u01DF\u01E3\u022D
    \u0304 \u00F6\u00FC\u01EA\u01EB\u0226 \u022B\u01D6\u01EC\u01ED\u01E0
    \u0304 \u0227\u022E\u022F\u0418\u0423 \u01E1\u0230\u0231\u04E2\u04EE
    \u0304 \u0438\u0443 \u04E3\u04EF
    \u0306 \u0041\u0045\u0047\u0049\u004F \u0102\u0114\u011E\u012C\u014E
    \u0306 \u0055\u0061\u0065\u0067\u0069 \u016C\u0103\u0115\u011F\u012D
    \u0306 \u006F\u0075\u0410\u0415\u0416 \u014F\u016D\u04D0\u04D6\u04C1
    \u0306 \u0418\u0423\u0430\u0435\u0436 \u0419\u040E\u04D1\u04D7\u04C2
    \u0306 \u0438\u0443 \u0439\u045E
    \u0307 \u0041\u0043\u0045\u0047\u0049 \u0226\u010A\u0116\u0120\u0130
    \u0307 \u004F\u005A\u0061\u0063\u0065 \u022E\u017B\u0227\u010B\u0117
    \u0307 \u0067\u006F\u007A \u0121\u022F\u017C
    \u0308 \u0041\u0045\u0049\u004F\u0055 \u00C4\u00CB\u00CF\u00D6\u00DC
    \u0308 \u0059\u0061\u0065\u0069\u006F \u0178\u00E4\u00EB\u00EF\u00F6
    \u0308 \u0075\u0079\u0399\u03A5\u03B9 \u00FC\u00FF\u03AA\u03AB\u03CA
    \u0308 \u03C5\u03D2\u0406\u0410\u0415 \u03CB\u03D4\u0407\u04D2\u0401
    \u0308 \u0416\u0417\u0418\u041E\u0423 \u04DC\u04DE\u04E4\u04E6\u04F0
    \u0308 \u0427\u042B\u042D\u0430\u0435 \u04F4\u04F8\u04EC\u04D3\u0451
    \u0308 \u0436\u0437\u0438\u043E\u0443 \u04DD\u04DF\u04E5\u04E7\u04F1
    \u0308 \u0447\u044B\u044D\u0456\u04D8 \u04F5\u04F9\u04ED\u0457\u04DA
    \u0308 \u04D9\u04E8\u04E9 \u04DB\u04EA\u04EB
    \u030A \u0041\u0055\u0061\u0075 \u00C5\u016E\u00E5\u016F
    \u030B \u004F\u0055\u006F\u0075\u0423 \u0150\u0170\u0151\u0171\u04F2
    \u030B \u0443 \u04F3
    \u030C \u0041\u0043\u0044\u0045\u0047 \u01CD\u010C\u010E\u011A\u01E6
    \u030C \u0048\u0049\u004B\u004C\u004E \u021E\u01CF\u01E8\u013D\u0147
    \u030C \u004F\u0052\u0053\u0054\u0055 \u01D1\u0158\u0160\u0164\u01D3
    \u030C \u005A\u0061\u0063\u0064\u0065 \u017D\u01CE\u010D\u010F\u011B
    \u030C \u0067\u0068\u0069\u006A\u006B \u01E7\u021F\u01D0\u01F0\u01E9
    \u030C \u006C\u006E\u006F\u0072\u0073 \u013E\u0148\u01D2\u0159\u0161
    \u030C \u0074\u0075\u007A\u00DC\u00FC \u0165\u01D4\u017E\u01D9\u01DA
    \u030C \u01B7\u0292 \u01EE\u01EF
    \u030F \u0041\u0045\u0049\u004F\u0052 \u0200\u0204\u0208\u020C\u0210
    \u030F \u0055\u0061\u0065\u0069\u006F \u0214\u0201\u0205\u0209\u020D
    \u030F \u0072\u0075\u0474\u0475 \u0211\u0215\u0476\u0477
    \u0311 \u0041\u0045\u0049\u004F\u0052 \u0202\u0206\u020A\u020E\u0212
    \u0311 \u0055\u0061\u0065\u0069\u006F \u0216\u0203\u0207\u020B\u020F
    \u0311 \u0072\u0075 \u0213\u0217
    \u031B \u004F\u0055\u006F\u0075 \u01A0\u01AF\u01A1\u01B0
    \u0326 \u0053\u0054\u0073\u0074 \u0218\u021A\u0219\u021B
    \u0327 \u0043\u0045\u0047\u004B\u004C \u00C7\u0228\u0122\u0136\u013B
    \u0327 \u004E\u0052\u0053\u0054\u0063 \u0145\u0156\u015E\u0162\u00E7
    \u0327 \u0065\u0067\u006B\u006C\u006E \u0229\u0123\u0137\u013C\u0146
    \u0327 \u0072\u0073\u0074 \u0157\u015F\u0163
    \u0328 \u0041\u0045\u0049\u004F\u0055 \u0104\u0118\u012E\u01EA\u0172
    \u0328 \u0061\u0065\u0069\u006F\u0075 \u0105\u0119\u012F\u01EB\u0173
  "
  variable compositions {}
  foreach {mark bases composed} $compositionTable {
    if {[dict exists $compositions $mark]} {
      lassign [dict get $compositions $mark] before made
      set bases $before$bases
      set composed $made$composed
    }
    dict set compositions $mark [list $bases $composed]
  }
  unset -nocomplain compositionTable mark bases composed before made
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
    set composed {}
    foreach piece [split $entry -] {
      # COMPOSED, because that is the spelling a word is looked up in and the
      # offsets are counted in: [Breaks] composes the word before it asks
      # anything of it, so an exception written decomposed would never be
      # found and one written precomposed would be found with offsets that no
      # longer fit. Composed piece by piece rather than as a whole, so that a
      # marker cannot fall between a letter and its mark.
      set text [lindex [Compose $piece] 0]
      append composed $text
      incr at [string length $text]
      lappend breaks $at
    }
    dict set exceptions [string tolower $composed] [lrange $breaks 0 end-1]
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
  # WHAT THE FILE SAYS IS CHECKED LIKE WHAT THE CALLER SAYS, and it was not:
  # -left and -right are refused above unless they are a whole number of 1 or
  # more, while LEFTHYPHENMIN and RIGHTHYPHENMIN were taken from the file as
  # they stood. The file is the less trustworthy of the two - it comes from
  # another machine, another project and another decade - and a 0 there was
  # not harmless: [Breaks] then offered a break in front of the first letter,
  # [word] answered with an EMPTY first piece, and a paragraph set with
  # "-hyphenate" hung for ever, because the line breaker took an offer that
  # consumed nothing of the word and went round again (textBlock.tcl, which
  # now refuses such an offer as well - two brakes, because either alone
  # would have held and neither was there). A negative value or a word
  # reached expr as an operand and came out as a raw Tcl error.
  #
  # Refused rather than corrected: a file that states a nonsense minimum is
  # not a file whose patterns can be trusted either, and silently reading 0 as
  # 2 would hide which of the two the caller is looking at.
  foreach {name directive} {left LEFTHYPHENMIN right RIGHTHYPHENMIN} {
    set value [dict get $data $name]
    if {$value ne {} && (![string is integer -strict $value] || $value < 1)} {
      return -code error "tclpdf: [file tail $path] says $directive\
          \"$value\", and that is the number of letters that must stay on one\
          side of a break - a whole number of 1 or more"
    }
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

# Is this character a combining MARK - Unicode general category Mn, Mc or Me,
# a character that is not a letter of its own but part of the one in front of
# it?
#
# Asked of TCL'S OWN Unicode tables rather than of a range list kept here, and
# by exclusion because Tcl offers no positive test: measured over every
# assigned code point of the BMP under 8.6.18 and 9.0.4, a mark answers
# "graph" and "print" and nothing else - not alpha, not alnum, not punct, not
# space, not control - and all 1 339 marks of the plane answer so, in both
# interpreters and with no exception either way.
#
# The characters that answer the same way and are NOT marks are the SYMBOLS,
# and the cut at U+0300 keeps the ones a word could plausibly hold out of it:
# no combining mark exists below U+0300, so the dollar, the plus, the caret,
# the backtick and every Latin-1 sign are letters here as they always were.
# What is left over - a symbol at U+0384 or above standing BETWEEN two letters
# of one word - would be taken for a mark; no word of any language with a
# pattern file is written that way, and the price of being wrong there is one
# break not offered.
proc ::tclpdf::hyphenate::Mark {character} {
  return [expr {[scan $character %c] >= 0x0300
      && [string is graph -strict $character]
      && ![string is alnum -strict $character]
      && ![string is punct -strict $character]}]
}

# A string in its composed spelling, with the way back: {text origins}, where
# origins holds one index per composed character - the place in the ORIGINAL
# string that character begins at.
#
# The composition itself is one pair at a time and left to right: a mark is
# folded into the character immediately in front of it when the table has that
# pair, and the result is offered to the next mark, so "a" + U+0308 + U+0301
# reaches its second mark as one character. That is canonical composition
# minus the canonical ORDERING, and the head of this file says why the
# ordering is not done and what it costs.
#
# The fast path is the point of the regexp: a word without a single character
# of the Combining Diacritical Marks block - which is every word of every
# precomposed text this package has ever been handed - is its own composition,
# and it is handed back with EMPTY origins, the shape that says "character k
# came from character k" and costs nothing to produce. The slow path is walked
# by the words that need it and by no others.
proc ::tclpdf::hyphenate::Compose {text} {
  variable compositions
  if {![regexp {[\u0300-\u036F]} $text]} {
    # EMPTY ORIGINS mean "character k came from character k" - the answer for
    # every text that carries no mark, which is nearly every text there is,
    # and the one shape that costs nothing to produce. [Breaks] reads it.
    return [list $text {}]
  }
  set composed {}
  set origins {}
  set index 0
  foreach character [split $text {}] {
    if {[string length $composed] && [dict exists $compositions $character]} {
      lassign [dict get $compositions $character] bases made
      set at [string first [string index $composed end] $bases]
      if {$at >= 0} {
        # The base keeps the origin it was given: the pair is one character
        # now, and it began where the base did.
        set composed [string replace $composed end end [string index $made $at]]
        incr index
        continue
      }
    }
    append composed $character
    lappend origins $index
    incr index
  }
  return [list $composed $origins]
}

# The break positions inside ONE run of letters, counted in characters from its
# start: 3 means "between the third and the fourth letter".
proc ::tclpdf::hyphenate::Breaks {data piece} {
  set left [dict get $data left]
  set right [dict get $data right]
  # THE WORD AS THE PATTERNS ARE WRITTEN, and the way back to the word as the
  # caller wrote it. Everything below counts in the COMPOSED spelling -
  # positions, minima, the forbidden characters - and the answer is counted
  # back through [Compose]'s origins at the very end, so a caller who wrote
  # the word decomposed gets its own character positions returned.
  lassign [Compose $piece] text origins
  # WHERE EACH LETTER BEGINS. A combining mark that no composition could fold
  # into its base is part of the letter in front of it and not a letter of
  # its own - which is what the minima have always been about ("a run of
  # fewer letters", and the manual says letters). Counted in characters, the
  # left minimum of 2 let "he" plus a mark stand as two letters where a
  # reader sees one and a half, and a break could fall BETWEEN a letter and
  # its mark, which is not a place at all.
  #
  # THE FAST PATH is one regexp against the whole word, and it is what keeps
  # a German pattern run at the speed it had: no combining mark exists below
  # U+0300, so a word written entirely in the lower blocks - Latin, and
  # everything a .dic in ISO8859-1 can hold - is all letters, letter k begins
  # at character k, and neither list has to be built at all. Measured over
  # 20 000 German words, building them cost a third of the running time.
  set length [string length $text]
  set plain [expr {![regexp {[^\u0020-\u02FF]} $text]}]
  set letters {}
  if {$plain} {
    set count $length
  } else {
    set index 0
    foreach character [split $text {}] {
      # The first character always opens a letter: a mark at the head of a
      # word hangs on nothing and there is no piece before it to join.
      if {![llength $letters] || ![Mark $character]} {
        lappend letters $index
      }
      incr index
    }
    set count [llength $letters]
  }
  if {$count < [dict get $data min] || $count < $left + $right} {
    return {}
  }
  set lower [string tolower $text]
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
    # OVER THE LETTERS, not over the characters: "at" counts letters for the
    # minima and names the character the letter begins at for the weights.
    # The two are the same list wherever a word carries no mark, which is why
    # every word that has none comes out exactly as it always did.
    for {set at $left} {$at <= $count - $right} {incr at} {
      set position [expr {$plain ? $at : [lindex $letters $at]}]
      # Weight 0 sits in front of the leading dot, so the place in front of
      # character "position" carries weight position + 1. Odd means break.
      if {[lindex $weights $position+1] % 2} {
        lappend breaks $position
      }
    }
  }
  set forbidden [dict get $data nohyphen]
  set kept $breaks
  if {$forbidden ne {}} {
    set kept {}
    foreach at $breaks {
      if {[string first [string index $text $at-1] $forbidden] >= 0
          || [string first [string index $text $at] $forbidden] >= 0} {
        continue
      }
      lappend kept $at
    }
  }
  if {$origins eq {}} {
    # Nothing was composed, so the composed positions ARE the caller's.
    return $kept
  }
  return [lmap at $kept {lindex $origins $at}]
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
  # A MARK IS NOT PUNCTUATION, and the walk backwards above cannot tell the
  # two apart - it asks [string is alpha], and a combining mark is not alpha.
  # So the marks of the LAST letter are taken back into the core: without
  # this, "cafe" plus U+0301 was hyphenated as "cafe" and the accent counted
  # as a full stop at the end of the sentence, which is a different word and a
  # different set of patterns. The leading edge needs no such walk: a mark in
  # front of the first letter hangs on nothing.
  while {$to + 1 < $length && [Mark [string index $string $to+1]]} {
    incr to
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

package provide tclpdf::hyphenate 1.1
