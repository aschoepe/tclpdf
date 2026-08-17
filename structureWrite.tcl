#
# tclpdf - PDF generation for Tcl
#
# structureWrite - the structure tree turned into objects at write time
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# The second half of what structure.tcl describes: the tree that was built
# while the document was drawn becomes StructElem objects, the ParentTree
# and the StructTreeRoot, and the structure destinations reserved by
# structureDest.tcl are filled in now that every element has its number.
# Nothing here changes the tree; it reads what structure.tcl recorded.
#
# Split off from structure.tcl because it is a topic of its own: building
# the tree during drawing and writing it out are two different jobs, and the
# writer is the one that runs on the beforeWrite event and nowhere else.
# The two private helpers below are here because only the writer asks them
# anything - measured, not assumed.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::document 1.0-
package require tclpdf::structure 1.1-

oo::define ::tclpdf::document::document {

  # Runs on the beforeWrite event, so on EVERY write - the numbers therefore
  # come from [reservation] and survive a rebuild, which is the contract
  # documented in event.tcl.
  method StructureWrite {} {
    if {![my tagged]} {
      return
    }
    set writer [my writer]
    set elements [my state structure]
    set rootNumber [my reservation structure.root]
    # Exactly one Document element below the root - TS 32005 Table 5 gives it
    # occurrence 1, not 0..n. Creating it here rather than asking for it means
    # a document that only ever derived its tags still gets a well formed
    # tree.
    set documentNumber [my reservation structure.document]
    set treeNumber [my reservation structure.parenttree]

    set index 0
    foreach element $elements {
      dict set element number [my reservation structure.$index]
      lset elements $index $element
      incr index
    }

    # Page -> array of element references, indexed by MCID. Only the elements
    # know which marks they own, so it is collected by walking them.
    set parents {}
    foreach element $elements {
      foreach kid [dict get $element kids] {
        if {[lindex $kid 0] ne "mark"} {
          continue
        }
        lassign $kid . page mcid
        set entry [expr {[dict exists $parents $page] ?
            [dict get $parents $page] : {}}]
        while {[llength $entry] <= $mcid} {
          lappend entry {}
        }
        lset entry $mcid [$writer ref [dict get $element number]]
        dict set parents $page $entry
      }
    }

    # {} unless a 2.0 claim put one there - see the NS key below.
    set namespace [my state uaNamespace]
    variable ::tclpdf::structure::only17

    set index 0
    set topLevel {}
    foreach element $elements {
      set parent [dict get $element parent]
      if {$parent eq {}} {
        lappend topLevel $index
      }
      # Pg names the page the MCIDs are counted in, and [StructurePage]
      # answers it only when every mark sits on ONE page. An element whose
      # marks span pages - a paragraph carried over a page break by [text
      # -paginate] - has no Pg, and then a bare number would name nothing:
      # each mark goes in as a marked-content reference naming its own page
      # (14.7.4.2, Table 324).
      set elementPage [my StructurePage $element]
      set kids {}
      foreach kid [dict get $element kids] {
        switch -- [lindex $kid 0] {
          element {
            lappend kids [$writer ref \
                [dict get [lindex $elements [lindex $kid 1]] number]]
          }
          mark {
            lassign $kid . markPage mcid
            if {$markPage eq $elementPage} {
              lappend kids [::tclpdf::pdfObj num $mcid]
            } else {
              lappend kids [::tclpdf::pdfObj dictionary [list \
                  Type /MCR Pg [$writer ref [dict get [my Page $markPage] number]] \
                  MCID [::tclpdf::pdfObj num $mcid]]]
            }
          }
          objr {
            # Pg is written on EVERY object reference rather than only where
            # the element's own Pg differs: always naming it is unambiguous
            # and permitted, and it spares a reader the comparison.
            lassign $kid . number page
            lappend kids [::tclpdf::pdfObj dictionary [list \
                Type /OBJR Obj [$writer ref $number] \
                Pg [$writer ref [dict get [my Page $page] number]]]]
          }
        }
      }
      set pairs [list Type /StructElem S /[dict get $element type] \
          P [expr {$parent eq {} ? [$writer ref $documentNumber] :
              [$writer ref [dict get [lindex $elements $parent] number]]}]]
      # The namespace an element's type is read in. Empty on the 1.7 path,
      # where the default namespace IS the 1.7 one and naming it would be
      # noise; set by ua.tcl for part 2, where relying on the default is no
      # longer allowed (UA-2 8.2.5.2).
      #
      # The twelve 1.7-only types are the exception and keep the default:
      # naming the 2.0 namespace on a type that does not exist in it would
      # be a claim about nothing.
      if {$namespace ne {} && [dict get $element type] ni $only17} {
        lappend pairs NS $namespace
      }
      # Pg is required as soon as the element owns marks - without it a
      # reader cannot resolve them.
      if {$elementPage ne {}} {
        lappend pairs Pg [$writer ref [dict get [my Page $elementPage] number]]
      }
      if {[llength $kids] == 1} {
        lappend pairs K [lindex $kids 0]
      } elseif {[llength $kids]} {
        lappend pairs K [::tclpdf::pdfObj arr $kids]
      }
      # E is the expanded form of an abbreviation (14.9.5, Table 323) - a text
      # string like Alt, so it is written the same way.
      foreach {key option} {Alt alt Lang lang T title ActualText actualText
          E expansion} {
        if {[dict get $element $option] ne {}} {
          lappend pairs $key [::tclpdf::pdfObj str [dict get $element $option]]
        }
      }
      # One owner gives a single dictionary, several give an array of them
      # (14.8.5). Written inline rather than as an indirect object: an
      # attribute dictionary is small, and one per cell as its own object
      # would double the object count of a table for nothing.
      set attributes {}
      dict for {owner values} [dict get $element attributes] {
        lappend attributes [::tclpdf::pdfObj dictionary [list O /$owner {*}$values]]
      }
      if {[llength $attributes] == 1} {
        lappend pairs A [lindex $attributes 0]
      } elseif {[llength $attributes]} {
        lappend pairs A [::tclpdf::pdfObj arr $attributes]
      }
      $writer put [dict get $element number] [::tclpdf::pdfObj dictionary $pairs]
      incr index
    }

    set documentKids {}
    foreach top $topLevel {
      lappend documentKids [$writer ref \
          [dict get [lindex $elements $top] number]]
    }
    set documentPairs [list Type /StructElem S /Document \
        P [$writer ref $rootNumber] K [::tclpdf::pdfObj arr $documentKids]]
    if {$namespace ne {}} {
      lappend documentPairs NS $namespace
    }
    $writer put $documentNumber [::tclpdf::pdfObj dictionary $documentPairs]

    # The ParentTree is a number tree (7.9.7): Nums pairs each key with its
    # value, in ascending key order.
    #
    # Two kinds of entry share it. A page's key holds an ARRAY, indexed by
    # MCID; an annotation's key holds the element itself, with no array
    # around it. Annotation keys are counted on past the pages, so both fit
    # in one ascending sequence.
    set annotations [my state structureAnnots]
    # The pages start where the annotations end - see [StructureAnnotation]
    # for why it is that way round and not the obvious one.
    set offset [llength $annotations]
    set entries {}
    foreach page [dict keys $parents] {
      dict set entries [expr {$offset + $page}] [::tclpdf::pdfObj arr \
          [lmap ref [dict get $parents $page] {
            expr {$ref eq {} ? "null" : $ref}
          }]]
    }
    foreach annotation $annotations {
      lassign $annotation element . key
      dict set entries $key [$writer ref \
          [dict get [lindex $elements $element] number]]
    }
    set nums {}
    foreach key [lsort -integer [dict keys $entries]] {
      lappend nums [::tclpdf::pdfObj num $key]
      lappend nums [dict get $entries $key]
    }
    $writer put $treeNumber [::tclpdf::pdfObj dictionary [list \
        Nums [::tclpdf::pdfObj arr $nums]]]

    set rootPairs [list Type /StructTreeRoot \
        K [$writer ref $documentNumber] \
        ParentTree [$writer ref $treeNumber] \
        ParentTreeNextKey [expr {[my page count] + [llength $annotations]}]]
    if {$namespace ne {}} {
      lappend rootPairs Namespaces [::tclpdf::pdfObj arr [list $namespace]]
    }
    $writer put $rootNumber [::tclpdf::pdfObj dictionary $rootPairs]

    # The destination objects, now that every element has its number. A
    # structure destination is the element itself where a page destination
    # would name a page (12.3.2.3) - a reader then scrolls to the CONTENT
    # rather than to a coordinate that may have moved.
    #
    # Two objects per name, because the action that carries them (see
    # [structureDestination]) names both: /SD, the element, and /D, a page
    # destination to where the element BEGINS, for a reader that does not
    # understand structure destinations (12.3.2.3 recommends the pair). /XYZ
    # with the top of the first content and no zoom, when the mark recorded
    # a position; /Fit on that page when it did not - a position that is not
    # known is not invented.
    dict for {name numbers} [my state structureDestinations] {
      if {![dict exists [my state structureNames] $name]} {
        return -code error "tclpdf: no structure element is named \"$name\" -\
            a link or a bookmark points at it. Name one with\
            \[\$doc structure <type> -name $name ...\]"
      }
      set target [dict get [my state structureNames] $name]
      $writer put [dict get $numbers sd] [::tclpdf::pdfObj arr [list \
          [$writer ref [dict get [lindex $elements $target] number]] /Fit]]
      lassign [my StructureFirstPosition $elements $target] page y
      if {$page eq {}} {
        set page 0
      }
      set pageRef [$writer ref [dict get [my Page $page] number]]
      $writer put [dict get $numbers d] [::tclpdf::pdfObj arr [expr {$y eq {} ?
          [list $pageRef /Fit] :
          [list $pageRef /XYZ null [::tclpdf::pdfObj num $y] null]}]]
    }

    my catalogEntry StructTreeRoot [$writer ref $rootNumber]
    # Marked says the file follows 14.7; Suspects false says nobody has
    # flagged the tree as doubtful. UA-1 clause 7.1 wants both.
    my catalogEntry MarkInfo [::tclpdf::pdfObj dictionary \
        [list Marked true Suspects false]]
    # The page carries its index into the ParentTree. Handed over through the
    # scratch state, the way link annotations already reach WritePage, so
    # output.tcl stays free of this topic.
    set structParents {}
    foreach page [dict keys $parents] {
      dict set structParents $page [expr {$offset + $page}]
    }
    my state structParents $structParents
    return
  }

  # The page an element's marks sit on, or {} when it owns none or they span
  # several. The norm allows leaving Pg out then, because each mark's page is
  # reachable through the ParentTree anyway.
  method StructurePage {element} {
    set pages {}
    foreach kid [dict get $element kids] {
      if {[lindex $kid 0] eq "mark"} {
        lappend pages [lindex $kid 1]
      }
    }
    set pages [lsort -unique -integer $pages]
    if {[llength $pages] == 1} {
      return [lindex $pages 0]
    }
    return {}
  }

  # Where an element BEGINS, as {page y} - the place the /D half of a
  # structure destination sends a reader. y is the top of the first content
  # in PDF space, or {} when the mark that begins the element recorded no
  # position. Not [StructurePage]: that answers "the one page all marks sit
  # on" and says nothing for an element that spans two, while here the FIRST
  # place is wanted, and every element has one.
  #
  # The kids are walked in document order: the first mark or annotation (an
  # OBJR carries its page and no position) decides, and a child element that
  # owns neither is asked the same question in turn - a Sect that holds only
  # a P begins where the P begins. An element with no content anywhere below
  # it has no place of its own; page 0 is the answer then, because a
  # destination has to name SOME page and the first is the one a reader can
  # least be misled by.
  method StructureFirstPosition {elements index} {
    foreach kid [dict get [lindex $elements $index] kids] {
      switch -- [lindex $kid 0] {
        mark {
          return [list [lindex $kid 1] [lindex $kid 3]]
        }
        objr {
          return [list [lindex $kid 2] {}]
        }
        element {
          set found [my StructureFirstPosition $elements [lindex $kid 1]]
          if {$found ne {}} {
            return $found
          }
        }
      }
    }
    return {}
  }

}

package provide tclpdf::structureWrite 1.0
