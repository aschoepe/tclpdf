#
# tclpdf - PDF generation for Tcl
#
# import - a page of an existing PDF, taken over as a form XObject (Etappe 7)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# Usage:
#
#   $doc pdf import letterhead briefbogen.pdf
#   $doc pdf import annex report.pdf -page 3
#   $doc form place letterhead -at {0 0}
#   $doc form place annex -at {20 40} -scale 0.4
#
# The named page becomes a form under the same contract as [form create]:
# placed with [form place], as often as wanted, scaled and rotated, stored
# once in the file. Taking over a letterhead is [pdf import] once and
# [form place] on every page.
#
# WHAT IS READ. Both cross-reference flavours of ISO 32000: the classic
# table (7.5.4) and, since PDF 1.5, cross-reference streams (7.5.8) with
# object streams (7.5.7) - measured on a stock of real invoices, 29 of 32
# use the stream flavour, so a reader without it would refuse most files
# that arrive in practice. Hybrid files (7.5.8.4) are read through their
# XRefStm entry. Incremental updates are followed over /Prev, newest
# section first, as the standard prescribes.
#
# WHAT IS REFUSED, by name: encrypted files (no decryption in this
# package - see the encryption stage of the roadmap), content streams in a
# filter this package cannot decode (the resources are exempt, see below),
# and files whose cross-reference is broken. Refusing beats guessing: an
# imported letterhead that is silently wrong reaches the recipient.
#
# HOW THE TAKEOVER WORKS. Everything reachable from the page's /Resources
# is copied object by object, renumbered through this document's writer.
# The copy is done on PARSED objects - a real tokenizer, not a text
# substitution - so a literal string that happens to contain "5 0 R" stays
# untouched. Streams among the copied objects (fonts, images, ICC
# profiles) keep their bytes and their /Filter exactly as they were: the
# import never decodes what it does not have to, which is also why exotic
# image filters are no obstacle. Only the CONTENT streams are decoded -
# they have to become one stream to live in a form XObject, and their
# operators end up behind this document's own compression.
#
# The page's boxes travel along: the form's BBox is the CropBox where one
# exists - intersected with the MediaBox, which bounds it (14.11.2.2) -
# the MediaBox otherwise, and a /Rotate of 90, 180 or 270 becomes
# the form's /Matrix, so the placed page looks the way a viewer shows it.
# A /Properties resource (optional content, "layers") gets its catalog
# counterpart via /OCProperties, or a validator reports an OCG without a
# configuration.
#
# The parser below is deliberately independent of the document object -
# plain procs over a byte string - so the tests can feed it handcrafted
# files without a document around it.

package require Tcl 8.6.11-
package require tclpdf::importRead 1.0-
package require tclpdf::pdfFunction 1.0-
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::document 1.0-

