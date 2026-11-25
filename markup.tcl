#
# tclpdf - PDF generation for Tcl
#
# markup - a paragraph written with tags, turned into the runs [text -runs 1]
# sets: "<b>bold</b>, <i>italic</i>, <a href=...>a link</a>, <h1>a heading</h1>,
# <ul><li>an item</li></ul>"
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# WHY TAGS AND NOT MARKDOWN (decided by the author, 2026-09-27; the whole
# weighing is in docs/MARKUP.md). The vocabulary is CLOSED: fourteen names, and
# nothing else between angle brackets is a tag - so the one character a
# caller has to watch is a "<" in front of a letter, where Markdown's "*",
# "_", "#", "~" and "[" all occur in ordinary text. Opening and closing are
# explicit, so a nesting fault is a refusal with a position rather than a
# guess. And the names are the structure vocabulary of ISO 32000-2, 14.8.4 -
# a tagged document gets its H1, Strong, Em, Link, L and LI from the spelling.
# Markdown is read as well, since the same day, as the SECOND notation
# (markdown.tcl): a strict subset that ends in the same pairs through [emit]
# below.
#
# WHAT THIS MODULE IS: a translator from one string into the list of {text
# options} pairs that textRun.tcl takes, and nothing else. It knows no
# document, no font and no page; [::tclpdf::markup::parse] is a plain
# procedure, which is what makes it testable on its own and keeps the block
# road one road: with -markup tags the string is translated here and then
# set exactly as a list the caller could have written by hand. Beside it
# stands [::tclpdf::markup::repair], as plain: it writes the places [parse]
# refuses as text and says which they were, for strings typed by people
# (see the comment above it, at the end of this file).
#
# THE RULES, as the manual states them:
#
#   - Tags are b i u s em strong a h1 h2 h3 p ul ol li, opening and closing,
#     in any case; <a> takes href="..." and nothing else takes an attribute.
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
#   - <ul> and <ol> are lists, bulleted and numbered, and hold nothing but
#     <li> items. An item is a paragraph: every run inside it carries the
#     option "item bullet" or "item number", taken from the list around it,
#     beside whatever b, i, u, s, a, strong or em add. Between two items
#     stands exactly one "\n" pair; around the list the paragraph rule of <p>
#     holds - a line feed in front of it unless the text there already ends
#     in one, and one behind it only where something follows. Consecutive
#     items of one kind are one list; the numbers are counted by the setting,
#     not written here.
#   - White space directly inside <ul> or <ol> - behind <ul>, between </li>
#     and <li>, in front of </ul> - is swallowed, so that a list can be
#     written one item per line without an empty paragraph between the items.
#     Anything else there, text or a tag other than <li>, is NESTING, and so
#     is an <li> anywhere but directly inside a list.
#   - Lists do not nest: <ul> or <ol> inside a list, a run, a paragraph or a
#     heading is NESTING, like <p> inside a run. Inside an <li> a line feed is
#     NESTING too: an item is ONE paragraph, and a line feed would begin a
#     second one that no longer belongs to the item, as a <p> inside it would.
#     A line feed directly behind </ul> is text, as behind </p>.
#   - b and strong, i and em set alike; what differs is the structure
#     element a tagged document gets, which textRun.tcl decides from the
#     option names handed on here: "strong" and "em" travel as such.
#

package require Tcl 8.6.11-

namespace eval ::tclpdf::markup {
  namespace export parse repair
  # The vocabulary, and what each name means to a run: the option it sets,
  # or "paragraph"/"heading"/"list" for the block-level ones. An item takes
  # its kind from the list around it - [emit] fills in the "item" option from
  # the "list" entry below it on the stack.
  variable tags {
    b {style bold} strong {style bold strong 1}
    i {style italic} em {style italic em 1}
    u {underline 1} s {strike 1}
    a {url {}}
    h1 {heading 1} h2 {heading 2} h3 {heading 3}
    p {paragraph 1}
    ul {list bullet} ol {list number} li {item {}}
  }
  variable entities {&lt; < &gt; > &amp; &}
}

