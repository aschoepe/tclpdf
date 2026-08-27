#
# tclpdf - PDF generation for Tcl
#
# fieldChoice - the choice fields: list box and combo box (ISO 32000-2,
#               12.7.5.4)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Usage:
#
#   $doc field listbox colour -rect {20 40 40 20} \
#       -options {{R red} {G green} {B blue}} -value G
#   $doc field combo salutation -rect {20 70 40 8} \
#       -options {Mr Mrs Mx} -value Mrs -editable 1
#
# WHAT THIS FILE IS. One topic - the field type /FT /Ch - and both of the
# shapes the standard gives it, because they are ONE dictionary with one bit
# between them: Table 233, bit 18, "If set, the field is a combo box; if
# clear, the field is a list box". Two modules for one bit would be two
# copies of /Opt, of the display-versus-export rule and of the appearance,
# and the bit would still have to be set in both. So there are two
# subcommands and one build.
#
# The module attaches through the contract at the head of field.tcl and
# writes no catalogue key of its own: /AcroForm, /DA at the document level,
# /DR, the widget's object number and the page's /Annots are the core's.
#
# THE NAMES. [$doc field list] is taken - it is the core's own subcommand for
# the list of field NAMES, and [register] refuses it by name along with
# names, state and default. "choice" was the other candidate and is not used
# either: in the standard a choice field is the UMBRELLA over both shapes
# (12.7.5.4 is headed "Choice fields"), so a subcommand called "choice" would
# name the family and deliver one of its two members. The two members are
# therefore named apart - "listbox" and "combo" - and the family name stays
# free for the file it belongs to.
#
# THE ONE RULE EVERY WRITER GETS WRONG. /V of a choice field is the
# DISPLAYED TEXT, not the export value. 12.7.5.4, after Table 234: "V is a
# text string representing the selected item, as given in the field
# dictionary's Opt array ... (For items represented in the Opt array by a
# two-element array, the name string is the SECOND of the two array
# elements.)" The export value is the FIRST element and appears nowhere else
# in the field dictionary. The caller here names an option by whichever of
# the two he has - the export value is tried first, because that is the
# option's identity - and what lands in /V is the display text, always.
#
# /I, THE INDICES. Table 234: an array of integers "sorted in ascending
# order, representing the zero-based indices in the Opt array of the
# currently selected option items. This entry shall be used when two or more
# elements in the Opt array have different names but the same export value or
# when the value of the choice field is an array." The case that matters for
# a writer is the one /V cannot express: two options that SHOW the same text.
# /V then names both and neither, and only /I says which one is selected. So
# /I is written wherever it says something /V does not - a multiple
# selection, or a display text that occurs twice - and left out where it
# would only repeat what /V already says.
#
# /Opt AND THE TWO-WORD TRAP. An entry of the array is "either a text string
# representing one of the available options or an array consisting of two
# text strings: the option's export value and the text that shall be
# displayed" (Table 234). -options takes exactly that, in Tcl: an entry of
# one word is the option, an entry of two is {export display}. Which means a
# display text that is itself two words has to say so, and in Tcl it says so
# the way every nested list does - with a brace pair:
#
#   -options {{{very good}} {good} {poor}}     three options, first shown
#                                              as "very good"
#   -options {{1 {very good}} {2 good}}        two options with export values
#
# Guessing between the two by counting is the only rule that lets both forms
# stand in one list, and it is the rule the standard's own array uses.
#
# ONE VALUE, unless the field holds several. -value names one option, whole:
# on a field that shows one selection "very good" is the option "very good"
# and never the two options "very" and "good". Only -multi, which is the one
# option that lets a field hold more than one thing, reads -value as a list.
# -index does the same job by position and is the way out where two options
# show the same text.
#
# SORTING IS THE WRITER'S JOB. Table 233, bit 20, is the one flag in 12.7
# that the standard addresses to the writer in so many words: "This flag is
# intended for use by PDF writers, not by PDF readers. PDF readers shall
# display the options in the order in which they occur in the Opt array."
# -sort 1 therefore SORTS - by display text, [lsort -dictionary] - and sets
# the flag afterwards. A flag set over an unsorted array achieves nothing at
# all, in any reader.
#
# NO ECMASCRIPT, in a field type that is the usual home for it. A choice that
# fills other fields, a list that sorts itself in the reader, a combo that
# recalculates a total - all of them are /AA actions whose contents are
# defined in another standard entirely (12.6.4.17), and field.tcl says why
# this package writes none of them. What can be computed is computed here and
# written as /V with its /AP drawn.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::color 1.0-
package require tclpdf::geometry 1.0-
package require tclpdf::field 1.0-