oo::define ::tclpdf::document::document {

  # $doc pdf import <alias> <path> ?-page n?
  method pdf {subcommand args} {
    switch -- $subcommand {
      import {return [my PdfImport {*}$args]}
      default {
        return -code error -errorcode [list TCLPDF IMPORT SUBCOMMAND $subcommand] \
            "tclpdf: unknown pdf subcommand \"$subcommand\" -\
            known is: import"
      }
    }
  }

  method PdfImport {alias path args} {
    set options [::tclpdf::option parse {page 1} $args "pdf import"]
    set page [dict get $options page]
    if {![string is entier -strict $page] || $page < 1} {
      return -code error -errorcode [list TCLPDF IMPORT ARGUMENT page] \
          "tclpdf: -page of pdf import is a page number\
          counted from 1, not \"$page\""
    }
    set forms [my state forms]
    if {[dict exists $forms $alias]} {
      return -code error -errorcode [list TCLPDF IMPORT NAME $alias] \
          "tclpdf: a form named \"$alias\" already exists"
    }
    # A missing path, a directory, an unreadable file: the reader refuses
    # them at its entry, in this package's words (importRead.tcl, Open).
    set reader [::tclpdf::importRead::Open $path]
    set pageDict [::tclpdf::importRead::Page reader $page]

    # The box that becomes the form, the rotation and the extent both
    # produce: [Geometry] answers all three, and it is the same answer
    # [::tclpdf::pdf pages] reports about every page of a file - see there
    # for why the reasoning lives in one place.
    set geometry [::tclpdf::importRead::Geometry reader $pageDict $page]
    lassign [dict get $geometry box] x0 y0 x1 y1
    set rotate [dict get $geometry rotate]
    set width [dict get $geometry width]
    set height [dict get $geometry height]

    # NOTHING IS WRITTEN UNTIL EVERYTHING THAT COULD BE REFUSED IS READ.
    # The last refusal on this road - a content stream in a filter this
    # package cannot decode - used to fall AFTER the copied objects were in
    # the writer and after /OCProperties was in the catalogue, so a caught
    # [pdf import] left the document carrying the layers and the orphaned
    # resources of a page it never got (measured 2026-08-22). It is the
    # check-before-write pattern of the earlier review rounds one layer
    # further out, and here it costs nothing but the order of two blocks:
    # the reader may say no as often as it likes, the document does not
    # change before it has said yes.

    # The page's resources, and the /Properties behind them resolved: the
    # optional-content work further down wants them, and so does the
    # marked-content walk two blocks below - which of the named property
    # lists carry an /MCID is a question only the reader can answer.
    set resources [::tclpdf::importRead::Get $pageDict Resources]
    set resolved [::tclpdf::importRead::Resolve reader $resources]
    set properties [::tclpdf::importRead::Resolve reader \
        [::tclpdf::importRead::Get $resolved Properties]]
    set marked {}
    if {[lindex $properties 0] eq "d"} {
      foreach {name item} [lindex $properties 1] {
        if {[::tclpdf::importRead::Get \
            [::tclpdf::importRead::Resolve reader $item] MCID] ne {}} {
          lappend marked /$name
        }
      }
    }

    # The content: one stream or an array of streams whose CONCATENATION
    # is the page description (7.8.2) - decoded, joined, and stored behind
    # this document's own compression.
    set contents [::tclpdf::importRead::Resolve reader \
        [::tclpdf::importRead::Get $pageDict Contents]]
    set pieces {}
    if {[lindex $contents 0] eq "a"} {
      set list [lindex $contents 1]
    } elseif {$contents eq {}} {
      set list {}
    } else {
      set list [list [::tclpdf::importRead::Get $pageDict Contents]]
    }
    foreach item $list {
      # A member of the array that is the null object contributes nothing:
      # "Specifying the null object as the value of a dictionary entry shall
      # be equivalent to omitting the entry entirely" (7.3.9), and 7.3.10
      # makes a reference to an object the file does not define exactly that
      # object. A page whose /Contents names a freed object is an EMPTY
      # page, not a refusal - /Contents is optional (Table 31).
      if {[lindex $item 0] ne "r"} continue
      set number [lindex [lindex $item 1] 0]
      lassign [::tclpdf::importRead::Object reader $number] value hasStream data
      if {!$hasStream} {
        return -code error -errorcode [list TCLPDF IMPORT FOREIGN $number] \
            "tclpdf: $path: content object $number is not a\
            stream"
      }
      lappend pieces [::tclpdf::importRead::DecodeStream reader $value $data \
          "the content stream"]
    }
    # THE FOREIGN PAGE'S STRUCTURE MARKS COME OUT. A tagged page carries
    # /P <</MCID 0>> BDC ... EMC brackets whose numbers point into the
    # structure tree of the file they came from; that tree does not travel,
    # and 14.7.4.2 makes a marked-content sequence inside a form XObject a
    # content item only through the XObject's own /StructParents. Left
    # standing they are marks pointing at nothing, inside the artifact or
    # Figure bracket the placement puts around them (14.8.2.2, Matterhorn
    # 01-005) - a reader that takes them seriously reads out paragraphs that
    # belong to no tree. Measured 2026-08-26 on an imported 05.07-accessible:
    # "form XObject /PI1 contains MCIDs [0..29] (needs its own
    # /StructParents; has None)".
    #
    # AND THE /Artifact BRACKETS WITH THEM, for the reason [Unmark] spells
    # out: "this is not content" is a sentence about the STRUCTURE TREE of
    # the file the page came from, and that tree does not travel. What the
    # page is HERE is said by the placement - an artifact under [form place
    # -artifact 1], a Figure under -alt - and an /Artifact bracket left
    # standing inside a Figure is content marked as artifact inside tagged
    # content, which ISO 14289-1, 7.1 forbids and veraPDF names (7.1-1,
    # 7.1-2). An /OC bracket switches a layer and stays; a /Span with a
    # /Lang says something about the content and stays.
    #
    # Always, not only in a tagged document: which of the two the caller
    # declares can come after the import ([ua 1] does it), the stripped
    # stream renders identically, and one behaviour is cheaper to explain
    # than two.
    set content [::tclpdf::importRead::Unmark [join $pieces \n] $marked]

    # Everything the page's resources reach, READ: object by object, the
    # closure over the references. The content streams are not part of it -
    # they are the block above, decoded and merged into the form rather than
    # copied. Every object of the closure is read here and kept, because
    # reading is where the reader refuses: a resource in an object stream
    # that is not there, a broken cross-reference entry, a value nested
    # deeper than the parser follows. Not one of those may leave a reserved
    # object number behind - an object reserved and never filled makes the
    # WRITE fail, for a document that could otherwise still be written.
    # WALKED AS {number generation} PAIRS, because that is what a reference
    # is (7.3.10). A reference whose generation the file does not have at
    # that number - a generation of its own, a free entry, no entry at all -
    # names the NULL OBJECT and reaches nothing; the reader answers those
    # with a null value ([Object] with a generation), and they are collected
    # apart, so that a page naming both "4 0 R" and "4 1 R" copies the one
    # object it has and writes null for the other. Keyed on the number the
    # copy is not: a file has one live generation per number, and it is that
    # object which is copied.
    set queue [::tclpdf::importRead::RefPairs $resources]
    set order {}
    set copies {}
    set dead {}
    set walked {}
    while {[llength $queue]} {
      set queue [lassign $queue pair]
      if {[dict exists $walked $pair]} continue
      dict set walked $pair 1
      lassign $pair number generation
      lassign [::tclpdf::importRead::Object reader $number $generation] \
          value hasStream data
      if {[lindex $value 0] eq "z"} {
        dict set dead $pair 1
        continue
      }
      if {[dict exists $copies $number]} continue
      dict set copies $number [list $value $hasStream $data]
      lappend order $number
      lappend queue {*}[::tclpdf::importRead::RefPairs $value]
    }

    # Which of the foreign optional content groups start out switched off,
    # read while the reader is still the only thing being asked; the numbers
    # they get in THIS document are known further down.
    lassign [my ImportLayerStates reader] baseVisible foreignStates

    # The page's own resources dictionary, where it stands DIRECT on the page
    # rather than as an object of the closure: its strings go through the
    # document's seam here, with everything else that is still allowed to
    # refuse, because the object it is written as is added further down among
    # numbers that are already handed out. A reference is left as it is -
    # [ImportStrings] hands back what it cannot be asked about.
    set resourceStrings [my ImportStrings $resources]

    # EVERY QUESTION THE CLOSURE CAN STILL SAY NO TO, ASKED OVER THE WHOLE
    # CLOSURE AND BEFORE THE FIRST OBJECT NUMBER IS HANDED OUT.
    #
    # This used to be one loop with the numbering below: strings checked,
    # filter checked, number reserved, next object. That reads as if it were
    # the check-before-write order and it is not - for object k the objects
    # 1..k-1 are already reserved when k refuses, and a reservation that is
    # never filled makes the WHOLE document unwritable ("object(s) reserved
    # but never written" at the next [write]), for a caller who caught the
    # refusal and carried on. Round 6 measured the case with the refusing
    # object FIRST, where the loop happens to be right, and closed it;
    # round 7 measured it in the middle of a two-resource page and found it
    # open (2026-08-26, a form XObject carrying /Foo <4G> behind another one,
    # and the same page with the second resource deflated into a -version 1.1
    # document). So the two refusals get a pass of their own.
    #
    #   [ImportStrings]  the last refusal of the reading side - a hexadecimal
    #                    string of the foreign file holding something that is
    #                    not a hexadecimal digit (7.3.4.3). It does not need
    #                    the map, so it can be settled here; only the
    #                    serialization needs it, and that stays below
    #   [requireFilter]  the writer's, and it stays the writer's - a
    #                    FlateDecode resource may not land in a file whose
    #                    header disowns the filter. Asked here rather than
    #                    reached through [stream], which runs after every
    #                    number has been handed out
    set writer [my writer]
    # WHAT THE SOURCE FILE CLAIMS FOR ITSELF, CLAIMED BY THE COPY. The
    # header names the version a file conforms to (7.5.2) and the
    # catalogue's /Version raises it from PDF 1.4 on (7.5.5); everything on
    # the page is written under that claim, and the copy carries it along
    # unread - the objects travel with their bytes untouched, so not one of
    # the version bindings the rest of this package sets sees them. A 1.4
    # document used to take over a page with /BitsPerComponent 16 (PDF 1.5,
    # Table 89) and write %PDF-1.4 over it, against the promise that every
    # feature is checked against the version before it is written.
    #
    # Entered as a FLOOR, in the words of every other feature of this
    # package: the document is not raised behind the caller's back - whoever
    # said -version 1.4 said what the file may contain - so a source that
    # needs more is refused by name, and the message names the version to
    # create the document with. A version this package has no name for (a
    # header saying 1.8, which no standard defines) is passed over rather
    # than turned into a refusal nobody can answer.
    set claimed [::tclpdf::importRead::Version reader]
    if {$claimed in {1.0 1.1 1.2 1.3 1.4 1.5 1.6 1.7 2.0}} {
      my RequireVersion $claimed "the page imported from\
          \"[file tail $path]\", which is written as PDF $claimed"
    }
    set strings {}
    foreach number $order {
      lassign [dict get $copies $number] value hasStream
      dict set strings $number [my ImportStrings $value]
      if {$hasStream} {
        $writer requireFilter [my ImportStreamFilters reader $value]
      }
    }

    # -- from here on the document changes --------------------------------
    #
    # [Refs] walked every value above and refused what it could not walk, so
    # the numbering below cannot run into a value the reading did not already
    # accept, and the pass above has asked the two questions that were left.
    #
    # WHAT CAN BE SHARED RATHER THAN COPIED is decided first, because a
    # shared object is written whole and needs no number of its own - see
    # [ImportShare]. What is left over gets its number here, all of them
    # before the first body is written, since a body may refer to an object
    # further down the list.
    set context [dict create copies $copies strings $strings map {} \
        shared {} plain {} visiting {} dead $dead]
    foreach number $order {
      my ImportShare $number context
    }
    set map [dict get $context map]
    foreach number $order {
      if {[dict exists $map $number]} continue
      # {number generation} - and the generation is 0, ALWAYS. The map is
      # what [importRead::Serialize] renumbers references through, and this
      # document writes every copied object as "N 0 obj" whatever generation
      # it stood at in the file it came from. Its short form (a bare number)
      # means "keep the reference's own generation", which is what an update
      # writing into a file's own numbering wants and what a copy must not
      # have: a resource that was "7 3 obj" over there is "42 0 obj" here.
      dict set map $number [list [$writer reserve] 0]
    }
    # AND ONE OBJECT FOR EVERY REFERENCE THAT REACHES NOTHING. 7.3.10 reads
    # such a reference as the null object, and the copy says so with a null
    # object of its own rather than by dropping the entry: an /ExtGState
    # naming a resource the file does not define keeps its key, and what a
    # reader finds behind it is what it found in the file it came from. One
    # object for all of them - they are all the same object - and none at
    # all where the page has no such reference. Keyed on the PAIR, so that
    # the live "4 1 R" and the dead "4 0 R" of one number go different ways
    # (importRead::Serialize looks the pair up first).
    if {[dict size $dead]} {
      set nothing [list [$writer add null] 0]
      dict for {pair -} $dead {
        dict set map $pair $nothing
      }
    }
    foreach number $order {
      if {[dict exists $context shared $number]} {
        # Already in the file, under a number this document gave it.
        continue
      }
      lassign [dict get $copies $number] value hasStream data
      # The value with its strings already converted, from the loop above -
      # [Serialize] is called rather than [ImportSerialize] because the
      # string half of that pair has been done. Doing it twice would encrypt
      # the ciphertext in an encrypted document.
      set value [dict get $strings $number]
      if {$hasStream} {
        # The raw bytes and their /Filter travel unchanged, and the object
        # goes out through [stream] rather than being assembled here: that
        # is the one place /Length is computed (writer.tcl) and the one
        # place a stream's filters are checked against the document's PDF
        # version. Building the body here meant a copied stream was the
        # single stream in the document that passed neither - a second
        # producer of /Length beside the writer's, and a FlateDecode
        # resource that could land in a file whose header disowns the
        # filter.
        #
        # /Length is dropped rather than restated: the writer sets it, and
        # an indirect length object therefore need not come along.
        # The parsed value is a dictionary whenever hasStream is true: a
        # stream is only recognised as one when its /Length could be read
        # out of a dictionary, so there is nothing else it could be here.
        set pairs {}
        foreach {key item} [lindex $value 1] {
          if {$key eq "Length"} continue
          lappend pairs $key [::tclpdf::importRead::Serialize $item $map]
        }
        $writer stream [lindex [dict get $map $number] 0] $pairs $data
      } else {
        $writer put [lindex [dict get $map $number] 0] \
            [::tclpdf::importRead::Serialize $value $map]
      }
    }

    # The resources dictionary itself: referenced and already part of the
    # closure, or direct on the page and written as an object of its own.
    if {[lindex $resources 0] eq "r" && $resolved ne {}} {
      set resourcesRef [$writer ref \
          [lindex [dict get $map [lindex [lindex $resources 1] 0]] 0]]
    } elseif {[lindex $resources 0] eq "d"} {
      set resourcesRef [$writer ref [$writer add \
          [::tclpdf::importRead::Serialize $resourceStrings $map]]]
    } else {
      # A page without resources is legal; the form then carries an empty
      # dictionary, which PDF/A asks for anyway (6.2.2).
      set resourcesRef [$writer ref [$writer add "<< >>"]]
    }

    # An optional-content resource needs its catalog counterpart, or the
    # file carries layers no viewer can configure. Table 98 allows an OCMD
    # as a /Properties value; the catalog's /OCGs array takes the GROUPS
    # behind it - its /OCGs, a reference or an array of them - never the
    # OCMD itself (8.11.4.2 asks for every group in the document there).
    set sources {}
    set numbers {}
    set hidden {}
    set configName {}
    # A second import MERGES with what an earlier one put into the catalog
    # rather than overwriting it; the entry is this module's own
    # serialization, read back with its own parser. First come the groups
    # already there, then the new ones, duplicates dropped by number.
    set existing [my catalogEntry OCProperties]
    if {$existing ne {}} {
      set pos 0
      set have [::tclpdf::importRead::Parse $existing pos]
      foreach item [lindex [::tclpdf::importRead::Get $have OCGs] 1] {
        if {[lindex $item 0] eq "r"} {
          lappend numbers [lindex [lindex $item 1] 0]
        }
      }
      # And what that entry said about the groups in it: which of them start
      # out switched off, and the configuration's name.
      set config [::tclpdf::importRead::Get $have D]
      foreach item [lindex [::tclpdf::importRead::Get $config OFF] 1] {
        if {[lindex $item 0] eq "r"} {
          lappend hidden [lindex [lindex $item 1] 0]
        }
      }
      # The /Name as it stands, re-emitted and not rebuilt: in an encrypted
      # document it is already ciphertext, and putting it through the string
      # seam a second time would encrypt the cipher.
      set name [::tclpdf::importRead::Get $config Name]
      if {[lindex $name 0] in {s h} && [lindex $name 1] ne {}} {
        set configName [::tclpdf::importRead::Serialize $name {}]
      }
    }
    # EVERY OPTIONAL CONTENT GROUP OF THE CLOSURE, not only the ones a
    # /Properties entry of the page names. 8.11.4.2 asks the catalogue's
    # /OCGs for "an array of indirect references to all the optional content
    # groups in the document", and a group reaches this document by more
    # roads than one: a /Properties entry, which is what a BDC bracket in
    # the content stream switches (8.11.3.2); the /OC of an image or a form
    # XObject, which is how Illustrator and every CAD exporter write a layer
    # (8.11.3.3); the /OC of an annotation; and an OCMD standing in front of
    # any of them (Table 98). Only the first was looked at, so a group whose
    # single road was an XObject's /OC was COPIED and then named in no
    # configuration - and 8.11.4.3 gives /BaseState the default ON, so the
    # layer the source file hides was drawn (measured 2026-08-27: 729 red
    # pixels in the result where poppler renders none in the source).
    #
    # All of those roads end at an object of the closure, and an optional
    # content group says what it is (Table 96: /Type /OCG is required). So
    # the question is asked ONCE, of the closure, instead of once per road -
    # the OCMD needs no unwrapping here either, because the groups it names
    # are objects of the closure themselves.
    foreach number $order {
      if {[lindex [::tclpdf::importRead::Get \
          [lindex [dict get $copies $number] 0] Type] 1] eq "OCG"} {
        lappend sources $number
      }
    }
    # A GROUP THAT WAS OFF IN THE FILE IT COMES FROM STAYS OFF. Switching
    # everything on was the simple answer and the wrong one: a draft stamp
    # the foreign document hides comes out as a stamp across the imported
    # page, and nothing in this package's API could switch it off again.
    # What an EARLIER import decided is in the entry read back above, and
    # what THIS one decides is written into the entry below - the entry is
    # the seam between the two writers of it, for the state of a group as
    # much as for the group itself (layer.tcl reads both out of it).
    foreach source $sources {
      set number [lindex [dict get $map $source] 0]
      lappend numbers $number
      if {[dict exists $foreignStates $source]} {
        if {![dict get $foreignStates $source]} {
          lappend hidden $number
        }
      } elseif {!$baseVisible} {
        lappend hidden $number
      }
    }
    if {[llength $numbers]} {
      set groups {}
      set on {}
      set off {}
      set seen {}
      foreach number $numbers {
        if {[dict exists $seen $number]} continue
        dict set seen $number 1
        set reference [$writer ref $number]
        lappend groups $reference
        if {$number in $hidden} {
          lappend off $reference
        } else {
          lappend on $reference
        }
      }
      # /Name, non-empty, on every configuration dictionary - ISO 19005-2
      # and -3, 6.9-1, which veraPDF reports as failed when it is missing.
      # It used to be missing here whenever the importing document had no
      # layer of ITS own, because layer.tcl writes the name and layer.tcl
      # only runs when [layer create] has hooked it onto the catalog event.
      # The word is the one layer.tcl gives the default configuration when
      # the caller names none, so a document that later grows a layer of
      # its own does not rename its configuration behind the caller's back.
      if {$configName eq {}} {
        set configName [my Str Default]
      }
      # /Order lists every group as well - it is what the manual promises a
      # document whose only layers came in with an import, and a group
      # missing from /Order is one no reader offers to switch. Where /Order
      # is present it shall reference all the groups (ISO 19005-2/-3,
      # 6.9-3), which a copy of the /OCGs list is by construction.
      set config [list Order [::tclpdf::pdfObj arr $groups] \
          ON [::tclpdf::pdfObj arr $on]]
      if {[llength $off]} {
        lappend config OFF [::tclpdf::pdfObj arr $off]
      }
      # The name goes LAST, and layer.tcl writes it last for the same
      # reason: it is the one value in the configuration that a caller
      # dictates, and the small reader in layer.tcl looks for the first
      # /OFF and the first /OCGs in the text. A title reading "/OFF [4 0 R]"
      # would be found first if it stood in front of them.
      lappend config Name $configName
      my catalogEntry OCProperties [::tclpdf::pdfObj dictionary [list \
          OCGs [::tclpdf::pdfObj arr $groups] \
          D [::tclpdf::pdfObj dictionary $config]]]
    }

    # The form: BBox in its own normalized space, the page's corner and a
    # /Rotate folded into /Matrix, so [form place] puts down what a viewer
    # shows - upright, at the placement point.
    switch -- $rotate {
      90 {
        set matrix [list 0 -1 1 0 [expr {-$y0}] $x1]
      }
      180 {
        set matrix [list -1 0 0 -1 $x1 $y1]
      }
      270 {
        set matrix [list 0 1 -1 0 $y1 [expr {-$x0}]]
      }
      default {
        set matrix [list 1 0 0 1 [expr {-$x0}] [expr {-$y0}]]
      }
    }
    # The BBox clips in FORM space, before the matrix is applied (ISO
    # 32000-2, 8.10.2) - so it is the page's own box, unrotated; only the
    # width and height handed to [form place] are the post-matrix extents.
    set pairs [list Type /XObject Subtype /Form FormType 1 \
        BBox [::tclpdf::pdfObj arr [list \
            [::tclpdf::pdfObj num $x0] [::tclpdf::pdfObj num $y0] \
            [::tclpdf::pdfObj num $x1] [::tclpdf::pdfObj num $y1]]] \
        Matrix [::tclpdf::pdfObj arr \
            [lmap number $matrix {::tclpdf::pdfObj num $number}]] \
        Resources $resourcesRef]
    # The same transparency group [form create] writes - isolated, and
    # deliberately without /CS; xObject.tcl carries the full reasoning (a
    # named colour space is a PDF/A claim, ISO 19005-2, 6.2.4.3-2).
    # Without the group, [form place -opacity] composites each imported
    # object separately instead of fading the page as a whole. Groups
    # exist since PDF 1.4 - an older document gets none.
    if {[package vcompare [$writer version] 1.4] >= 0} {
      lappend pairs Group [::tclpdf::pdfObj dictionary {S /Transparency I true}]
    }
    set number [my streamObject $pairs $content]

    set resourceName PI[expr {[dict size $forms] + 1}]
    my resource XObject $resourceName [$writer ref $number]
    dict set forms $alias [dict create resource $resourceName \
        width $width height $height]
    my state forms $forms
    return $alias
  }

  # -- an imported object body, in this document's syntax ------------------
  #
  # THE FOURTH STRING DOOR. A PDF is encrypted string by string and stream by
  # stream (ISO 32000-2, 7.6.2), which is why every string a module writes
  # goes out through [my Str], [my HexStr] or [my BytesStr] - the seam the
  # cipher sits behind. The strings of an imported object never saw it: they
  # come out of a foreign file already parsed, and [importRead::Serialize]
  # writes them the way the syntax spells them, cipher or no cipher. In an
  # encrypted document that produced the one thing worse than an unreadable
  # file - a readable one: the layer names of an imported page stood in the
  # clear in a file whose own strings were encrypted, and a reader that
  # decrypted the file got the cipher of a string that was never encrypted
  # (measured 2026-08-22: /Name (German) legible in the file, /Name () after
  # [qpdf --decrypt]). The copied STREAMS were put behind the seam on
  # 2026-08-20; these are their object bodies.
  #
  # The strings are replaced BEFORE the value is serialized, rather than the
  # serializer being taught the seam: [importRead::Serialize] is the reader's
  # and three topics stand on it, while which spelling an encrypted string
  # gets is this document's business - the encryptor answers with finished
  # PDF syntax (hexadecimal, always) exactly as it does at every other string
  # in the document.
  # -- what is shared rather than copied ------------------------------------
  #
  # AN IMPORTED OBJECT IS A VALUE, not a thing with an identity. Two
  # byte-identical font programs are interchangeable, and until 2026-08-26
  # importing the same file twice brought every one of them twice: a letter
  # with the front and the back of a letterhead carried each embedded face
  # two times over, and [pdf fonts] counted eight where the source had four
  # (measured on 02.01-embedding.pdf: 24 269 bytes in, 24 790 after one
  # import, 48 831 after two). Only functions were pooled, because gradients
  # already had a pool and the case was reached from there.
  #
  # So the pool is asked about EVERY object of the closure, keyed on what the
  # object would be written as. The key is built from the value as it was
  # READ - before the document's string seam - because an encrypted document
  # spells the same string differently every time (a fresh initialisation
  # vector per call), and a key that changes on every look is a pool that
  # never hits.
  #
  # AN OBJECT IS ONLY SHAREABLE IF EVERYTHING IT POINTS AT IS, and that is
  # what makes this recursive rather than a loop. The serialization of a
  # value holding a reference depends on the number that reference resolves
  # to, so it can only be a key once that number is settled and settled by
  # CONTENT rather than by the order this import happened to reserve in. A
  # font dictionary therefore reaches the pool exactly when its descendant,
  # its descriptor and its font file have; one plainly copied object below
  # makes the whole chain above it plain as well.
  #
  # Whatever is left over is copied under a reserved number, as before -
  # anything on a reference cycle (a page tree walks back to its parent),
  # anything reaching one, and everything above an object the pool could not
  # take.
  #
  # THE OBJECT IS WRITTEN HERE, whole, rather than reserved and filled later:
  # a shared object has no forward reference to wait for, by construction.
  # Answers 1 where the number in the map is a shared one.
  method ImportShare {number contextVar} {
    upvar 1 $contextVar context
    if {[dict exists $context shared $number]} {
      return 1
    }
    if {[dict exists $context plain $number]} {
      return 0
    }
    if {[dict exists $context visiting $number]} {
      # A cycle. Nothing on it can be keyed by its content, because the
      # content of each holds the number of the next.
      return 0
    }
    if {![dict exists $context copies $number]} {
      return 0
    }
    lassign [dict get $context copies $number] value hasStream data
    dict set context visiting $number 1
    set shareable 1
    # Walked as PAIRS: a value holding a reference that reaches nothing is
    # never pooled, because the null object it is written with is handed out
    # after this pass - and because the pool is keyed on finished syntax, in
    # which a dead "4 0 R" and a live "4 1 R" would otherwise look the same.
    foreach pair [::tclpdf::importRead::RefPairs $value] {
      if {[dict exists $context dead $pair]
          || ![my ImportShare [lindex $pair 0] context]} {
        set shareable 0
      }
    }
    dict unset context visiting $number
    if {!$shareable} {
      dict set context plain $number 1
      return 0
    }
    set map [dict get $context map]
    # A FUNCTION GOES ON THROUGH THE POOL THE GRADIENTS USE, so that an
    # imported function and one this document computed for a [shading] of its
    # own are one object. That pool is keyed on finished syntax, which for a
    # value without strings is the same thing as the key below - and a
    # function with strings in it does not exist.
    if {!$hasStream && [lindex $value 0] eq "d"
        && [dict exists [lindex $value 1] FunctionType]
        && ![llength [::tclpdf::importRead::Refs $value]]} {
      dict set context map $number [list [my FunctionPool \
          [my ImportSerialize $value {}] {} {}] 0]
      dict set context shared $number 1
      return 1
    }
    # AN OPTIONAL CONTENT GROUP IS NOT A VALUE. It is a row in the reader's
    # layer panel, a name a person clicks, and a thing this document keeps a
    # STATE for - which of the imported groups start out switched off travels
    # through the catalogue entry (see below and layer.tcl), keyed on the
    # number this document gave it. Two imports that each brought a layer are
    # two layers the caller can tell apart and switch apart, and collapsing
    # them into one would decide that question here rather than leaving it
    # where it belongs. A membership dictionary goes with it, since it names
    # groups. Everything else - a font, a picture, an ICC profile, a
    # descriptor - is a value, and two identical ones are interchangeable.
    if {[lindex [::tclpdf::importRead::Get $value Type] 1] in {OCG OCMD}} {
      dict set context plain $number 1
      return 0
    }
    set key [list $hasStream $data \
        [::tclpdf::importRead::Serialize $value $map]]
    set pool [my state importPool]
    if {[dict exists $pool $key]} {
      dict set context map $number [list [dict get $pool $key] 0]
      dict set context shared $number 1
      return 1
    }
    set body [dict get $context strings $number]
    if {$hasStream} {
      # The raw bytes and their /Filter travel unchanged, and /Length is
      # dropped rather than restated - the writer computes it. Both are the
      # copying loop's reasons, spelled out there.
      set pairs {}
      foreach {entry item} [lindex $body 1] {
        if {$entry eq "Length"} continue
        lappend pairs $entry [::tclpdf::importRead::Serialize $item $map]
      }
      set target [[my writer] addStream $pairs $data]
    } else {
      set target [[my writer] add \
          [::tclpdf::importRead::Serialize $body $map]]
    }
    dict set pool $key $target
    my state importPool $pool
    dict set context map $number [list $target 0]
    dict set context shared $number 1
    return 1
  }

  # The filter names of a stream the import is about to copy, as a plain list
  # - what the writer is asked about before the object's number is reserved.
  #
  # /Filter is a name or an array of them (7.3.8.2), and either the entry
  # itself or a member of the array may be an indirect reference (7.4), which
  # is why every one of them goes through [Resolve] - the same reading
  # [DecodeStream] does to find out which decoder to run, asked here of a
  # stream that is copied rather than decoded. A stream with no /Filter
  # answers the empty list.
  method ImportStreamFilters {readerVar value} {
    upvar 1 $readerVar reader
    set filter [::tclpdf::importRead::Resolve reader \
        [::tclpdf::importRead::Get $value Filter]]
    if {[lindex $filter 0] eq "nm"} {
      return [list [lindex $filter 1]]
    }
    if {[lindex $filter 0] ne "a"} {
      return {}
    }
    set names {}
    foreach item [lindex $filter 1] {
      lappend names [lindex [::tclpdf::importRead::Resolve reader $item] 1]
    }
    return $names
  }

  method ImportSerialize {value map} {
    return [::tclpdf::importRead::Serialize [my ImportStrings $value] $map]
  }

  # The same value with every string in it replaced by the finished string
  # object the document's seam hands back. It travels on as a node of type
  # "n" - the reader's node for a number, whose payload is written out AS IT
  # STANDS. That is what a finished object needs and the reason the seam can
  # be reached from outside the serializer at all.
  #
  # Without an encryptor the result is byte for byte what the serializer
  # would have written on its own: [pdfObj bytesStr] escapes the same three
  # characters and the same range as the "s" branch there, and a hexadecimal
  # string reappears as a hexadecimal string.
  method ImportStrings {value {depth 0}} {
    if {$depth > 500} {
      # The serializer refuses this value on the next line anyway, with the
      # named error the whole reader uses for it.
      return $value
    }
    lassign $value type payload
    switch -- $type {
      s {
        return [list n [my BytesStr $payload]]
      }
      h {
        # 7.3.4.3: hexadecimal digits and white space, and an odd number of
        # digits means a trailing zero - which is what [binary format H*]
        # does with one. Anything else is not a hexadecimal string, and a
        # raw Tcl error is not a refusal this package makes.
        set hex [string map {" " {} "\n" {} "\r" {} "\t" {} "\f" {} "\x00" {}} \
            $payload]
        if {![string is xdigit -strict $hex] && $hex ne {}} {
          return -code error -errorcode {TCLPDF IMPORT SYNTAX} "tclpdf: a\
              hexadecimal string of the imported PDF holds something that is\
              not a hexadecimal digit (ISO 32000-2, 7.3.4.3)"
        }
        return [list n [my HexStr [binary format H* $hex]]]
      }
      d {
        set out {}
        foreach {key item} $payload {
          lappend out $key [my ImportStrings $item [expr {$depth + 1}]]
        }
        return [list d $out]
      }
      a {
        return [list a [lmap item $payload {
          my ImportStrings $item [expr {$depth + 1}]
        }]]
      }
      default {
        return $value
      }
    }
  }

  # Which optional content groups of the file being read start out switched
  # OFF, as {defaultVisible {number visible ...}} over the SOURCE object
  # numbers: the default configuration's /BaseState (Table 99, default ON)
  # and the /ON and /OFF arrays that override it per group. A file without
  # optional content, or one whose configuration is unreadable, answers "on,
  # nothing listed" - the state every group of a well formed file has unless
  # its configuration says otherwise.
  method ImportLayerStates {readerVar} {
    upvar 1 $readerVar reader
    set root [::tclpdf::importRead::Resolve reader \
        [::tclpdf::importRead::Get [dict get $reader trailer] Root]]
    set properties [::tclpdf::importRead::Resolve reader \
        [::tclpdf::importRead::Get $root OCProperties]]
    set config [::tclpdf::importRead::Resolve reader \
        [::tclpdf::importRead::Get $properties D]]
    if {[lindex $config 0] ne "d"} {
      return [list 1 {}]
    }
    set base [expr {
      [lindex [::tclpdf::importRead::Get $config BaseState] 1] eq "OFF" ? 0 : 1
    }]
    set states {}
    foreach {key visible} {ON 1 OFF 0} {
      set array [::tclpdf::importRead::Resolve reader \
          [::tclpdf::importRead::Get $config $key]]
      if {[lindex $array 0] ne "a"} continue
      foreach item [lindex $array 1] {
        if {[lindex $item 0] eq "r"} {
          dict set states [lindex [lindex $item 1] 0] $visible
        }
      }
    }
    return [list $base $states]
  }
}