# The pairs a tagged string sets as. Every refusal names the position in the
# string, counted in characters from 0, as the error codes of this package
# count. The stack holds {name href position} entries - the position where
# the tag was opened, which is what an OPEN refusal names.
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
    # What the innermost open tag is: directly inside <ul> or <ol> white
    # space is swallowed and any other text refused, and inside an <li> a
    # line feed is refused - the item is one paragraph.
    set inside [expr {[llength $stack] ? [dict get $tags [lindex $stack end 0]] : {}}]
    if {[dict exists $inside list]} {
      if {[string is space $char]} {
        incr position
        continue
      }
      if {$char ne "<" || ![regexp {[A-Za-z/]} [string index $text $position+1]]} {
        return -code error -errorcode [list TCLPDF TEXT MARKUP NESTING li $position] \
            "tclpdf: text at position $position stands directly inside\
            <[lindex $stack end 0]> - a list holds nothing but <li> items;\
            put the text into an <li>, or close the list first"
      }
    }
    if {$char eq "\n" && [lsearch -exact -index 0 $stack li] >= 0} {
      return -code error -errorcode [list TCLPDF TEXT MARKUP NESTING li $position] \
          "tclpdf: the line feed at position $position stands inside <li> - an\
          item is one paragraph; close the item, or the list, first"
    }
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
          <b>, <i>, <u>, <s>, <em>, <strong>, <a href=\"...\">, <h1> to <h3>,\
          <p>, <ul>, <ol> or <li>; write &lt; for a literal \"<\" in front of a letter"
    }
    set name [string tolower $name]
    if {![dict exists $tags $name]} {
      return -code error -errorcode [list TCLPDF TEXT MARKUP UNKNOWN $name $position] \
          "tclpdf: unknown tag <$name> at position $position - known are\
          [join [lmap n [dict keys $tags] {string cat < $n >}] {, }]"
    }
    set effect [dict get $tags $name]
    set block [expr {[dict exists $effect paragraph] || [dict exists $effect heading]
        || [dict exists $effect list]}]
    set item [dict exists $effect item]
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
      } elseif {$item} {
        # An item ends here, and its paragraph break waits for the next
        # <li>: behind the last item the list's own close decides, so that a
        # list at the end of the text does not end on an empty paragraph.
        set boundary 0
      }
      incr position [string length $whole]
      continue
    }
    # An opening tag. Text in front of it goes out first, with what was in
    # force in front of it.
    lassign [emit $pairs $buffer $stack] pairs buffer
    set top [lindex $stack end 0]
    if {[dict exists $inside list] && !$item} {
      return -code error -errorcode [list TCLPDF TEXT MARKUP NESTING $name $position] \
          "tclpdf: <$name> at position $position stands directly inside\
          <$top> - a list holds nothing but <li> items"
    }
    if {$item && ![dict exists $inside list]} {
      set where [expr {[llength $stack] ? "not inside <$top>" : "not on its own"}]
      return -code error -errorcode [list TCLPDF TEXT MARKUP NESTING $name $position] \
          "tclpdf: <$name> at position $position is a list item and stands\
          directly inside <ul> or <ol>, $where"
    }
    if {$block && [llength $stack]} {
      set what [expr {[dict exists $effect list] ? "a list - lists do not nest -" : "a paragraph"}]
      return -code error -errorcode [list TCLPDF TEXT MARKUP NESTING $name $position] \
          "tclpdf: <$name> at position $position is $what and cannot stand\
          inside <$top> - close <$top> first"
    }
    if {($block || $item) && !$boundary} {
      lappend pairs "\n" {}
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
    lappend stack [list $name $href $position]
    set boundary [expr {$block || $item}]
    incr position [string length $whole]
  }
  if {[llength $stack]} {
    lassign [lindex $stack end] name - start
    return -code error -errorcode [list TCLPDF TEXT MARKUP OPEN $name $start] \
        "tclpdf: <$name> at position $start is still open at the end of the\
        text - close it with </$name>"
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
  set kind {}
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
        list {set kind $value}
        item {dict set options item $kind}
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

# --- repair ------------------------------------------------------------------
#
# WHY A REPAIR, AND NOT A LENIENT READING (the author's decision, 2026-11-25).
# Text people type into a form field - a remark on an order, a comment - may
# hold one "<" in front of a letter, and the strict reading refuses the whole
# paragraph for it. That stays: [parse] and -markup never guess. A caller who
# wants "that one place as text, the rest formatted" calls [repair] himself,
# and it tells him what it did: the string with every refused place written
# as text - visible, "<x>" stays "<x>" - and the list of the error codes it
# removed, to be logged or shown. The repaired string is then set the strict
# way, by the same -markup as before.
#
# HOW: [parse] is the judge, and the error code names the place. Every code
# of the tags ends in a position. Where the character there is a "<" - an
# unknown tag, a closing tag that is not the innermost, a tag where it may
# not stand, an <a> without href, a tag with an attribute, a tag still open
# at the end - that "<" is written &lt;, which makes the whole tag text. The
# other two refusals are not repaired, because no escape makes them right:
# text directly inside <ul> or <ol> (NESTING li at that text) and a line
# feed inside an <li>; they are thrown on unchanged, as is everything
# else no rule fits. Nothing is dropped in silence.

# The string a refusal leaves: the tag at the position the code names written
# as text, or the string as it was where the position holds no "<".
proc ::tclpdf::markup::Literal {text code} {
  variable entities
  set position [lindex $code end]
  if {[string index $text $position] ne "<"} {
    return $text
  }
  return [string replace $text $position $position \
      [lindex [dict keys [dict filter $entities value <]] 0]]
}

# A string the strict reading refuses, made one it takes; see the comment
# above. Answers {text <the string> faults <the codes removed, in order>}.
proc ::tclpdf::markup::repair {text} {
  return [repairWith $text MARKUP ::tclpdf::markup::parse ::tclpdf::markup::Literal]
}

# The loop both notations repair with: read the string with "parse", hand
# each refusal of the topic "notation" to "literal", which answers the string
# with the refused place written as text, and read it again, until it is
# taken.
#
# Public because it is shared by the Markdown translator (markdown.tcl),
# like [emit]: the loop and its guard exist once.
#
# A place written as text never opens, closes or refuses anything again, so
# every round turns at least one character of the string into text for good,
# and there are no more rounds than characters. A string still refused after
# that many is a defect, refused as TCLPDF TEXT <notation> REPAIR with the
# count, never a loop. A refusal "literal" cannot repair - it answers the
# string unchanged - is thrown on as it came, and so is any other error; its
# position counts in the string as far as it was repaired, which is the
# string as handed in where nothing was repaired in front of that place.
# The positions are whole numbers out of the error code; the string itself
# is only cut and spliced, never read as a number, so "0123" stays "0123".
proc ::tclpdf::markup::repairWith {text notation parse literal} {
  set faults {}
  set limit [string length $text]
  while {[catch {{*}$parse $text} message options]} {
    set code [dict get $options -errorcode]
    if {[lrange $code 0 2] ne [list TCLPDF TEXT $notation]} {
      return -options $options $message
    }
    if {[llength $faults] >= $limit} {
      # Each code written out, so that the table of codes reads its class.
      set message "tclpdf: the string is still refused after $limit repairs,\
          one for each of its characters ($code) - a defect of the repair"
      if {$notation eq "MARKDOWN"} {
        return -code error -errorcode [list TCLPDF TEXT MARKDOWN REPAIR $limit] $message
      }
      return -code error -errorcode [list TCLPDF TEXT MARKUP REPAIR $limit] $message
    }
    set repaired [{*}$literal $text $code]
    if {$repaired eq $text} {
      return -options $options $message
    }
    lappend faults $code
    set text $repaired
  }
  return [dict create text $text faults $faults]
}

package provide tclpdf::markup 1.3
