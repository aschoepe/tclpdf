#
# tclpdf - PDF generation for Tcl
#
# xml - an element tree, from tdom where it exists and from here where it does
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Two parsers behind five accessors. tdom is used when it is installed,
# because it is measurably better at this; the parser below runs when it is
# not, because the package rule is that tclpdf works on a plain Tcl
# installation - the same rule that keeps C out of the critical path.
#
# Measured on this machine, 300 real SVG files (397 KB):
#
#   correctness   300 of 300 both ways - no file one can read and the other
#                 cannot, in either direction
#   speed         tdom 3 ms against 82 ms, so 27x over the set and 32-48x on
#                 a single drawing
#   XXE           neither reads a foreign file: tdom resolves external
#                 entities only when -externalentitycommand is given, and it
#                 is not given here. -paramentityparsing never says so in the
#                 code instead of relying on a missing ingredient
#   entity bomb   MEASURED AND WRONG until 2026-08-27, when this line said
#                 "tdom refuses one that amplifies beyond 100x, its own
#                 default". It does not: a 424-byte document with six levels
#                 of nested entities came back after 13 ms with a text node
#                 of a million characters, an amplification of 2360. The
#                 limit is drawn HERE now, before the document is handed to
#                 either parser - see [Amplification]. The parser below
#                 expands declared entities as tdom does since 2026-11-24,
#                 and the same check is what bounds it
#
# The accessors exist so that svg.tcl works against BOTH without knowing
# which: a tdom node is an object, a node from here is a dictionary, and
# converting one into the other would eat two thirds of the speed the swap
# was made for.
#
#   ::tclpdf::xml parse $text     -> a handle, whatever kind
#   ::tclpdf::xml name $node
#   ::tclpdf::xml attribute $node $name ?$default?
#   ::tclpdf::xml children $node
#   ::tclpdf::xml parent $node
#   ::tclpdf::xml text $node
#   ::tclpdf::xml release $handle  -> a tdom document is NOT freed by itself
#
# What the parser below handles is what SVG files contain: elements,
# attributes, nesting, comments, CDATA, processing instructions, the five
# predefined entities plus numeric references, and the general entities of
# the internal subset, expanded where they are referenced as tdom expands
# them - in text and in attribute values, an entity inside an entity, and an
# element written in one (see [Unescape] and [Splice]). What it does not: the
# rest of a document type definition - attribute defaults, parameter
# entities, the external subset -, or namespaces as anything other than part
# of the name. What tdom refuses it refuses too, under one code for both, see
# [Refused]: a reference to an entity the document never declares, an "&"
# that begins no reference, a character reference to no XML character, an
# external entity in an attribute value, and anything but white space,
# comments and processing instructions after the root element.
#

package require Tcl 8.6.11-

namespace eval ::tclpdf::xml {
  namespace export {[a-z]*}
  namespace ensemble create

  # Asked once. A failed [package require] is not an error here - it decides
  # which of the two parsers runs, and both produce the same answers.
  variable haveTdom [expr {![catch {package require tdom 0.9.0-}]}]

  # How far the entities of a document may amplify it, as a multiple of the
  # markup's own length, and the floor below which no document is refused at
  # all. Availability, not security: the standard sets no limit, and neither
  # does tdom - a few nested entities turn a kilobyte into a gigabyte and the
  # process never comes back.
  variable amplificationLimit 100
  variable amplificationFloor 65536

  # How many entities deep one may refer to the next. Both [Expanded] and the
  # expansion in [Unescape] follow a chain one Tcl frame per entity, and Tcl
  # stops at a thousand frames: measured 2026-11-24, a chain of 994 failed
  # with "too many nested evaluations" for both parsers - not a TCLPDF code -
  # and one of 992 parsed with tdom and failed without it, the built-in
  # parser starting two frames deeper. Drawn far below, where no real file
  # goes; the nesting of the classic bomb is ten.
  variable entityDepth 100
}

# Which parser is in use - for a caller who wants to know, and for the tests
# that have to exercise both.
proc ::tclpdf::xml::parser {} {
  variable haveTdom
  return [expr {$haveTdom ? "tdom" : "tclpdf"}]
}