# ---------------------------------------------------------------------------
# THE INVENTORY: what a finished file says about itself
# ---------------------------------------------------------------------------
#
#   set facts [::tclpdf::pdf info invoice.pdf]
#   dict get $facts pages                  -> 3
#   dict get $facts info Producer          -> "tclpdf 1.1.1"
#   dict get $facts pdfa                   -> "3B"
#   ::tclpdf::pdf pages invoice.pdf        -> one dictionary per page
#   ::tclpdf::pdf fonts invoice.pdf        -> one dictionary per face
#   ::tclpdf::pdf metadata invoice.pdf     -> the XMP packet, or {}
#
# WHY THIS COSTS ALMOST NOTHING. The reader above already reads a foreign
# file's trailer, its whole cross-reference chain, its page tree with the
# inherited attributes, and any object behind them - it has to, to take over a
# single page. Everything below only ASKS that reader what it has: not one
# byte is read that [pdf import] does not read anyway, and the one piece of
# arithmetic that is new - which box a viewer shows, turned which way - is the
# import's own, now shared with it ([Geometry] above). The alternative for a
# caller is shelling out to pdfinfo: a foreign program, its exit status, its
# output format, and a file that has to lie where that program may read it.
#
# A PACKAGE COMMAND, NOT A DOCUMENT METHOD - the decision update.tcl makes at
# length, for the same reason: the subject is a finished file made by anyone,
# addressed by its path. A document object is a file this package is about to
# WRITE, and asking one what some other file contains would put two unrelated
# things in one handle. So the entry sits beside [::tclpdf::update open] and
# [::tclpdf::sign digest]. The name mirrors the document method [$doc pdf
# import]: the "pdf" family is the one about foreign files - one takes a page
# out of one, the other asks one what it is.
#
# FOUR SUBCOMMANDS RATHER THAN ONE DICTIONARY, because they cost different
# things. [info] answers out of the trailer, the catalog and page one; [pages]
# walks every page of the tree; [fonts] walks every page AND the resources
# behind it. A 900-page catalogue can then answer "is this encrypted, how many
# pages, who made it" without its 900 pages being visited. Each call opens the
# file again - ask once and keep the answer.
#
# AN ENCRYPTED FILE IS ANSWERED, NOT REFUSED. [pdf import] and [update open]
# refuse one, and they must: they would produce a document made of cipher
# text. An inventory is the one caller for which "encrypted, standard handler,
# revision 6, AESV3" IS the answer - which is more than pdfinfo gives, since
# that stops at "Command Line Error: Incorrect password". What comes back is
# what the trailer and the cross-reference say: the size, the version, how
# often the file was written on, the identifier and the /Encrypt entries.
# Every content-derived field stays empty, because strings and streams are
# cipher text without the key (7.6.2) and a guess would be worse than an empty
# answer. [pages], [fonts] and [metadata] refuse an encrypted file by name -
# through [Open], which refuses it for all three.
#
# WHAT IS DELIBERATELY NOT ANSWERED, each because the honest answer would need
# more than reading:
#
#   TEXT, WORDS, IMAGES, COLOURS ON THE PAGE. That is rendering, not reading:
#   content streams would have to be interpreted, fonts decoded, CID codes
#   mapped back through ToUnicode. pdftotext does it, and does it well.
#
#   WHETHER A SIGNATURE IS VALID. What comes back is that a signature field
#   exists, what it claims, and whether its /ByteRange reaches the last byte
#   of the file. Whether the digest matches and whether the certificate is
#   trusted is cryptography against an outside trust store - pdfsig and
#   Mustangproject do that, and this package points at them rather than
#   half-doing it.
#
#   WHETHER THE FILE REALLY IS PDF/A. What is reported is the CLAIM in the XMP
#   packet - pdfaid:part and pdfaid:conformance - and a claim is not a
#   conformance; veraPDF decides that over hundreds of rules. The difference
#   is worth the key's name: "pdfa" is what the file says about itself.
#
#   THE PERMISSIONS OF AN ENCRYPTED FILE. /P is reported as the number it is
#   and not interpreted: from revision 6 on, the authoritative copy of the
#   permissions is the encrypted /Perms string (7.6.4.4), so decoded bits
#   would state as fact what only decryption can confirm.
#
#   JAVASCRIPT, "OPTIMIZED", USER PROPERTIES - fields pdfinfo prints that
#   cannot be had from one catalog key: scripts also hang off annotations and
#   page actions, and "optimized" is a claim about linearization. Half an
#   answer here would read like a whole one.
#
#   ANNOTATIONS, OUTLINES, PAGE LABELS, THE STRUCTURE TREE. Each is a tree of
#   its own and none of them is inventory in the sense asked for. They are
#   reachable through the same reader the day they are wanted.

package provide tclpdf::import 1.8