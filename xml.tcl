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
#                 cannot expand at all, because it does not know
#                 user-defined entities, so the check is free for it
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
# attributes, nesting, comments, CDATA, processing instructions and the five
# predefined entities plus numeric references. What it does not: a document
# type definition, custom entities, or namespaces as anything other than part
# of the name.
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
    set document [dom parse -paramentityparsing never $text]
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
proc ::tclpdf::xml::Amplification {text} {
  variable amplificationLimit
  variable amplificationFloor
  if {![regexp -indices {<!DOCTYPE[^>\[]*\[} $text head]} {
    return
  }
  set subset [string range $text [expr {[lindex $head 1] + 1}] end]
  set close [string first \] $subset]
  if {$close >= 0} {
    set subset [string range $subset 0 $close-1]
  }
  set definitions [dict create]
  foreach {-> name double single} [regexp -all -inline \
      {<!ENTITY\s+([^\s%>]+)\s+(?:"([^"]*)"|'([^']*)')\s*>} $subset] {
    dict set definitions $name [expr {$double ne {} ? $double : $single}]
  }
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

# One entity's expanded length, memoised, with the entities open on the way
# down as the cycle guard.
proc ::tclpdf::xml::Expanded {name definitions lengthsVariable open budget} {
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
  # Comments, processing instructions and the doctype carry nothing we want,
  # and dropping them first means the element walk has three cases fewer.
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

  set stack {}
  set root {}
  set position 0
  while {[regexp -indices -start $position {<\s*(/?)\s*([^\s/>]+)((?:[^>"']|"[^"]*"|'[^']*')*?)(/?)\s*>} \
      $text match closing name attributes empty]} {
    lassign $match matchStart matchEnd
    set before [string range $text $position $matchStart-1]
    if {[llength $stack] && [string trim $before] ne {}} {
      set top [lindex $stack end]
      set chunk [Unescape $before]
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
        set root $node
      }
      continue
    }

    set node [dict create name $elementName \
        attributes [Attributes [string range $text {*}$attributes]] \
        text {} children {} order {}]
    if {$isEmpty} {
      if {![llength $stack]} {
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

proc ::tclpdf::xml::Attributes {text} {
  set result {}
  foreach {-> name value quoted} [regexp -all -inline \
      {([^\s=]+)\s*=\s*(?:"([^"]*)"|'([^']*)')} $text] {
    dict set result $name [Unescape [expr {$value ne {} ? $value : $quoted}]]
  }
  return $result
}

# The five predefined entities and numeric references. Anything else is left
# alone: an unknown entity in an SVG is a broken file, and turning it into
# nothing silently would hide that.
proc ::tclpdf::xml::Unescape {text} {
  if {[string first & $text] < 0} {
    return $text
  }
  set text [string map {&lt; < &gt; > &quot; \" &apos; ' &#39; ' &#34; \"} $text]
  set text [regsub -all {&#x([0-9A-Fa-f]+);} $text {[format %c 0x\1]}]
  set text [regsub -all {&#([0-9]+);} $text {[format %c \1]}]
  set text [subst -novariables -nobackslashes $text]
  # Ampersand last, so that an escaped ampersand does not restart the others.
  return [string map {&amp; &} $text]
}

package provide tclpdf::xml 1.2
