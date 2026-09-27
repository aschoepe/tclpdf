#
# tclpdf - PDF generation for Tcl
#
# markup - a paragraph written with tags, turned into the runs [text -runs 1]
# sets: "<b>bold</b>, <i>italic</i>, <a href=...>a link</a>, <h1>a heading</h1>"
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# WHY TAGS AND NOT MARKDOWN (decided by the author, 2026-09-27; the whole
# weighing is in docs/MARKUP.md). The vocabulary is CLOSED: eleven names, and
# nothing else between angle brackets is a tag - so the one character a
# caller has to watch is a "<" in front of a letter, where Markdown's "*",
# "_", "#", "~" and "[" all occur in ordinary text. Opening and closing are
# explicit, so a nesting fault is a refusal with a position rather than a
# guess. And the names are the structure vocabulary of ISO 32000-2, 14.8.4 -
# a tagged document gets its H1, Strong, Em and Link from the spelling.
# Markdown is read as well, since the same day, as the SECOND notation
# (markdown.tcl): a strict subset that ends in the same pairs through [emit]
# below.
#
# WHAT THIS MODULE IS: a translator from one string into the list of {text
# options} pairs that textRun.tcl takes, and nothing else. It knows no
# document, no font and no page; [::tclpdf::markup::parse] is a plain
# procedure, which is what makes it testable on its own and keeps the block
# road one road: with -markup tags the string is translated here and then
# set exactly as a list the caller could have written by hand.
#
# THE RULES, as the manual states them:
#
#   - Tags are b i u s em strong a h1 h2 h3 p, opening and closing, in any
#     case; <a> takes href="..." and nothing else takes an attribute.
#   - A "<" in front of a space, a digit, "=" or the end is text ("a < b",
#     "< 5 %"). A "<" in front of a letter or "/" has to open a known tag -
#     otherwise TCLPDF TEXT MARKUP UNKNOWN, with the name and the position.
#   - One escape: &lt; for a literal "<" in front of a letter, and &gt; and
#     &amp; beside it for symmetry. No other entity; "&" is text.
#   - Nesting is strict. A closing tag has to close the innermost open one
#     (NESTING); an open tag at the end is OPEN; a paragraph tag inside a
#     run, or a heading inside a paragraph, is NESTING too. A tag repeated
#     inside itself is allowed and does nothing.
#   - <p> and <h1>-<h3> are paragraphs; text between them is a paragraph of
#     its own. A line feed in the text stays a paragraph break, as it is
#     without markup, so that a caller who wants nothing but <b> changes
#     nothing else.
#   - b and strong, i and em set alike; what differs is the structure
#     element a tagged document gets, which textRun.tcl decides from the
#     option names handed on here: "strong" and "em" travel as such.
#

package require Tcl 8.6.11-

namespace eval ::tclpdf::markup {
  # The vocabulary, and what each name means to a run: the option it sets,
  # or "paragraph"/"heading" for the block-level ones.
  variable tags {
    b {style bold} strong {style bold strong 1}
    i {style italic} em {style italic em 1}
    u {underline 1} s {strike 1}
    a {url {}}
    h1 {heading 1} h2 {heading 2} h3 {heading 3}
    p {paragraph 1}
  }
  variable entities {&lt; < &gt; > &amp; &}
}

