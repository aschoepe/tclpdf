#
# tclpdf - PDF generation for Tcl
#
# svgCss - the class rules of a <style> block
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# A MINIMAL STYLESHEET, and deliberately so. What an SVG exporter puts into a
# <style> block is, on this machine, almost entirely one thing: rules whose
# selector is a class, ".cls-1 {fill:#0086b3}", alone or in a comma group
# ".cls-1, .cls-2 {stroke-width:0px}". Counted on 2026-11-25 over the 11375
# SVG files under ~/src and ~/Downloads: 49 carry a <style> block, 39 of them
# use class="", and their selectors are 87 plain classes, 22 @-rules (nearly
# all @font-face), 5 element selectors, 2 id selectors and 4 others. 38 of
# the 49 blocks stand inside <defs> - an Illustrator export keeps them there,
# and so does the official ZUGFeRD logo, which until this module came out as
# a black rectangle: its blue and its white live in two class rules.
#
# What is read:
#
#   blocks      every <style> element of the drawing, wherever it stands,
#               <defs> included, in document order, as ONE stylesheet; a
#               type other than text/css is not CSS and is not read
#   selectors   a single class, ".name", also as a member of a comma group;
#               the name is a CSS identifier, escapes included, so ".\30 123"
#               is the class "0123" - which stays the TEXT 0123 throughout
#   properties  exactly the ones the style cascade reads from an attribute
#               and from style="" - the list is [svgPaint]'s and not a
#               second one here - plus stop-color and stop-opacity, which a
#               <stop> reads on its own
#   comments    /* ... */ and the <!-- --> pair are taken out before anything
#               else
#
# The cascade is SVG 1.1, 6.4: a presentation attribute is a rule of
# specificity zero at the START of the author stylesheet, so EVERY class rule
# beats it; a style="" attribute beats every class rule. Among class rules -
# all of the same specificity - the one standing LATER in the stylesheet
# wins, whatever order class="a b" names them in. A property set through a
# class is inherited exactly like one set through an attribute: the class
# writes into the same style dictionary [SvgStyle] hands down.
#
# What is NOT read, and stays reported as "style" by [svg info]: @-rules
# (@font-face, @media, @import), every selector that is not a single class
# (rect, #id, .a .b, .a.b, rect.a, :hover, *), a declaration marked
# !important, and a declaration of a property outside the list above -
# clip-path and mask among them, which this package reads from an attribute
# or a style="" but not from a class. A block from which everything was
# read is no omission and is not reported; one with anything left over is
# reported once, as the block was before. The reason for the narrow line is
# the count above: the rest occurs in a handful of files, and a stylesheet
# with selectors and specificity is a second cascade this package would
# have to keep right in all its corners for them.
#
# The topic is the stylesheet - read it, and answer the declarations one
# element gets from it. Where they go in the cascade is [SvgStyle]'s
# business, in svgPaint.tcl, and the pre-pass [SvgCheckPaint] in svg.tcl
# asks the same answer, so a colour a class names is checked before the
# first byte of the drawing is written like any other.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::xml 1.3-
package require tclpdf::svgPaint 1.10-
package require tclpdf::document 1.18-

namespace eval ::tclpdf::svgCss {
}

