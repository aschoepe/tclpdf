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
# Two parsers behind four accessors. tdom is used when it is installed,
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
#   entity bomb   tdom refuses one that amplifies beyond 100x, its own
#                 default; the parser below cannot expand at all, because it
#                 does not know user-defined entities
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

  if {$haveTdom} {
    # -paramentityparsing never, spelled out. The default is "always": tdom
    # then TRIES to resolve external entities and the external subset, and
    # only fails to because no -externalentitycommand is given. Security by a
    # missing ingredient is not security - this says it.
    set document [dom parse -paramentityparsing never $text]
    set root [$document documentElement]
    if {$root eq {}} {
      $document delete
      return -code error "tclpdf: no XML element found"
    }
    return [list tdom $document $root]
  }
  return [list tclpdf {} [Parse $text]]
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
  lassign $node kind document element
  set result {}
  if {$kind eq "tdom"} {
    foreach child [$element childNodes] {
      if {[$child nodeType] eq "ELEMENT_NODE"} {
        lappend result [list tdom $document $child]
      }
    }
    return $result
  }
  foreach child [dict get $element children] {
    lappend result [list tclpdf {} $child]
  }
  return $result
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
      dict append top text [Unescape $before]
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
        return -code error "tclpdf: XML is not well formed - \"$elementName\"\
            closes \"[dict get $node name]\""
      }
      if {[llength $stack]} {
        set parent [lindex $stack end]
        dict lappend parent children $node
        lset stack end $parent
      } else {
        set root $node
      }
      continue
    }

    set node [dict create name $elementName \
        attributes [Attributes [string range $text {*}$attributes]] \
        text {} children {}]
    if {$isEmpty} {
      if {![llength $stack]} {
        return $node
      }
      set parent [lindex $stack end]
      dict lappend parent children $node
      lset stack end $parent
      continue
    }
    lappend stack $node
  }

  if {[llength $stack]} {
    return -code error "tclpdf: XML is not well formed - \"[dict get\
        [lindex $stack end] name]\" is never closed"
  }
  if {$root eq {}} {
    return -code error "tclpdf: no XML element found"
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

package provide tclpdf::xml 1.0