# The pairs a tagged string sets as. Every refusal names the position in the
# string, counted in characters from 0, as the error codes of this package
# count.
proc ::tclpdf::markup::parse {text} {
  variable tags
  variable entities
  set pairs {}
  set stack {}
  set buffer {}
  set position 0
  set length [string length $text]
  # Whether the text emitted so far ends at a paragraph boundary - the
  # start, or a line feed - which is what <p> and a heading need in front of
  # them and behind them.
  set boundary 1
  while {$position < $length} {
    set char [string index $text $position]
    if {$char eq "&"} {
      set taken 0
      foreach {entity literal} $entities {
        set end [expr {$position + [string length $entity] - 1}]
        if {[string range $text $position $end] eq $entity} {
          append buffer $literal
          incr position [string length $entity]
          set taken 1
          break
        }
      }
      if {!$taken} {
        append buffer $char
        incr position
      }
      continue
    }
    if {$char ne "<"} {
      append buffer $char
      set boundary [expr {$char eq "\n"}]
      incr position
      continue
    }
    set next [string index $text $position+1]
    if {![regexp {[A-Za-z/]} $next]} {
      # "a < b", "< 5 %", a "<" at the very end: text.
      append buffer $char
      set boundary 0
      incr position
      continue
    }
    if {![regexp -start $position {\A<(/?)([A-Za-z][A-Za-z0-9]*)((?:\s+[^>]*)?)>} $text whole closing name attributes]} {
      return -code error -errorcode [list TCLPDF TEXT MARKUP UNKNOWN \
          [string range $text $position+1 $position+12] $position] \
          "tclpdf: \"<\" at position $position opens no tag - a tag is\
          <b>, <i>, <u>, <s>, <em>, <strong>, <a href=\"...\">, <h1> to <h3>\
          or <p>; write &lt; for a literal \"<\" in front of a letter"
    }
    set name [string tolower $name]
    if {![dict exists $tags $name]} {
      return -code error -errorcode [list TCLPDF TEXT MARKUP UNKNOWN $name $position] \
          "tclpdf: unknown tag <$name> at position $position - known are\
          [join [lmap n [dict keys $tags] {string cat < $n >}] {, }]"
    }
    set effect [dict get $tags $name]
    set block [expr {[dict exists $effect paragraph] || [dict exists $effect heading]}]
    if {$closing eq "/"} {
      if {![llength $stack] || [lindex $stack end 0] ne $name} {
        set expected [expr {[llength $stack] ? "</[lindex $stack end 0]>" : "no tag"}]
        return -code error -errorcode [list TCLPDF TEXT MARKUP NESTING $name $position] \
            "tclpdf: </$name> at position $position closes a tag that is\
            not the innermost open one - $expected is"
      }
      # The text inside goes out with the options in force up to here.
      lassign [emit $pairs $buffer $stack] pairs buffer
      set stack [lrange $stack 0 end-1]
      if {$block} {
        # A paragraph ends here. The line feed that ends it is text of the
        # block: it stays out where nothing follows, so that the block does
        # not end on an empty paragraph.
        set boundary 0
        if {$position + [string length $whole] < $length} {
          lappend pairs "\n" {}
          set boundary 1
        }
      }
      incr position [string length $whole]
      continue
    }
    # An opening tag. Text in front of it goes out first, with what was in
    # force in front of it.
    lassign [emit $pairs $buffer $stack] pairs buffer
    if {$block} {
      if {[llength $stack]} {
        return -code error -errorcode [list TCLPDF TEXT MARKUP NESTING $name $position] \
            "tclpdf: <$name> at position $position is a paragraph and\
            cannot stand inside <[lindex $stack end 0]> - close the run\
            first"
      }
      if {!$boundary} {
        lappend pairs "\n" {}
      }
    }
    set href {}
    if {$name eq "a"} {
      if {![regexp {^\s+href\s*=\s*"([^"]*)"\s*$} $attributes -> href] || $href eq {}} {
        return -code error -errorcode [list TCLPDF TEXT MARKUP HREF $position] \
            "tclpdf: <a> at position $position needs href=\"...\" with an\
            address in double quotes, and nothing else"
      }
    } elseif {[string trim $attributes] ne {}} {
      return -code error -errorcode [list TCLPDF TEXT MARKUP ATTRIBUTE $name $position] \
          "tclpdf: <$name> at position $position takes no attribute -\
          only <a href=\"...\"> does"
    }
    lappend stack [list $name $href]
    set boundary [expr {$block ? 1 : 0}]
    incr position [string length $whole]
  }
  if {[llength $stack]} {
    return -code error -errorcode [list TCLPDF TEXT MARKUP OPEN [lindex $stack end 0]] \
        "tclpdf: <[lindex $stack end 0]> is still open at the end of the\
        text - close it with </[lindex $stack end 0]>"
  }
  lassign [emit $pairs $buffer $stack] pairs buffer
  return $pairs
}

# The buffered text as one pair carrying the options of the tags in force.
# An empty buffer emits nothing; the buffer comes back empty.
#
# Public because it is shared by the Markdown translator (markdown.tcl): its
# stack carries the names of the vocabulary above, and this is the one place
# that decides what a name does to a run - so the same paragraph written in
# either notation comes out as the identical list of pairs.
proc ::tclpdf::markup::emit {pairs buffer stack} {
  variable tags
  if {$buffer eq {}} {
    return [list $pairs {}]
  }
  set options {}
  set style {}
  foreach entry $stack {
    lassign $entry name href
    foreach {key value} [dict get $tags $name] {
      switch -- $key {
        style {
          if {$value ni $style} {
            lappend style $value
          }
        }
        url {dict set options url $href}
        paragraph {}
        default {dict set options $key $value}
      }
    }
  }
  if {[llength $style]} {
    dict set options style [lsort $style]
  }
  lappend pairs $buffer $options
  return [list $pairs {}]
}

package provide tclpdf::markup 1.1