# Parse a document. The result is a handle to be passed to the accessors and
# to [release] - not a data structure to look inside.
proc ::tclpdf::xml::parse {text} {
  variable haveTdom

  Amplification $text
  if {$haveTdom} {
    # -paramentityparsing never, spelled out. The default is "always": tdom
    # then TRIES to resolve external entities and the external subset, and
    # only fails to because no -externalentitycommand is given. Security by a
    # missing ingredient is not security - this says it.
    if {[catch {dom parse -paramentityparsing never $text} document]} {
      Refused $text $document
    }
    set root [$document documentElement]
    if {$root eq {}} {
      $document delete
      return -code error -errorcode [list TCLPDF XML EMPTY none] \
          "tclpdf: no XML element found"
    }
    return [list tdom $document $root]
  }
  return [list tclpdf {} [Parse $text]]
}

# tdom's refusal in this package's words, under the code the parser below
# gives the same document.
#
# tdom answers a document that is not well formed with expat's message - 'error
# "undefined entity" at line 1 character 3' - and an -errorcode of NONE,
# measured 2026-11-24 with tdom 0.9.7, against the promise that every refusal
# begins with "tclpdf:" and carries a TCLPDF code. The message is kept, since
# expat names the line and the character; the CODE is asked of the parser
# below, by parsing the same document with it. Mapping expat's messages to
# classes instead would be a second, smaller parser that had to be kept in
# step with the first: "no element found" is an unclosed element or no element
# at all, and "not well-formed (invalid token)" is a bare "&" or a dozen other
# things. Asked this way, a script that traps the code cannot tell which
# parser ran, and the price - the slower parse - is paid only for a document
# that is refused anyway. What tdom refuses and the parser below accepts is
# "MALFORMED syntax".
proc ::tclpdf::xml::Refused {text message} {
  if {[catch {Parse $text} verdict options]
      && [lrange [dict get $options -errorcode] 0 1] eq {TCLPDF XML}} {
    return -code error -errorcode [dict get $options -errorcode] \
        "tclpdf: XML is not well formed - $message"
  }
  return -code error -errorcode [list TCLPDF XML MALFORMED syntax] \
      "tclpdf: XML is not well formed - $message"
}

# What the internal subset's entities would expand to, refused where it is
# out of proportion to the document that carries them.
#
# The classic bomb is six lines: ten a's, then ten of those, ten of THOSE, and
# a document that is 400 bytes long and a gigabyte once expanded. No parser on
# this machine draws a line - measured 2026-08-27, tdom answered a 424-byte
# file with a million characters in 13 ms - and the standard has nothing to
# say about it either, so the limit is this package's own, like the ones on
# Flate and on <use>.
#
# The lengths are worked out SYMBOLICALLY, before anything is expanded: each
# entity's length is its literal text with every entity reference in it
# replaced by that entity's own length. A definition that refers to itself,
# directly or round a corner, is a cycle and is refused as one - no depth of
# recursion is enough for it.
#
# The literal text is the REPLACEMENT text, with its character references
# resolved as they are at the declaration ([Replacement]): "&#38;e;" is a
# reference to e once declared. Until 2026-11-24 this check read the literal
# as written and saw no reference in it, so a bomb spelled that way passed -
# tdom's expat then stopped it at its own limit, past eight megabytes, and
# answered with nothing a caller could trap.
proc ::tclpdf::xml::Amplification {text} {
  variable amplificationLimit
  variable amplificationFloor
  set definitions [dict get [Entities $text] internal]
  if {![dict size $definitions]} {
    return
  }
  set budget [expr {max($amplificationFloor,
      $amplificationLimit * [string length $text])}]
  set lengths [dict create]
  foreach name [dict keys $definitions] {
    Expanded $name $definitions lengths [dict create] $budget
  }
  # And the references in the document itself, each one costing its entity's
  # expanded length.
  set total 0
  foreach {-> reference} [regexp -all -inline {&([^;&\s]+);} $text] {
    if {[dict exists $lengths $reference]} {
      incr total [dict get $lengths $reference]
    }
  }
  if {$total > $budget} {
    return -code error -errorcode [list TCLPDF XML ENTITY expansion] \
        "tclpdf: the entities of this document expand it to more than\
        $total characters out of [string length $text] - past the\
        ${amplificationLimit}-fold this package allows, and a document\
        that amplifies without a limit does not finish parsing"
  }
  return
}