# Point 1 of the contract. Two subcommands, one module: the two shapes of a
# choice field differ in one flag bit and share everything else.
::tclpdf::field register listbox tclpdf::fieldChoice
::tclpdf::field register combo tclpdf::fieldChoice

oo::define ::tclpdf::document::document {

  # $doc field listbox <name> -rect {x y w h} -options {...}
  #     ?-page n? ?-value v? ?-default v? ?-index {i ...}?
  #
  # -value names ONE option - by its export value, or by the text it shows -
  # and only with -multi 1 is it read as a list of them.
  #     ?-multi 0|1? ?-top n? ?-sort 0|1? ?-align left|center|right?
  #     ?-readonly 0|1? ?-required 0|1? ?-noexport 0|1? ?-commit 0|1?
  #     ?-family f? ?-style s? ?-size n? ?-color c?
  #     ?-border c? ?-borderWidth n? ?-background c? ?-highlight c?
  #     ?-tooltip text?
  #
  # -rect counts {x y w h} from the TOP left corner of the page in the unit
  # of the document, exactly as the text field, "link -at" and "sign -rect"
  # count.
  method FieldListbox {name args} {
    return [my FieldChoiceEntry listbox $name $args]
  }

  # $doc field combo <name> -rect {x y w h} -options {...}
  #     ?-editable 0|1? ?-spellcheck 0|1? and everything above that is not
  #     -multi, -top or -highlight
  #
  # A combo box shows one line and opens a list; only the editable one takes
  # a value the options do not offer.
  method FieldCombo {name args} {
    return [my FieldChoiceEntry combo $name $args]
  }

  # Both entries, because both parse the same options over the same checks.
  # Point 2 of the contract: everything is refused BEFORE the field is
  # declared, so a refused call leaves the document exactly as it was.
  method FieldChoiceEntry {kind name arguments} {
    set combo [expr {$kind eq "combo"}]
    set what "field $kind \"$name\""
    set defaults {
      rect {} page {} options {} value {} default {} index {}
      align left sort 0 readonly 0 required 0 noexport 0 commit 0
      family {} style {} size {} color {}
      border {} borderWidth 0.4 background {} tooltip {}
      contents {} label {}
    }
    if {$combo} {
      # -editable is the Edit flag, and -spellcheck 0 the DoNotSpellCheck
      # flag, which Table 233 admits only on an editable combo. Neither has
      # a spelling on a list box, so neither is offered there: an option
      # that exists and does nothing is worse than one that is refused.
      dict set defaults editable 0
      dict set defaults spellcheck 1
    } else {
      dict set defaults multi 0
      dict set defaults top 0
      # The selection bar. A light blue, which is what a reader paints
      # behind a selected row, and the caller's if he wants another.
      dict set defaults highlight {0.6 0.756863 0.854902}
    }
    set options [::tclpdf::option parse $defaults $arguments "field $kind"]

    set booleans {sort readonly required noexport commit}
    if {$combo} {
      lappend booleans editable spellcheck
    } else {
      lappend booleans multi
    }
    foreach flag $booleans {
      set value [dict get $options $flag]
      if {![string is boolean -strict $value]} {
        return -code error -errorcode [list TCLPDF FIELD BOOLEAN $flag] \
            "tclpdf: -$flag of $what is a boolean, not \"$value\""
      }
      dict set options $flag [expr {$value ? 1 : 0}]
    }
    if {[dict get $options align] ni {left center right}} {
      return -code error -errorcode \
          [list TCLPDF FIELD ALIGN [dict get $options align]] \
          "tclpdf: -align of $what is left, center or right - the /Q of ISO\
          32000-2, Table 228 knows those three - not\
          \"[dict get $options align]\""
    }

    set entries [my FieldChoiceOptions $what [dict get $options options]]
    if {[dict get $options sort]} {
      # The flag is for the writer (Table 233, bit 20), so the writer sorts.
      # By the DISPLAY text: it is what the reader shows and therefore what a
      # sorted list means to whoever reads it.
      set entries [lsort -dictionary -index 1 $entries]
    }

    set editable [expr {$combo && [dict get $options editable]}]
    set multi [expr {!$combo && [dict get $options multi]}]
    if {[dict get $options index] ne {} && [dict get $options value] ne {}} {
      return -code error -errorcode {TCLPDF FIELD COMBINATION} \
          "tclpdf: -value and -index both name the selection of $what and\
          only one of them can - -value names an option by its export value\
          or its displayed text, -index by its position in -options. Drop one\
          of the two"
    }
    if {[dict get $options index] ne {} && [dict get $options sort]} {
      # -sort reorders /Opt, and an index counts in the array as it stands in
      # the file. Rather than let the caller guess which order his numbers
      # are in, the pair is refused and the option that does not care is
      # named.
      return -code error -errorcode {TCLPDF FIELD COMBINATION} \
          "tclpdf: -index and -sort cannot both be given for $what - -sort\
          reorders the options before they are written (ISO 32000-2, Table\
          233, bit 20 is a flag for the writer), so a position counted in\
          -options is not the position in the file. Name the selection with\
          -value, or sort the list yourself and drop -sort"
    }
    if {[dict get $options index] ne {}} {
      set selection [my FieldChoiceIndices $what $entries \
          [dict get $options index]]
      set free {}
    } else {
      lassign [my FieldChoiceSelect $what $entries -value \
          [dict get $options value] $editable $multi] selection free
    }
    lassign [my FieldChoiceSelect $what $entries -default \
        [dict get $options default] $editable $multi] defaultSelection defaultFree
    if {!$multi && [llength $selection] > 1} {
      # Only -index can get here: -value is one value on a field that holds
      # one. Table 233, bit 22 is a LIST BOX flag, so a combo box has no
      # multiple selection to offer at all and is told so rather than sent
      # after an option it does not have.
      set hint "Pass -multi 1"
      if {$combo} {
        set hint "A combo box shows one line, and MultiSelect (ISO 32000-2,\
            Table 233, bit 22) is a list box flag - use \"field listbox ...\
            -multi 1\""
      }
      return -code error -errorcode {TCLPDF FIELD SELECT -index} \
          "tclpdf: -index of $what names [llength $selection] options and the\
          field takes one. $hint"
    }

    set top 0
    if {!$combo} {
      set top [dict get $options top]
      if {![string is integer -strict $top] || $top < 0
          || $top >= [llength $entries]} {
        return -code error -errorcode [list TCLPDF FIELD TOP $top] \
            "tclpdf: -top of $what is the index of the first VISIBLE option\
            (/TI, ISO 32000-2, Table 234), counting from zero, and this field\
            has [llength $entries] option(s) - not \"$top\""
      }
    }
    if {$combo && !$editable && ![dict get $options spellcheck]} {
      # Table 233 under DoNotSpellCheck: "shall not be used unless the Combo
      # and Edit flags are both set". There is nothing to spell-check in a
      # field the user cannot type in.
      return -code error -errorcode {TCLPDF FIELD COMBINATION} \
          "tclpdf: -spellcheck 0 needs -editable 1 on $what - ISO 32000-2,\
          Table 233 admits the DoNotSpellCheck flag only where the Combo and\
          Edit flags are both set, and a combo box the user cannot type in\
          has nothing to spell-check. Pass -editable 1, or drop -spellcheck"
    }

    # The two measurements, through the one place that reads a measurement of
    # a field option - see [FieldSize] in field.tcl. Both used to be read
    # here with [string is double], which is true for NaN and for Inf: the
    # pair was taken at the call and died at the WRITE, one of them in Tcl's
    # own words ("can't use non-numeric floating-point value as operand of
    # \"+\"", ARITH DOMAIN) and from inside an appearance stream, which leaves
    # the document unwritable for good (measured 2026-08-27, annot H1).
    set size [my FieldSize [dict get $options size] $what]
    set borderWidth [my FieldBorderWidth [dict get $options borderWidth] $what]
    set colours {color border background}
    if {!$combo} {
      lappend colours highlight
    }
    foreach which $colours {
      if {[dict get $options $which] eq {}} continue
      if {[catch {::tclpdf::color parse [dict get $options $which]} parsed]} {
        return -code error -errorcode [list TCLPDF FIELD COLOUR $which] \
            "tclpdf: -$which of $what is not a colour this package reads:\
            $parsed"
      }
    }
    # The default appearance string is settled at the declaration, not at the
    # write: it names a font resource, a family that does not resolve has to
    # be refused at the call that named it, and the appearance has to be
    # drawn in the very font the /DA names.
    set font [my FieldFont [dict get $options family] \
        [dict get $options style] $size [dict get $options color] $what]

    # AND EVERY WORD THE FIELD WILL SHOW has to be one that font can set.
    # The DISPLAY half of each option is what is drawn (the export half never
    # leaves the file), and a value typed into an editable combo is drawn as
    # it stands. Asked here for the reason field.tcl gives at [FieldSettable]:
    # the refusal from inside an appearance stream at write time cannot be
    # taken back, and it makes the whole document unwritable.
    foreach entry $entries {
      my FieldSettable [lindex $entry 1] $font options $what
    }
    foreach {which text} [list value $free default $defaultFree] {
      my FieldSettable $text $font $which $what
    }

    # THREE OF THESE FLAGS ARE YOUNGER THAN THE FIELD THEY SIT ON. A form
    # field is 1.2 and so is /Ff, but CommitOnSelChange came with 1.5 and
    # MultiSelect and DoNotSpellCheck with 1.4 (ISO 32000-2, Table 233) - so
    # a document pinned to 1.2 used to be given a bit its own header says no
    # reader need understand. The floors come from the one table annot.tcl
    # keeps for keys of this kind; each stands beside the line that sets its
    # bit, so a fourth flag cannot be added without the question being asked.
    set flagNames {}
    foreach {flag flagName} {readonly ReadOnly required Required
        noexport NoExport sort Sort commit CommitOnSelChange} {
      if {[dict get $options $flag]} {
        if {$flagName eq "CommitOnSelChange"} {
          my AnnotKeyVersion CommitOnSelChange
        }
        lappend flagNames $flagName
      }
    }
    if {$combo} {
      lappend flagNames Combo
      if {$editable} {
        lappend flagNames Edit
      }
      if {![dict get $options spellcheck]} {
        my AnnotKeyVersion DoNotSpellCheck
        lappend flagNames DoNotSpellCheck
      }
    } elseif {$multi} {
      my AnnotKeyVersion MultiSelect
      lappend flagNames MultiSelect
    }

    set highlight {}
    if {!$combo} {
      set highlight [dict get $options highlight]
    }
    set data [dict create \
        combo $combo editable $editable multi $multi \
        entries $entries \
        selection $selection free $free \
        defaultSelection $defaultSelection defaultFree $defaultFree \
        top $top \
        align [dict get $options align] \
        da [dict get $font da] \
        size [dict get $font size] \
        family [dict get $font family] style [dict get $font style] \
        color [dict get $font colour] \
        border [dict get $options border] \
        borderWidth $borderWidth \
        background [dict get $options background] \
        highlight $highlight]
    # /I is a 1.4 entry (Table 234), and whether it will be written is
    # settled by the declaration - so it is asked here, through the very
    # predicate the build asks at write time. Two readings of the same
    # condition are two answers waiting to differ.
    if {[my FieldChoiceIndexNeeded $data]} {
      my AnnotKeyVersion I
    }
    my FieldDeclare $name -type Ch -build FieldChoiceBuild \
        -rect [dict get $options rect] -page [dict get $options page] \
        -tooltip [dict get $options tooltip] \
        -contents [dict get $options contents] \
        -label [dict get $options label] \
        -flags [::tclpdf::field flags $flagNames] \
        -font [dict get $font alias] \
        -data $data
    return $name
  }

  # -options into the list of {export display} pairs the rest of the module
  # works with. A one-word entry is an option whose export value IS its
  # displayed text, which is what Table 234 means by a plain text string in
  # the array.
  method FieldChoiceOptions {what value} {
    if {[catch {llength $value} count]} {
      return -code error -errorcode {TCLPDF FIELD OPTIONS} \
          "tclpdf: -options of $what is a Tcl list of the options the field\
          offers, and \"$value\" is not one"
    }
    if {!$count} {
      return -code error -errorcode {TCLPDF FIELD OPTIONS} \
          "tclpdf: $what needs -options with at least one entry - /Opt is\
          what a choice field offers, and ISO 32000-2, Table 234 says of a\
          field without it that \"no choices should be presented to the\
          user\". For a field the user types free text into, use \"field\
          text\""
    }
    set entries {}
    set index 0
    foreach entry $value {
      if {[catch {llength $entry} parts]} {
        set parts 0
      }
      switch -- $parts {
        1 {
          lappend entries [list [lindex $entry 0] [lindex $entry 0]]
        }
        2 {
          lappend entries [list [lindex $entry 0] [lindex $entry 1]]
        }
        default {
          return -code error -errorcode [list TCLPDF FIELD OPTIONS $index] \
              "tclpdf: option $index of $what is \"$entry\", which is\
              [expr {$parts ? "$parts words" : "empty"}] - an entry of /Opt\
              is one option (ISO 32000-2, Table 234): either the text to\
              show, or {export display} with the export value first. A text\
              of several words is one entry in a brace pair of its own, as\
              in -options {{{very good}} good}"
        }
      }
      incr index
    }
    return $entries
  }

  # -index into a checked, ascending, duplicate-free list of positions.
  method FieldChoiceIndices {what entries value} {
    set selection {}
    foreach index $value {
      if {![string is integer -strict $index] || $index < 0
          || $index >= [llength $entries]} {
        return -code error -errorcode [list TCLPDF FIELD INDEX $index] \
            "tclpdf: -index of $what counts the options from zero and this\
            field has [llength $entries] of them - \"$index\" names none.\
            /I holds \"the zero-based indices in the Opt array\" (ISO\
            32000-2, Table 234)"
      }
      if {$index ni $selection} {
        lappend selection $index
      }
    }
    # "sorted in ascending order" (Table 234), and the sort is numeric: -integer
    # rather than the string order, in which 10 comes before 2.
    return [lsort -integer $selection]
  }

  # One selection specification into {indices freeText}. The caller names an
  # option by its EXPORT value, which is the option's identity, or by its
  # displayed text where the two differ and he has only the second.
  #
  # An editable combo box is the one field that takes a value its options do
  # not offer - that is what the Edit flag is for - so there, and only there,
  # an unmatched value becomes the value itself.
  #
  # ONE VALUE, unless the field takes several. A field that holds one
  # selection is given one, whole - "very good" is an option named "very
  # good" and not two options named "very" and "good" - and only a
  # -multi list box reads its -value as a list. Which is the same trap
  # -options has, decided the same way: nothing is split that cannot hold
  # more than one thing.
  method FieldChoiceSelect {what entries option value editable multi} {
    if {$value eq {}} {
      return [list {} {}]
    }
    if {!$multi} {
      set value [list $value]
    }
    set selection {}
    foreach wanted $value {
      set found {}
      foreach column {0 1} {
        set index 0
        foreach entry $entries {
          if {[lindex $entry $column] eq $wanted} {
            lappend found $index
          }
          incr index
        }
        if {[llength $found]} break
      }
      if {![llength $found]} {
        if {$editable} {
          # A value of its own. An editable combo box is never a multiple
          # selection - the Edit flag is a combo flag and MultiSelect a list
          # box one - so this is the whole value.
          return [list {} $wanted]
        }
        return -code error -errorcode [list TCLPDF FIELD SELECT $option] \
            "tclpdf: $option of $what is \"$wanted\", and the field offers\
            [my FieldChoiceNames $entries]. Name an option by its export\
            value or by the text it shows. A value outside the list needs\
            an editable combo box (\"field combo ... -editable 1\", the Edit\
            flag of ISO 32000-2, Table 233)"
      }
      if {[llength $found] > 1} {
        # Two options under one word. Which of them was meant is a question
        # only the caller can answer, and -index is where he answers it.
        return -code error -errorcode [list TCLPDF FIELD SELECT $option] \
            "tclpdf: $option of $what is \"$wanted\" and [llength $found]\
            options answer to it (at [join $found {, }]) - so the field\
            dictionary could not say which one is selected either. Name the\
            option by its position with -index"
      }
      set index [lindex $found 0]
      if {$index ni $selection} {
        lappend selection $index
      }
    }
    return [list [lsort -integer $selection] {}]
  }

  # The options, for a refusal. Both halves where they differ, because a
  # caller who named one of them needs to see which of the two he wrote.
  method FieldChoiceNames {entries} {
    set names {}
    foreach entry $entries {
      lassign $entry export display
      if {$export eq $display} {
        lappend names "\"$export\""
      } else {
        lappend names "\"$export\" (\"$display\")"
      }
    }
    return [join $names {, }]
  }

  # The pairs of ONE choice field, at write time. Point 4 of the contract:
  # what is the type's own and nothing the core writes.
  method FieldChoiceBuild {name record} {
    set data [dict get $record data]
    set entries [dict get $data entries]
    set pairs [list FT /Ch DA [my Str [dict get $data da]]]
    if {[dict get $data align] ne "left"} {
      # /Q 0 is the default and is left out where it applies (Table 228).
      lappend pairs Q [expr {[dict get $data align] eq "center" ? 1 : 2}]
    }
    lappend pairs Opt [::tclpdf::pdfObj arr [lmap entry $entries {
      lassign $entry export display
      if {$export eq $display} {
        # "a text string representing one of the available options" - the
        # short form, for an option whose export value is what it shows.
        # Writing {x x} instead would say the same thing twice.
        my Str $display
      } else {
        ::tclpdf::pdfObj arr [list [my Str $export] [my Str $display]]
      }
    }]]
    foreach {key which free} {V selection free DV defaultSelection defaultFree} {
      set value [my FieldChoiceValueObject $data [dict get $data $which] \
          [dict get $data $free]]
      if {$value eq {}} continue
      lappend pairs $key $value
    }
    # /I, and only where it says something /V cannot - see the head of this
    # file. The indices belong to the VALUE, so they are written for /V and
    # have no counterpart for /DV: Table 234 knows no default index.
    if {[my FieldChoiceIndexNeeded $data]} {
      lappend pairs I [::tclpdf::pdfObj arr [dict get $data selection]]
    }
    if {[dict get $data top] > 0} {
      # /TI, "the top index (the index in the Opt array of the first option
      # visible in the list)", default 0 (Table 234) - so a zero is left out.
      lappend pairs TI [dict get $data top]
    }
    lappend pairs {*}[my FieldBorderEntries $data]
    lappend pairs AP [::tclpdf::pdfObj dictionary [list \
        N [my FieldAppearanceStream $record N {my FieldChoicePaint $record}]]]
    return $pairs
  }

  # /V or /DV: a text string for one selection, an array of them for
  # several, and nothing at all where nothing is selected - "The default
  # value of V is null" (12.7.5.4), and a key holding its own default is a
  # key to leave out.
  method FieldChoiceValueObject {data selection free} {
    if {$free ne {}} {
      return [my Str $free]
    }
    if {![llength $selection]} {
      return {}
    }
    set texts [lmap index $selection {
      lindex [dict get $data entries] $index 1
    }]
    if {[llength $texts] == 1} {
      return [my Str [lindex $texts 0]]
    }
    return [::tclpdf::pdfObj arr [lmap text $texts {my Str $text}]]
  }

  # Does /V leave the selection open? It does as soon as two options SHOW
  # the same text: /V holds that text and names both of them. Then /I is the
  # only entry that says which one is selected.
  # WILL THIS FIELD CARRY /I? Asked twice and answered once: at the
  # declaration, where the 1.4 floor of the key has to be required while the
  # call can still be refused, and at the write, where the key is put in.
  method FieldChoiceIndexNeeded {data} {
    return [expr {[llength [dict get $data selection]]
        && ([dict get $data multi] || [my FieldChoiceAmbiguous $data])}]
  }

  method FieldChoiceAmbiguous {data} {
    set seen {}
    foreach entry [dict get $data entries] {
      set display [lindex $entry 1]
      if {[dict exists $seen $display]} {
        return 1
      }
      dict set seen $display 1
    }
    return 0
  }

  # What the field SHOWS. Point 5 of the contract: {0 0} is the top left
  # corner of the widget, y downwards, in the document unit.
  method FieldChoicePaint {record} {
    set data [dict get $record data]
    lassign [dict get $record extent] width height
    set borderWidth [dict get $data borderWidth]
    set hasBorder [expr {[dict get $data border] ne {} && $borderWidth > 0}]

    # Background and frame first and OUTSIDE the /Tx bracket: a reader that
    # sets a new value replaces the stream from /Tx BMC to the matching EMC
    # (12.7.4.3), and the frame is not the value.
    if {[dict get $data background] ne {}} {
      my rect -at {0 0} -size [list $width $height] \
          -fill [dict get $data background]
    }
    if {$hasBorder} {
      # Inset by half the line width, so the stroke lands inside the /BBox
      # rather than half outside it.
      set half [expr {$borderWidth / 2.0}]
      my rect -at [list $half $half] \
          -size [list [expr {$width - $borderWidth}] \
              [expr {$height - $borderWidth}]] \
          -stroke [dict get $data border] -width $borderWidth
    }

    set padding [expr {$borderWidth
        + [::tclpdf::geometry fromPoints 1 [my cget -unit]]}]
    set inner [expr {$width - 2 * $padding}]
    set space [expr {$height - 2 * $padding}]
    if {$inner <= 0 || $space <= 0} {
      # A field too small to hold anything between its own frames. Nothing is
      # drawn rather than something the /BBox would clip away with nothing to
      # say it happened.
      return
    }

    # The bracket is written even where nothing is selected. An empty list
    # box is the usual state of a blank form, and a reader that fills it in
    # replaces what stands between the marks - which it can only do if the
    # marks are there (12.7.4.3: without them "the new contents shall be
    # appended to the end of the original stream").
    my content "/Tx BMC\n"
    my save
    my clip -at [list $padding $padding] -size [list $inner $space]
    # EVERY value is named, none inherited: this runs at write time, where
    # the document's text state is whatever the last [font] call left behind.
    set size [dict get $data size]
    set font [list -size $size -family [dict get $data family] \
        -style [dict get $data style] -color [dict get $data color]]
    if {[dict get $data combo]} {
      my FieldChoicePaintLine $data $padding $inner $width $height $font
    } else {
      my FieldChoicePaintRows $data $padding $inner $width $space $font
    }
    my restore
    my content "EMC\n"
    return
  }

  # A combo box shows ONE line - the selected option, or the text of an
  # editable one - vertically centred, as a reader draws a closed drop-down.
  # The arrow beside it is the reader's own furniture and is not in the
  # appearance stream.
  method FieldChoicePaintLine {data padding inner width height font} {
    set text [dict get $data free]
    if {$text eq {} && [llength [dict get $data selection]]} {
      set text [lindex [dict get $data entries] \
          [lindex [dict get $data selection] 0] 1]
    }
    if {$text eq {}} {
      return
    }
    set sizeUnit [::tclpdf::geometry fromPoints [dict get $data size] \
        [my cget -unit]]
    # The letters as a box one font size tall - close enough for a widget a
    # reader will re-centre by its own rule the moment the field is used.
    set top [expr {($height - $sizeUnit) / 2.0}]
    if {$top < $padding} {
      set top $padding
    }
    my text $text -at [list [my FieldChoiceX $data $padding $width] $top] \
        -anchor top -align [dict get $data align] {*}$font
    return
  }

  # A list box shows its options from /TI downwards, one row each, with the
  # selected ones on a coloured bar. The bar is drawn INSIDE the bracket: it
  # marks the value, and a reader replacing the value has to take it with it.
  method FieldChoicePaintRows {data padding inner width space font} {
    set sizeUnit [::tclpdf::geometry fromPoints [dict get $data size] \
        [my cget -unit]]
    # One row is 1.2 times the font size - the leading this package uses for
    # a line of text everywhere else, so a list box and a paragraph in the
    # same document are set on the same rhythm.
    set line [expr {$sizeUnit * 1.2}]
    set entries [dict get $data entries]
    set selection [dict get $data selection]
    set x [my FieldChoiceX $data $padding $width]
    set y $padding
    set limit [expr {$padding + $space}]
    for {set index [dict get $data top]} {$index < [llength $entries]} {incr index} {
      if {$y >= $limit} break
      if {$index in $selection && [dict get $data highlight] ne {}} {
        my rect -at [list $padding $y] -size [list $inner $line] \
            -fill [dict get $data highlight]
      }
      my text [lindex $entries $index 1] -at [list $x $y] -anchor top \
          -align [dict get $data align] {*}$font
      set y [expr {$y + $line}]
    }
    return
  }

  # Where a row starts, for the three values of /Q.
  method FieldChoiceX {data padding width} {
    switch -- [dict get $data align] {
      center {return [expr {$width / 2.0}]}
      right {return [expr {$width - $padding}]}
    }
    return $padding
  }
}

package provide tclpdf::fieldChoice 1.2
