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
    if {![file exists $path]} {
      return -code error -errorcode {TCLPDF IMPORT FILE} \
          "tclpdf: pdf import: no file \"$path\""
    }

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
    set content [join $pieces \n]

    # Everything the page's resources reach, READ: object by object, the
    # closure over the references. The content streams are not part of it -
    # they are the block above, decoded and merged into the form rather than
    # copied. Every object of the closure is read here and kept, because
    # reading is where the reader refuses: a resource in an object stream
    # that is not there, a broken cross-reference entry, a value nested
    # deeper than the parser follows. Not one of those may leave a reserved
    # object number behind - an object reserved and never filled makes the
    # WRITE fail, for a document that could otherwise still be written.
    set resources [::tclpdf::importRead::Get $pageDict Resources]
    set queue [::tclpdf::importRead::Refs $resources]
    set order {}
    set copies {}
    while {[llength $queue]} {
      set queue [lassign $queue number]
      if {[dict exists $copies $number]} continue
      lassign [::tclpdf::importRead::Object reader $number] value hasStream data
      dict set copies $number [list $value $hasStream $data]
      lappend order $number
      lappend queue {*}[::tclpdf::importRead::Refs $value]
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

    # -- from here on the document changes --------------------------------
    #
    # [Refs] walked every value above and refused what it could not walk, so
    # the numbering below cannot run into a value the reading did not already
    # accept - and every number is handed out only for an object whose
    # strings have been through [ImportStrings] one line earlier, which is
    # the last thing on this road that can still say no.
    set writer [my writer]
    set map {}
    set pooled {}
    set strings {}
    foreach number $order {
      # A FUNCTION IS A VALUE, not a thing with an identity: two identical
      # ones are interchangeable, and importing the same file twice used to
      # bring the same function twice with it. It goes through the pool the
      # gradients already use - and the decision falls HERE, before the
      # number is reserved, because a reservation left unfilled makes the
      # whole document unwritable. That defect has been had once (annot.tcl,
      # 2026-08-25) and is not worth having twice.
      lassign [dict get $copies $number] value hasStream
      set reuse [my ImportPooledFunction $value $hasStream]
      if {$reuse ne {}} {
        dict set map $number $reuse
        lappend pooled $number
        continue
      }
      # THE STRINGS OF THE OBJECT, put through the document's seam BEFORE
      # the number is reserved and for the same reason as the pool above.
      # [ImportStrings] is the last refusal of the whole import - a
      # hexadecimal string of the foreign file holding something that is not
      # a hexadecimal digit (7.3.4.3) - and it used to fall in the loop
      # below, with every number already handed out: a [pdf import] the
      # caller had caught left the document unwritable, "object(s) reserved
      # but never written" at the next [write] (measured 2026-08-25 on a
      # file carrying <4G>). The conversion does not need the map, so it can
      # be done here; only the serialization does, and that stays below.
      dict set strings $number [my ImportStrings $value]
      # AND THE FILTER OF A COPIED STREAM, asked of the writer here for the
      # third time in this loop for the same reason. The check itself is the
      # writer's and stays there - a FlateDecode resource may not land in a
      # file whose header disowns the filter - but it used to be reached only
      # through [stream] in the loop below, which runs after every number of
      # the closure has been handed out: [pdf import] of a page with a
      # deflated resource into a -version 1.1 document was refused correctly
      # and left the document unwritable all the same, "object(s) reserved but
      # never written" at the next [write] (measured 2026-08-25). The refusal
      # is the same sentence either way; only its place has moved forward.
      if {$hasStream} {
        $writer requireFilter [my ImportStreamFilters reader $value]
      }
      dict set map $number [$writer reserve]
    }
    foreach number $order {
      if {$number in $pooled} {
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
        $writer stream [dict get $map $number] $pairs $data
      } else {
        $writer put [dict get $map $number] \
            [::tclpdf::importRead::Serialize $value $map]
      }
    }

    # The resources dictionary itself: referenced and already part of the
    # closure, or direct on the page and written as an object of its own.
    if {[lindex $resources 0] eq "r"} {
      set resourcesRef [$writer ref \
          [dict get $map [lindex [lindex $resources 1] 0]]]
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
    set resolved [::tclpdf::importRead::Resolve reader $resources]
    set properties [::tclpdf::importRead::Resolve reader \
        [::tclpdf::importRead::Get $resolved Properties]]
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
    if {[lindex $properties 0] eq "d"} {
      foreach {- item} [lindex $properties 1] {
        if {[lindex $item 0] ne "r"} continue
        set entry [::tclpdf::importRead::Resolve reader $item]
        if {[lindex [::tclpdf::importRead::Get $entry Type] 1] eq "OCMD"} {
          set members [::tclpdf::importRead::Get $entry OCGs]
          if {[lindex $members 0] eq "r"} {
            set members [list $members]
          } elseif {[lindex $members 0] eq "a"} {
            set members [lindex $members 1]
          } else {
            set members {}
          }
          foreach member $members {
            if {[lindex $member 0] eq "r"} {
              lappend sources [lindex [lindex $member 1] 0]
            }
          }
        } else {
          lappend sources [lindex [lindex $item 1] 0]
        }
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
      set number [dict get $map $source]
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
  # A foreign object that may be reused rather than copied, or the empty
  # string. Narrow on purpose, and each condition is a way it could go wrong:
  #
  #   a stream          a sampled (type 0) or PostScript (type 4) function
  #                     carries one, and the pool would have to key on the
  #                     bytes as well - the common gradient types 2 and 3 do
  #                     not, so the cheap half is taken and the rest copied
  #   not a dictionary  nothing else can be a function
  #   no FunctionType   the only mark a function has (ISO 32000-1, 7.10)
  #   any reference     the serialization of a value holding one depends on
  #                     the map, and the map is not finished at this point.
  #                     A function of type 3 referring to its parts through
  #                     indirect objects is therefore copied whole
  method ImportPooledFunction {value hasStream} {
    if {$hasStream || [lindex $value 0] ne "d"} {
      return {}
    }
    if {![dict exists [lindex $value 1] FunctionType]} {
      return {}
    }
    if {[llength [::tclpdf::importRead::Refs $value]]} {
      return {}
    }
    return [my FunctionPool [my ImportSerialize $value {}] {} {}]
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

package provide tclpdf::import 1.5