# What the document type declaration says about entities, as a dictionary:
#
#   internal  the general entities of the internal subset, name ->
#             replacement text ([Replacement])
#   external  the names declared as external entities, SYSTEM or PUBLIC
#   unparsed  those of them that are unparsed, NDATA
#   open      1 where a reference to an entity declared nowhere is still
#             well formed
#
# OPEN is XML 1.0, 4.1, WFC "Entity Declared": a reference must match a
# declaration only in a document without an external subset and without a
# parameter entity reference in its internal subset - either may declare the
# entity where no parser here looks - or in one that says standalone="yes".
# Measured 2026-11-24 with tdom 0.9.7: "&e;" with no declaration is refused
# under "<!DOCTYPE a>" and under "<!DOCTYPE a [<!ENTITY f 'y'>]>", accepted
# under a PUBLIC or SYSTEM identifier and under a "%p;" in the subset, and
# refused again with standalone="yes" in front of the same SYSTEM identifier.
# Read by [Amplification] for the lengths and by [Parse] for the references;
# one reading of the declaration for both, so that the two cannot disagree
# about which entities a document has.
proc ::tclpdf::xml::Entities {text} {
  set result [dict create internal [dict create] external {} unparsed {} \
      open 0]
  if {![regexp -indices {<!DOCTYPE([^>\[]*)(\[?)} $text -> identifier bracket]} {
    return $result
  }
  set subset {}
  if {[lindex $bracket 1] >= [lindex $bracket 0]} {
    set subset [string range $text [lindex $bracket 1]+1 end]
    set close [string first \] $subset]
    if {$close >= 0} {
      set subset [string range $subset 0 $close-1]
    }
  }
  set standalone [regexp \
      {^﻿?<\?xml\s[^?]*\sstandalone\s*=\s*["']yes["']} $text]
  # A parameter entity reference that nothing reads may declare anything, so
  # XML 1.0, 4.1 has a processor that does not read it ignore the entity
  # declarations after it, unless the document is standalone. Measured
  # 2026-11-24: tdom expands nothing declared after a "%p;", and does under
  # standalone="yes".
  set declarations $subset
  if {!$standalone && [regexp -indices {%[^\s%;]+;} $subset reference]} {
    set declarations [string range $subset 0 [lindex $reference 0]-1]
  }
  # One pass, in the order the declarations are written: where a name is
  # declared twice, the FIRST declaration is binding, internal or external
  # (XML 1.0, 4.2). Measured 2026-11-24: tdom expands <!ENTITY n "t1"><!ENTITY
  # n "t2"> to t1, and the dictionary here used to keep t2.
  foreach {-> name double single external identifiers} [regexp -all -inline \
      {<!ENTITY\s+([^\s%>]+)\s+(?:"([^"]*)"\s*>|'([^']*)'\s*>|(SYSTEM|PUBLIC)\s((?:[^>"']|"[^"]*"|'[^']*')*)>)} \
      $declarations] {
    if {[dict exists $result internal $name]
        || $name in [dict get $result external]} {
      continue
    }
    # Not a ternary in expr: it would hand back a value such as 010 as 8.
    if {$external ne {}} {
      dict lappend result external $name
      regsub -all {"[^"]*"|'[^']*'} $identifiers {} keywords
      if {[regexp {\sNDATA\s} " $keywords "]} {
        dict lappend result unparsed $name
      }
    } elseif {$double ne {}} {
      dict set result internal $name [Replacement $double]
    } else {
      dict set result internal $name [Replacement $single]
    }
  }
  if {([regexp {^\s+\S+\s+(?:SYSTEM|PUBLIC)\s} \
          [string range $text {*}$identifier]]
        || [regexp {%[^\s%;]+;} $subset])
      && !$standalone} {
    dict set result open 1
  }
  return $result
}

# The replacement text of an internal entity: its literal with the character
# references resolved, which XML 1.0, 4.5 does when the entity is DECLARED.
# "&#38;amp;" is declared as "&amp;" and reads as "&" where it is referenced,
# "&#38;e;" refers to the entity e, "&#60;g/>" is an element; an entity
# reference in the literal stays as written and is expanded where the entity
# is used. A character reference to no XML character is refused here, used or
# not - measured 2026-11-24, tdom refuses <!ENTITY n "&#0;"> before it reads
# the first element.
proc ::tclpdf::xml::Replacement {literal} {
  if {[string first &# $literal] < 0} {
    return $literal
  }
  set result {}
  set from 0
  foreach {all hex decimal} [regexp -all -inline -indices \
      {&#(?:x([0-9A-Fa-f]+)|([0-9]+));} $literal] {
    lassign $all start end
    append result [string range $literal $from [expr {$start - 1}]]
    set from [expr {$end + 1}]
    if {[lindex $hex 0] >= 0} {
      append result [Character [string range $literal {*}$hex] x \
          $literal $start {an entity declaration}]
    } else {
      append result [Character [string range $literal {*}$decimal] d \
          $literal $start {an entity declaration}]
    }
  }
  append result [string range $literal $from end]
  return $result
}

# The character a numeric reference names - DIGITS read as hexadecimal (x) or
# decimal (d) - refused where XML 1.0, 2.2 has no such character: U+0000 and
# the controls but tab, line feed and carriage return, the surrogates U+D800
# to U+DFFF, U+FFFE and U+FFFF, and anything past U+10FFFF. Measured
# 2026-11-24: tdom refuses each as "reference to invalid character number";
# the parser here wrote U+0000 into the text and answered &#99999999999; with
# Tcl's own "integer value too large to represent".
#
# The digits go through scan, never through expr: a leading zero is decimal
# under 8.6 as well. More digits than U+10FFFF has are out of range however
# they are read, and are not handed to scan at all.
proc ::tclpdf::xml::Character {digits base text start where} {
  set digits [string trimleft $digits 0]
  if {$base eq "x"} {
    set most 6
  } else {
    set most 7
  }
  set code -1
  if {$digits eq {}} {
    set code 0
  } elseif {[string length $digits] <= $most} {
    scan $digits %$base code
  }
  if {$code in {9 10 13}
      || ($code >= 0x20 && $code <= 0xD7FF)
      || ($code >= 0xE000 && $code <= 0xFFFD)
      || ($code >= 0x10000 && $code <= 0x10FFFF)} {
    return [format %c $code]
  }
  return -code error -errorcode [list TCLPDF XML MALFORMED character] \
      "tclpdf: XML is not well formed - the reference in $where\
      \"[Excerpt $text $start]\" names no character XML allows"
}

# The entities whose replacement text holds markup, directly or through an
# entity it refers to, round as many corners as there are - [Splice] puts
# their references in the text into the document itself.
proc ::tclpdf::xml::Markup {entities} {
  set internal [dict get $entities internal]
  set result {}
  dict for {name replacement} $internal {
    if {[string first < $replacement] >= 0} {
      lappend result $name
    }
  }
  set grown [llength $result]
  while {$grown} {
    set grown 0
    dict for {name replacement} $internal {
      if {$name in $result} {
        continue
      }
      foreach {-> reference} [regexp -all -inline \
          {&([^\s&;<>"']+);} $replacement] {
        if {$reference in $result} {
          lappend result $name
          set grown 1
          break
        }
      }
    }
  }
  return $result
}

# One entity's expanded length, memoised, with the entities open on the way
# down as the cycle guard.
proc ::tclpdf::xml::Expanded {name definitions lengthsVariable open budget} {
  variable entityDepth
  upvar 1 $lengthsVariable lengths
  if {[dict exists $lengths $name]} {
    return [dict get $lengths $name]
  }
  if {[dict exists $open $name]} {
    return -code error -errorcode [list TCLPDF XML ENTITY cycle] \
        "tclpdf: the entity \"&$name;\" is defined in terms of itself -\
        an entity that refers back to its own definition has no expansion"
  }
  if {![dict exists $definitions $name]} {
    return 0
  }
  if {[dict size $open] >= $entityDepth} {
    return -code error -errorcode [list TCLPDF XML ENTITY depth] \
        "tclpdf: the entity \"&$name;\" is reached through more than\
        $entityDepth entities, each referring to the next - deeper than\
        this package follows"
  }
  dict set open $name 1
  set literal [dict get $definitions $name]
  set length [string length $literal]
  foreach {-> reference} [regexp -all -inline {&([^;&\s]+);} $literal] {
    if {![dict exists $definitions $reference]} {
      continue
    }
    set inner [Expanded $reference $definitions lengths $open $budget]
    # The reference itself is gone and its expansion takes its place.
    set length [expr {$length - [string length $reference] - 2 + $inner}]
    if {$length > $budget} {
      # Far enough: the answer is already past the limit, and going on would
      # be the arithmetic the limit exists to prevent.
      break
    }
  }
  dict set lengths $name $length
  return $length
}

# A tdom document holds memory that nothing frees on its own. Every [parse]
# needs a matching [release], and it belongs in a finally clause - an error
# while drawing must not leak the tree.
proc ::tclpdf::xml::release {handle} {
  lassign $handle kind document ->
  if {$kind eq "tdom" && $document ne {}} {
    $document delete
  }
  return
}

# -- the four accessors ----------------------------------------------------

proc ::tclpdf::xml::root {handle} {
  return $handle
}

proc ::tclpdf::xml::name {node} {
  lassign $node kind document element
  if {$kind eq "tdom"} {
    return [$element nodeName]
  }
  return [dict get $element name]
}

proc ::tclpdf::xml::attribute {node attributeName {default {}}} {
  lassign $node kind document element
  if {$kind eq "tdom"} {
    if {[$element hasAttribute $attributeName]} {
      return [$element getAttribute $attributeName]
    }
    return $default
  }
  if {[dict exists [dict get $element attributes] $attributeName]} {
    return [dict get [dict get $element attributes] $attributeName]
  }
  return $default
}

proc ::tclpdf::xml::children {node} {
  lassign $node kind context element
  set result {}
  if {$kind eq "tdom"} {
    foreach child [$element childNodes] {
      if {[$child nodeType] eq "ELEMENT_NODE"} {
        lappend result [list tdom $context $child]
      }
    }
    return $result
  }
  # This is where the ancestor chain grows: the handle of a child carries
  # everything that encloses it, so that [parent] has something to answer
  # with. See there for why it travels in the handle rather than in the node.
  lappend context $element
  foreach child [dict get $element children] {
    lappend result [list tclpdf $context $child]
  }
  return $result
}

# Character data and elements TOGETHER, in document order: a list of
# {text <string>} and {element <handle>}.
#
# [text] and [children] each answer half the question and neither says how the
# two halves interleave - which is exactly what a <text> in an SVG needs:
# "A<tspan>B</tspan>C" is A, then the tspan, then C, and reading the two
# accessors put the C in front of the B. The fallback parser therefore keeps
# an ORDER list beside its text and children; a tdom node has the order in its
# childNodes already.
proc ::tclpdf::xml::nodes {node} {
  lassign $node kind context element
  set result {}
  if {$kind eq "tdom"} {
    foreach child [$element childNodes] {
      switch -- [$child nodeType] {
        TEXT_NODE - CDATA_SECTION_NODE {
          lappend result [list text [$child nodeValue]]
        }
        ELEMENT_NODE {
          lappend result [list element [list tdom $context $child]]
        }
      }
    }
    return $result
  }
  set children [children $node]
  foreach part [dict get $element order] {
    lassign $part what value
    if {$what eq "text"} {
      lappend result [list text $value]
    } else {
      lappend result [list element [lindex $children $value]]
    }
  }
  return $result
}

# The element that encloses this one, or the empty string at the root.
#
# tdom has it for nothing: a node is an object and knows its parent. The
# parser below builds nodes as DICTIONARIES, and a dictionary cannot point at
# the thing that contains it - the parent holds its children by value, so a
# parent pointer inside a child would be the parent holding a copy of itself.
# The chain of ancestors travels in the HANDLE instead: the slot a tdom handle
# spends on its document, which the other kind left empty, and [children] adds
# one element to it on the way down. The chain is complete either way, because
# a handle is only ever made from a node the parser has finished with.
#
# The alternative was to gather the inherited properties while [SvgCollect]
# walks the tree, which costs nothing per handle - and it was NOT taken:
# SvgCollect belongs to svgElement and runs BEFORE anything has loaded
# svgClip, whose reader knows how a property is spelled. It would have had one
# module reach into another that is not loaded yet, for one property, where
# this answers the question for every caller and every property.
#
# The price, measured on 2026-08-25 over 401 real SVG files (7225 elements):
# the WALK alone goes from 3.3 to 3.5 ms with the parser below - two tenths
# of a millisecond against the 182 ms that parsing the same set costs - and
# nothing at all through tdom, which asks the node instead of carrying
# anything. Over parse and walk together the difference stays inside the
# noise.
proc ::tclpdf::xml::parent {node} {
  lassign $node kind context element
  if {$kind eq "tdom"} {
    # The document element's parent is the document, and tdom answers the
    # empty string for it - which is the answer wanted here anyway.
    set enclosing [$element parentNode]
    if {$enclosing eq {} || [$enclosing nodeType] ne "ELEMENT_NODE"} {
      return {}
    }
    return [list tdom $context $enclosing]
  }
  if {![llength $context]} {
    return {}
  }
  return [list tclpdf [lrange $context 0 end-1] [lindex $context end]]
}

# The character data directly inside an element, its element children left
# out. Both parsers answer the same thing for the same document.
proc ::tclpdf::xml::text {node} {
  lassign $node kind document element
  if {$kind eq "tdom"} {
    set result {}
    foreach child [$element childNodes] {
      if {[$child nodeType] in {TEXT_NODE CDATA_SECTION_NODE}} {
        append result [$child nodeValue]
      }
    }
    return $result
  }
  return [dict get $element text]
}

# Every descendant with a given name, in document order.
proc ::tclpdf::xml::find {node wanted} {
  set found {}
  if {[name $node] eq $wanted} {
    lappend found $node
  }
  foreach child [children $node] {
    lappend found {*}[find $child $wanted]
  }
  return $found
}

# -- the fallback parser ---------------------------------------------------

# Returns a node dictionary: name, attributes, text, children.
proc ::tclpdf::xml::Parse {text} {
  # Read before the doctype is dropped below: which entity references the
  # document may make is said there and nowhere else.
  set entities [Entities $text]
  set markup [Markup $entities]
  # Each declared entity expanded once per kind of value, see [Unescape].
  set expansions [dict create]
  set text [Strip $text]

  set stack {}
  set root {}
  set position 0
  while {[regexp -indices -start $position {<\s*(/?)\s*([^\s/>]+)((?:[^>"']|"[^"]*"|'[^']*')*?)(/?)\s*>} \
      $text match closing name attributes empty]} {
    lassign $match matchStart matchEnd
    set before [string range $text $position $matchStart-1]
    if {[llength $stack] && [llength $markup]
        && [Splice text $position $before $entities $markup]} {
      # The replacement text stands in the document in place of its
      # reference now, and the walk reads on from the same place.
      continue
    }
    if {[llength $stack] && [string trim $before] ne {}} {
      set top [lindex $stack end]
      set chunk [Unescape $before $entities text {the text} expansions]
      dict append top text $chunk
      # And the same chunk in the ORDER list, which is what [nodes] reads:
      # where the character data of an element stands relative to its
      # element children is a question neither [text] nor [children] can
      # answer, and an SVG <text> is nothing but that question.
      dict lappend top order [list text $chunk]
      lset stack end $top
    }
    set position [expr {$matchEnd + 1}]
    set isClosing [expr {[lindex $closing 0] <= [lindex $closing 1]}]
    set isEmpty [expr {[lindex $empty 0] <= [lindex $empty 1]}]
    set elementName [string range $text {*}$name]

    if {$isClosing} {
      set node [lindex $stack end]
      set stack [lrange $stack 0 end-1]
      if {[dict get $node name] ne $elementName} {
        return -code error -errorcode [list TCLPDF XML MALFORMED $elementName] \
            "tclpdf: XML is not well formed - \"$elementName\"\
            closes \"[dict get $node name]\""
      }
      if {[llength $stack]} {
        set parent [lindex $stack end]
        dict lappend parent order \
            [list element [llength [dict get $parent children]]]
        dict lappend parent children $node
        lset stack end $parent
      } else {
        # The root is complete, and only white space may follow it here.
        Trailing $text $position $elementName
        return $node
      }
      continue
    }

    set node [dict create name $elementName \
        attributes [Attributes [string range $text {*}$attributes] \
            $entities expansions] \
        text {} children {} order {}]
    if {$isEmpty} {
      if {![llength $stack]} {
        Trailing $text $position $elementName
        return $node
      }
      set parent [lindex $stack end]
      dict lappend parent order \
          [list element [llength [dict get $parent children]]]
      dict lappend parent children $node
      lset stack end $parent
      continue
    }
    lappend stack $node
  }

  if {[llength $stack]} {
    return -code error -errorcode [list TCLPDF XML MALFORMED unclosed] \
        "tclpdf: XML is not well formed - \"[dict get\
        [lindex $stack end] name]\" is never closed"
  }
  if {$root eq {}} {
    return -code error -errorcode [list TCLPDF XML EMPTY none] \
        "tclpdf: no XML element found"
  }
  return $root
}

# What follows the root element, from POSITION on. XML 1.0, 2.1 lets a
# document end in white space, comments and processing instructions, and the
# last two are gone by the time this is asked ([Parse] drops them first).
# Measured 2026-11-24: tdom refuses "<a/>x" and "<a/><b/>" as "junk after
# document element"; the parser here took both, the second by answering with
# <b> as the root.
proc ::tclpdf::xml::Trailing {text position name} {
  set rest [string trimleft [string range $text $position end] " \t\r\n"]
  if {$rest eq {}} {
    return
  }
  return -code error -errorcode [list TCLPDF XML MALFORMED trailing] \
      "tclpdf: XML is not well formed - \"[string map {\n { } \r { } \t { }} \
      [string range $rest 0 24]]\" follows the root element \"$name\",\
      where only white space, comments and processing instructions may"
}

# The first reference in BEFORE - the character data that starts at POSITION
# in the document - to an entity of MARKUP, replaced in the document by that
# entity's replacement text: 1 where one was replaced, 0 where none is there.
#
# XML 1.0, 4.4.2 includes the replacement text where the reference stands,
# and in content it is read as content: <!ENTITY sign "<g>...</g>"> makes an
# element. Measured 2026-11-24, tdom made one and the parser here left
# "&sign;" in the text. Put into the document and walked again, it is an
# element here too - one reference at a time, so that a reference inside the
# replacement text is met by the walk like any other. Only an entity that
# holds markup takes this road; every other one is expanded by [Unescape]
# without a copy of the document. Neither road loops: [Amplification] has
# refused every cycle and bounded every expansion.
proc ::tclpdf::xml::Splice {textVariable position before entities markup} {
  upvar 1 $textVariable text
  foreach {all reference} [regexp -all -inline -indices \
      {&([^\s&;<>"']+);} $before] {
    set name [string range $before {*}$reference]
    if {$name in $markup} {
      set text [string replace $text \
          [expr {$position + [lindex $all 0]}] \
          [expr {$position + [lindex $all 1]}] \
          [Strip [dict get $entities internal $name]]]
      return 1
    }
  }
  return 0
}

# Comments, processing instructions and the doctype carry nothing we want,
# and dropping them first means the element walk has three cases fewer. Asked
# of the document by [Parse] and of a replacement text by [Splice], which may
# hold the same.
proc ::tclpdf::xml::Strip {text} {
  regsub -all {<!--.*?-->} $text {} text
  regsub -all {<\?.*?\?>} $text {} text
  regsub -all {<!DOCTYPE[^>\[]*(\[[^\]]*\])?[^>]*>} $text {} text
  # CDATA is character data with markup switched off. Unwrapping it plainly
  # would hand its content to the element walk below - a CDATA holding
  # "<nicht>" then reads as an opening tag and the document stops being well
  # formed. So the two significant characters are escaped instead, and the
  # ordinary entity handling puts them back.
  while {[regexp -indices {<!\[CDATA\[(.*?)\]\]>} $text match inner]} {
    set content [string map {& &amp; < &lt;} [string range $text {*}$inner]]
    set text [string replace $text {*}$match $content]
  }
  return $text
}

proc ::tclpdf::xml::Attributes {text entities expansionsVariable} {
  upvar 1 $expansionsVariable expansions
  set result {}
  foreach {-> name value quoted} [regexp -all -inline \
      {([^\s=]+)\s*=\s*(?:"([^"]*)"|'([^']*)')} $text] {
    # Not a ternary in expr: expr would read a numeric-looking value such as
    # 010 as a number and hand back 8 under Tcl 8.6.
    if {$value eq {}} {
      set value $quoted
    }
    dict set result $name \
        [Unescape $value $entities attribute "the attribute $name" expansions]
  }
  return $result
}

# The references of a text or an attribute value, each replaced by what it
# stands for. CONTEXT is "text" or "attribute", WHERE names the value for a
# message, EXPANSIONS is the caller's dictionary of the entities expanded so
# far.
#
#   &lt; &gt; &amp; &quot; &apos;  the character
#   &#65; &#x41;                   the character, where XML has one
#                                  ([Character])
#   &name; of the internal subset  its replacement text, read in turn as the
#                                  same kind of value - "&amp;" in it is an
#                                  ampersand, "&other;" is expanded as well
#   &name; declared external       refused in an attribute value (XML 1.0,
#                                  3.1, WFC "No External Entity References");
#                                  in text nothing, since nothing here fetches
#                                  a file
#   &name; declared nowhere        nothing where an external subset may
#                                  declare it ([Entities], OPEN), refused
#                                  otherwise (4.1, WFC "Entity Declared")
#   any other "&"                  refused - "x & y", "&amp" without its
#                                  semicolon, "&#;"
#
# Every line is what tdom 0.9.7 answers, measured 2026-11-24. Until that day
# the parser here left a declared entity, an external one and an undeclared
# one under an open doctype standing as written, and took "&#0;" for a
# character. A replacement text that holds "<" is refused in an attribute
# value (3.1, WFC "No < in Attribute Values"), as tdom refuses it; in text,
# [Splice] has put it into the document before this is asked.
#
# The recursion ends and its output is bounded: [Amplification] has measured
# every expansion and refused every cycle before the parse began. Each entity
# is expanded once per CONTEXT and then taken from EXPANSIONS, so that a
# thousand references to one entity cost one expansion.
proc ::tclpdf::xml::Unescape {text entities context where expansionsVariable} {
  if {[string first & $text] < 0} {
    return $text
  }
  upvar 1 $expansionsVariable expansions
  # One pass over the ampersands, each replaced by its character where it
  # begins a reference; the text between them is copied, never evaluated. No
  # subst here: it would run any bracketed command the document carries. The
  # digits go through scan, so &#065; is 65 under Tcl 8.6 as well.
  set result {}
  set from 0
  foreach {all reference} [regexp -all -inline -indices \
      {&(?:([^\s&;<>"']+);)?} $text] {
    lassign $all start end
    append result [string range $text $from [expr {$start - 1}]]
    set from [expr {$end + 1}]
    if {[lindex $reference 0] < 0} {
      Unreferenced $text $start $where
    }
    set name [string range $text {*}$reference]
    if {$name in {lt gt quot apos amp}} {
      append result [dict get {lt < gt > quot \" apos ' amp &} $name]
    } elseif {[regexp {^#x([0-9A-Fa-f]+)$} $name -> digits]} {
      append result [Character $digits x $text $start $where]
    } elseif {[regexp {^#([0-9]+)$} $name -> digits]} {
      append result [Character $digits d $text $start $where]
    } elseif {[string index $name 0] eq "#"} {
      Unreferenced $text $start $where
    } elseif {[dict exists $entities internal $name]} {
      set key [list $context $name]
      if {![dict exists $expansions $key]} {
        set replacement [dict get $entities internal $name]
        if {$context eq "attribute" && [string first < $replacement] >= 0} {
          return -code error -errorcode [list TCLPDF XML MALFORMED markup] \
              "tclpdf: XML is not well formed - the entity \"&$name;\" in\
              $where \"[Excerpt $text $start]\" holds markup, which an\
              attribute value cannot"
        }
        dict set expansions $key \
            [Unescape $replacement $entities $context $where expansions]
      }
      append result [dict get $expansions $key]
    } elseif {$name in [dict get $entities external]} {
      if {$context eq "attribute"} {
        return -code error -errorcode [list TCLPDF XML MALFORMED external] \
            "tclpdf: XML is not well formed - the entity \"&$name;\" in\
            $where \"[Excerpt $text $start]\" is an external entity, which\
            an attribute value cannot refer to"
      }
      if {$name in [dict get $entities unparsed]} {
        return -code error -errorcode [list TCLPDF XML MALFORMED external] \
            "tclpdf: XML is not well formed - the entity \"&$name;\" in\
            $where \"[Excerpt $text $start]\" is an unparsed entity, which\
            the text cannot refer to"
      }
    } elseif {[dict get $entities open]} {
      # Declared, perhaps, where nothing here reads: nothing, as with tdom.
    } else {
      return -code error -errorcode [list TCLPDF XML MALFORMED reference] \
          "tclpdf: XML is not well formed - the entity \"&$name;\" in\
          $where \"[Excerpt $text $start]\" is not declared"
    }
  }
  append result [string range $text $from end]
  return $result
}

# An "&" that begins no reference, refused with the text around it.
proc ::tclpdf::xml::Unreferenced {text start where} {
  return -code error -errorcode [list TCLPDF XML MALFORMED ampersand] \
      "tclpdf: XML is not well formed - the \"&\" in $where\
      \"[Excerpt $text $start]\" begins no reference; write it as \"&amp;\""
}

# A few characters either side of a position, on one line, for a message.
proc ::tclpdf::xml::Excerpt {text position} {
  return [string map {\n { } \r { } \t { }} \
      [string trim [string range $text $position-12 $position+12]]]
}

package provide tclpdf::xml 1.3