# The rules of a stylesheet, as a list of {prelude body} pairs in the order
# they stand. An @-rule keeps its "@" at the front of the prelude, so that
# [selectors] can tell it apart, and its body is whatever its braces hold -
# nested braces included, which is what @media carries. A stray tail with no
# block after it comes back with an empty prelude. A block that is never
# closed runs to the end of the text, the way CSS recovers from it.
proc ::tclpdf::svgCss::rules {text} {
  regsub -all {/\*.*?\*/} $text { } text
  # An unterminated comment runs to the end (CSS Syntax 3, 4.3.2).
  regsub {/\*.*$} $text {} text
  regsub -all {<!--|-->} $text { } text
  set rules {}
  set position 0
  while {[regexp -start $position -indices {\S} $text first]} {
    set start [lindex $first 0]
    set open [string first "\{" $text $start]
    if {[string index $text $start] eq "@"} {
      # A statement @-rule (@import, @charset) ends at its semicolon, a
      # block @-rule at the brace that closes its block.
      set semicolon [string first ";" $text $start]
      if {$semicolon >= 0 && ($open < 0 || $semicolon < $open)} {
        lappend rules [list [string trim [string range $text $start \
            [expr {$semicolon - 1}]]] {}]
        set position [expr {$semicolon + 1}]
        continue
      }
    }
    if {$open < 0} {
      lappend rules [list {} {}]
      break
    }
    set close [::tclpdf::svgCss::Close $text $open]
    lappend rules [list \
        [string trim [string range $text $start [expr {$open - 1}]]] \
        [string range $text [expr {$open + 1}] [expr {$close - 1}]]]
    set position [expr {$close + 1}]
  }
  return $rules
}

# The index of the brace that closes the one at $open, or the length of the
# text when none does.
proc ::tclpdf::svgCss::Close {text open} {
  set depth 0
  set position $open
  while {[regexp -start $position -indices {[\{\}]} $text brace]} {
    set at [lindex $brace 0]
    if {[string index $text $at] eq "\{"} {
      incr depth
    } else {
      incr depth -1
      if {$depth == 0} {
        return $at
      }
    }
    set position [expr {$at + 1}]
  }
  return [string length $text]
}

# The classes a prelude selects, and how many of its selectors were not
# read: {classes unread}. Only a selector that is one class and nothing else
# is read; in a comma group each member is judged on its own, so
# ".a, rect" applies to class a and reports the rect.
proc ::tclpdf::svgCss::selectors {prelude} {
  if {$prelude eq {} || [string index $prelude 0] eq "@"} {
    return [list {} 1]
  }
  # A name character: letter, digit, hyphen, underscore, anything outside
  # ASCII, or an escape - a hex escape with its optional white space, or a
  # backslash before any other character (CSS Syntax 3, 4.3.7).
  set escape {\\[0-9a-fA-F]{1,6}[ \t\r\n\f]?|\\[^\r\n\f0-9a-fA-F]}
  set start "(?:\[_a-zA-Z\]|\[^\\x00-\\x7f\]|$escape)"
  set char "(?:\[-_a-zA-Z0-9\]|\[^\\x00-\\x7f\]|$escape)"
  set pattern "^\\.((?:--|-?$start)$char*)\$"
  set classes {}
  set unread 0
  foreach selector [split $prelude ,] {
    if {[regexp $pattern [string trim $selector] -> name]} {
      lappend classes [::tclpdf::svgCss::Unescape $name]
    } else {
      incr unread
    }
  }
  return [list $classes $unread]
}

# A CSS identifier with its escapes resolved. No [regsub -command], which
# Tcl 8.6 has not got. The hex digits are read with [scan %x] - a code
# point, never a text value going through [expr].
proc ::tclpdf::svgCss::Unescape {text} {
  set result {}
  set position 0
  while {[regexp -start $position -indices \
      {\\([0-9a-fA-F]{1,6})[ \t\r\n\f]?|\\(.)} $text match hex plain]} {
    append result [string range $text $position [expr {[lindex $match 0] - 1}]]
    if {[lindex $hex 0] >= 0} {
      scan [string range $text {*}$hex] %x code
      # Zero, a surrogate and anything past the last code point are the
      # replacement character (CSS Syntax 3, 4.3.7).
      if {$code == 0 || $code > 0x10FFFF ||
          ($code >= 0xD800 && $code <= 0xDFFF)} {
        set code 0xFFFD
      }
      append result [format %c $code]
    } else {
      append result [string range $text {*}$plain]
    }
    set position [expr {[lindex $match 1] + 1}]
  }
  append result [string range $text $position end]
  return $result
}

# The properties a declaration block marks !important, lower case. Such a
# declaration would outrank even style="" (CSS 2.1, 6.4.2), which is a
# second priority this module does not keep - so it is not applied at all
# and the block is reported, rather than applied at the wrong rank.
proc ::tclpdf::svgCss::important {body} {
  set names {}
  foreach {-> name} [regexp -all -inline -nocase \
      {([-a-z]+)\s*:[^;]*!\s*important} $body] {
    lappend names [string tolower $name]
  }
  return $names
}

oo::define ::tclpdf::document::document {

  # The stylesheet of one drawing, read once before the drawing starts and
  # kept in the state as svgClasses: class name -> list of {order
  # declarations}, where order is the position of the rule in the
  # stylesheet. Called by [SvgDraw] beside [SvgCollect], and like it before
  # the pre-pass, which needs the answer as well.
  method SvgCssCollect {root} {
    set classes [dict create]
    set order 0
    foreach node [my SvgCssBlocks $root] {
      foreach rule [dict get [my SvgCssBlock $node] rules] {
        lassign $rule names declarations
        incr order
        foreach name $names {
          dict lappend classes $name [list $order $declarations]
        }
      }
    }
    my state svgClasses $classes
    return
  }

  # The <style> elements under a node, in document order.
  method SvgCssBlocks {node} {
    set blocks {}
    foreach child [::tclpdf::xml children $node] {
      if {[string map {svg: {}} [::tclpdf::xml name $child]] eq "style"} {
        lappend blocks $child
      } else {
        lappend blocks {*}[my SvgCssBlocks $child]
      }
    }
    return $blocks
  }

  # One <style> block read: rules {{classes declarations} ...} with only
  # what is applied left in, and unread, the number of things in it that
  # are not. The declarations of a rule are read by [SvgDeclarations], the
  # same reader style="" goes through - a rule's body IS a declaration
  # block, and one reader means one treatment of comments and !important.
  method SvgCssBlock {node} {
    set text [::tclpdf::xml text $node]
    set type [string trim [::tclpdf::xml attribute $node type]]
    if {$type ne {} && ![string equal -nocase $type text/css]} {
      return [dict create rules {} unread [expr {[string trim $text] ne {}}]]
    }
    set read [concat $::tclpdf::svgPaint::cascade $::tclpdf::svgPaint::stop]
    set rules {}
    set unread 0
    foreach rule [::tclpdf::svgCss::rules $text] {
      lassign $rule prelude body
      lassign [::tclpdf::svgCss::selectors $prelude] names skipped
      incr unread $skipped
      if {![llength $names]} {
        continue
      }
      set declarations [my SvgDeclarations $body]
      foreach property [::tclpdf::svgCss::important $body] {
        if {[dict exists $declarations $property]} {
          dict unset declarations $property
          incr unread
        }
      }
      dict for {property value} $declarations {
        if {$property ni $read} {
          dict unset declarations $property
          incr unread
        }
      }
      lappend rules [list $names $declarations]
    }
    return [dict create rules $rules unread $unread]
  }

  # How many things in one <style> block are not applied - what decides
  # whether [svg info] reports the block (SvgStyleBlock, svgElement.tcl).
  method SvgCssUnread {node} {
    return [dict get [my SvgCssBlock $node] unread]
  }

  # The declarations one element gets from the stylesheet, as a dictionary:
  # every rule naming one of its classes, applied in the order the rules
  # stand - so the later rule wins, not the later name in class="".
  method SvgCssDeclarations {node} {
    set classes [my state svgClasses]
    if {![dict size $classes]} {
      return {}
    }
    set attribute [::tclpdf::xml attribute $node class]
    if {$attribute eq {}} {
      return {}
    }
    set matched {}
    foreach name [lsort -unique [regexp -all -inline {[^ \t\r\n\f]+} $attribute]] {
      if {[dict exists $classes $name]} {
        lappend matched {*}[dict get $classes $name]
      }
    }
    set declarations [dict create]
    foreach entry [lsort -integer -index 0 $matched] {
      set declarations [dict merge $declarations [lindex $entry 1]]
    }
    return $declarations
  }
}

package provide tclpdf::svgCss 1.0
