#
# tclpdf - PDF generation for Tcl
#
# graphics - paths, graphics state and transparency (8.4, 8.5)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# The methods here attach themselves to the document class with [oo::define]
# when the module is loaded, which is what keeps the core from growing with
# every feature. Loading is triggered by the first call - see the topic table
# in document.tcl.
#
# Everything goes through Style and Paint. Those two exist because the same
# five lines - colour, width, dash, then the right painting operator - would
# otherwise be repeated in every shape, each version slightly different. The
# painting operator in particular has six spellings (f, S, B, f*, B*, n) and
# picking the wrong one produces a shape that is there but invisible.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::color 1.0-
package require tclpdf::option 1.0-
package require tclpdf::geometry 1.0-
package require tclpdf::document 1.0-

namespace eval ::tclpdf::graphics {}

oo::define ::tclpdf::document::document {

  # -- graphics state -----------------------------------------------------

  # q and Q (8.4.2). Always in pairs - an unbalanced q leaves the rest of the
  # page in whatever state the last shape left behind.
  # q and Q, and with them the colours [style] set: a reader restores its
  # colour on Q, so what this package remembers about them has to follow.
  method save {} {
    set stack [my streamState styleStack]
    # Annex C.2, Table C.1: "Nesting depth of graphics state (q) ... 28". A
    # deeper stack is not a syntax error and no validator objects - it is a
    # limit a conforming reader is allowed to stop at, and what it does with
    # the twenty-ninth "q" is its own business. Refused rather than repaired,
    # like every other Annex C limit this package holds to (the page frame,
    # the real range, 32 DeviceN colourants, the name length in pdfObj).
    # Counted BEFORE the operator is written: a refused save leaves nothing.
    #
    # ONLY THE SAVES OF THIS API ARE COUNTED, and that is less than the
    # depth of the stream. Every shape with a style of its own, every text
    # run, every placement writes a q/Q of its own inside the bracket, so 28
    # open saves plus one "rect -fill red" is 29 nested "q" in the file -
    # measured 2026-08-27. Nor does the count follow a form onto the page it
    # is placed on: 8.10.1 gives the "Do" its own save, and the form's stream
    # runs inside it, so the depths add up there as well. What starts at
    # depth zero for a reader is a Type 3 glyph description and a colour
    # font's paint tree, which are executed rather than placed.
    #
    # The limit is therefore held on THE SAVES A CALLER OPENS, which is the
    # number a caller can do something about, and not on the file's own
    # nesting. Annex C.2 of ISO 32000-2 keeps the figure only historically
    # ("In previous versions of PDF, a maximum depth ... was 28"), so the
    # difference costs nothing a reader made after 2008 will notice.
    if {[llength $stack] >= 28} {
      return -code error -errorcode [list TCLPDF GRAPHICS SAVE depth] \
          "tclpdf: 28 nested saves are open and that is as deep as the\
          graphics state stack goes (ISO 32000-1, Annex C.2) - close one\
          with \"restore\" before opening another"
    }
    my content "q\n"
    # The transformation in force goes on the stack with the colours: "Q"
    # restores the whole graphics state (8.4.2), the CTM included, and what
    # this package remembers about it has to follow the reader. A fourth word
    # in the same record rather than a stack of its own, so the two cannot
    # come apart - see [ctm] in page.tcl for what it is for.
    lappend stack [list [my streamState styleFill] [my streamState styleStroke] \
        [my streamState overprintFill] [my ctm] \
        [my streamState overprintMode]]
    my streamState styleStack $stack
    # A stream that ends with a save still open is refused, and the refusal
    # has to name the place: the write is far from the call, and "one save
    # too many" without a page number is a message nobody can act on. See
    # [GraphicsBalance]. Subscribed on the first save and never again - the
    # arrangement annot.tcl keeps for its own write check.
    if {[my state graphicsHooked] eq {}} {
      my state graphicsHooked 1
      my onSelf beforeWrite GraphicsBeforeWrite
    }
    return
  }

  # Every page, at the write: a "q" that no "Q" answers.
  #
  # 8.4.2 gives q and Q as a pair. An unclosed one at the END of a page
  # stream carries nothing into anything - the stream is over - but it is
  # still a state the file opens and never closes, and it is almost always
  # the symptom of a [restore] that was skipped over by an error path, with
  # everything after it drawn in the wrong state. The mirror refusal
  # ([restore] without a save) has been made since 2026-08-18; this is the
  # other direction, and it is made in the same words.
  #
  # At the write rather than at [page add], because a caller may add a page,
  # go back to an earlier one and close the bracket there - the page is not
  # finished until the document is.
  method GraphicsBeforeWrite {} {
    set open {}
    for {set index 0} {$index < [my page count]} {incr index} {
      set page [my Page $index]
      if {![dict exists $page styleStack]} {
        continue
      }
      set depth [llength [dict get $page styleStack]]
      if {$depth} {
        lappend open "page [expr {$index + 1}] ($depth)"
      }
    }
    if {[llength $open]} {
      my GraphicsBalance [join $open {, }]
    }
    return
  }

  # The wording, in one place: the page write and the two stream builders
  # (a form XObject, a tiling pattern) all end a stream and all ask the same
  # question of it.
  method GraphicsBalance {where} {
    return -code error -errorcode [list TCLPDF GRAPHICS SAVE unbalanced] \
        "tclpdf: a save is still open where the content stream ends -\
        $where; q and Q are a pair (ISO 32000-1, 8.4.2), and a stream that\
        opens a graphics state and never closes it is a restore that was\
        skipped"
  }

  # Refused without a [save] to answer: the stack of remembered colours is
  # one entry per open q, so an empty one means no q is open in this
  # stream, and the Q would leave the reader with more restores than saves
  # - undefined by 8.4.2, and measured before 2026-08-18 it went out
  # without a word. Nothing is written when it is refused.
  method restore {} {
    set stack [my streamState styleStack]
    if {![llength $stack]} {
      return -code error -errorcode [list TCLPDF GRAPHICS RESTORE empty] \
          "tclpdf: restore without a save - the graphics state\
          stack of this stream is empty (8.4.2)"
    }
    my content "Q\n"
    lassign [lindex $stack end] fill stroke overprintFill ctm overprintMode
    my streamState styleFill $fill
    my streamState styleStroke $stroke
    my streamState overprintFill $overprintFill
    my streamState ctm $ctm
    my streamState overprintMode $overprintMode
    my streamState styleStack [lrange $stack 0 end-1]
    return
  }

  # $doc transform -at {150 200} -rotate 20
  # $doc transform -translate {10 10} -rotate 45 -scale 2 -skew {0 0}
  #
  # Two different things, and the difference matters:
  #
  #   -at {x y}         a POINT in document coordinates to rotate, scale or
  #                     skew ABOUT. Everything drawn afterwards still uses
  #                     normal document coordinates.
  #   -translate {dx dy} a DELTA: dx to the right, dy DOWNWARDS, matching the
  #                     top-left origin the rest of the API uses.
  #
  # -at is what "put a rotated stamp there" needs. It works by moving to the
  # point, transforming, and moving back - so the page height stays the
  # reference and [coords] keeps working for every shape that follows. Doing
  # it with -translate instead mirrors the y axis a second time and the shape
  # lands somewhere else entirely.
  #
  # The parts compose as if called one after another - translate, then
  # rotate, then skew, then scale - which is what a sequence of cm operators
  # does: a point drawn afterwards is scaled first, skewed, turned, and
  # displaced LAST, so the displacement is in unscaled, unturned document
  # units (the reading Canvas and SVG give "translate() rotate()" as well).
  # Measured before 2026-08-17 the order was the other way round - the
  # displacement went through the rotation and the scale, and
  # "-translate {10 20} -scale 2" moved by 20 and 40 - although the manual
  # promised the sequence. Wrap it in save and restore, or it stays in force
  # for the rest of the page.
  method transform {args} {
    set options [::tclpdf::option parse {
      at {} translate {} rotate {} scale {} skew {} matrix {}
    } $args]
    if {[dict get $options matrix] ne {}} {
      # Six finite numbers and not singular - the one check every raw
      # -matrix gets (geometry.tcl), before the cm goes out. "cm" takes
      # exactly six operands (8.4.4), and five leave a reader with an operand
      # stack it cannot make sense of; a singular cm (8.3.4) folds everything
      # drawn after it onto a line, with no way back to the page - the same
      # reason -scale refuses a zero factor below.
      set matrix [::tclpdf::geometry check [dict get $options matrix] transform]
    } else {
      # Every part is checked and built first, and composed afterwards in
      # the order the points go through them (see above): the values are
      # refused before anything is written, whatever their position.
      set translate {}
      set rotate {}
      set skew {}
      set scale {}
      if {[dict get $options translate] ne {}} {
        lassign [my GraphicsNumbers [dict get $options translate] -translate 2 \
            "{dx dy}"] dx dy
        set translate [::tclpdf::geometry translate [my distance $dx] \
            [expr {-[my distance $dy]}]]
      }
      if {[dict get $options rotate] ne {}} {
        set rotate [::tclpdf::geometry rotate [my GraphicsNumbers \
            [dict get $options rotate] -rotate 1 "an angle in degrees"]]
      }
      if {[dict get $options skew] ne {}} {
        lassign [my GraphicsNumbers [dict get $options skew] -skew 2 \
            "two angles in degrees {alpha beta}"] alpha beta
        set skew [::tclpdf::geometry skew $alpha $beta]
      }
      if {[dict get $options scale] ne {}} {
        set scale [dict get $options scale]
        if {[llength $scale] ni {1 2}} {
          return -code error -errorcode [list TCLPDF GRAPHICS ARGUMENT scale] \
              "tclpdf: -scale is one factor or {sx sy},\
              not \"$scale\""
        }
        # A factor of zero makes the matrix singular: everything drawn under
        # it collapses to a line or a point, and there is no way back to the
        # page from there. Negative is fine - that is a mirror.
        foreach factor $scale {
          # [finite] and not "string is double": NaN and Inf are doubles to
          # Tcl, "== 0" is false for both, and the cm then carried a factor
          # that places nothing (measured 2026-08-26: {ARITH DOMAIN}).
          if {![::tclpdf::option finite $factor] || $factor == 0} {
            return -code error -errorcode [list TCLPDF GRAPHICS ARGUMENT scale] \
                "tclpdf: -scale takes non-zero factors,\
                not \"$factor\""
          }
        }
        set scale [::tclpdf::geometry scale {*}$scale]
      }
      set matrix [::tclpdf::geometry identity]
      # Scale, skew, rotate, translate: the point meets them in this order,
      # which is the sequence "translate, rotate, skew, scale" of cm calls.
      foreach part [list $scale $skew $rotate $translate] {
        if {$part ne {}} {
          set matrix [::tclpdf::geometry multiply $matrix $part]
        }
      }
      if {[dict get $options at] ne {}} {
        # ABOUT the point instead of about the origin of the page - to the
        # origin first, transform, and back again. The pair stood written out
        # here until 2026-08-27 and is [geometry about] now, which is where
        # the two placement roads read it as well: three copies of "move,
        # turn, move back" is how the fourth one gets the order backwards,
        # and neither order produces an error - only a shape somewhere else.
        lassign [my GraphicsPoint [dict get $options at] -at transform] px py
        set matrix [::tclpdf::geometry about $matrix $px $py]
      }
    }
    # AND THE MATRIX THE PARTS COMPOSE TO IS HELD TO WHAT A RAW -matrix IS
    # HELD TO. -matrix goes through [geometry check] above (8.3.4: a singular
    # cm folds everything drawn after it onto a line, with no way back to the
    # page), and the parts used to escape it: "transform -skew {45 45}" wrote
    # "1 1 1 1 0 0 cm", determinant zero, measured 2026-08-26 - tan 45 is 1
    # in both places, and two equal columns are a collapse. Asked here, of
    # the composed matrix and of the numbers as they will be WRITTEN
    # ([geometry singular]), because that is where a combination that is
    # sound part by part can still collapse.
    if {[::tclpdf::geometry singular $matrix]} {
      return -code error -errorcode [list TCLPDF GEOMETRY MATRIX transform] \
          "tclpdf: transform composes to the singular matrix {$matrix} -\
          a*d - b*c must not be zero, or everything drawn under it collapses\
          onto a line; -skew {45 45} is the usual way there, tan 45 being 1\
          on both axes"
    }
    my content "[join [lmap number $matrix {::tclpdf::pdfObj num $number}] { }] cm\n"
    # AND THE STREAM NOW SITS SOMEWHERE ELSE. "cm" concatenates (8.4.4): the
    # new CTM is this matrix followed by the one in force, in that order,
    # because a point drawn from here on meets this matrix first. Recorded so
    # that the three answers stated in default user space - a Figure's
    # /BBox, a link's /Rect, the box a placement hands back - can be worked
    # out at all; see [ctm] in page.tcl. Written LAST, after the refusals
    # above, so a transform that was turned away leaves the record alone.
    my streamState ctm [::tclpdf::geometry multiply $matrix [my ctm]]
    return $matrix
  }

  # The numbers of -translate, -rotate and -skew: as many as the option
  # takes, and every one of them a number something can be measured in.
  #
  # Written once because the three used to be read by a bare [lassign] and a
  # bare [dict get]: "-translate {1 2 3}" dropped the third word in silence,
  # "-rotate NaN" and "-skew {a b}" died inside the trigonometry with Tcl's
  # own words - measured 2026-08-26 - against the promise that a value that
  # is not a measurement is turned away where it is READ (doc, "Numbers").
  # "shape" is what the option takes, for the message.
  method GraphicsNumbers {value option count shape} {
    if {[llength $value] != $count} {
      return -code error -errorcode [list TCLPDF GRAPHICS ARGUMENT \
          [string trimleft $option -]] \
          "tclpdf: $option of transform is $shape, not \"$value\""
    }
    foreach number $value {
      if {![::tclpdf::option finite $number]} {
        return -code error -errorcode [list TCLPDF GRAPHICS ARGUMENT \
            [string trimleft $option -]] \
            "tclpdf: $option of transform takes finite numbers, not\
            \"$number\" - NaN and Inf are doubles to Tcl and place nothing\
            on a page"
      }
    }
    return $value
  }

  # Set colour, line width, dash pattern, caps and joins without drawing.
  #
  # The colours are remembered as well as written: a shape that names no
  # colour of its own paints with them (see GraphicsPaint), which is what
  # "in force until changed" has to mean for a colour. Measured before
  # 2026-08-17 the operators went out and nothing ever painted with them - a
  # bare rect after "style -fill red" ended in n.
  method style {args} {
    set options [::tclpdf::option parse {
      fill {} stroke {} width {} dash {} cap {} join {} miter {} opacity {}
      blend {} overprint {}
    } $args]
    my content [my GraphicsStyle $options 0 style]
    foreach which {fill stroke} {
      if {[dict get $options $which] ne {}} {
        my streamState style[string totitle $which] [dict get $options $which]
      }
    }
    return
  }

  # Constant alpha via an ExtGState resource (11.6.6). Measured the most
  # frequent feature of the whole corpus at 62.5 % - watermarks, logos, the
  # shaded every-other-row of a table.
  method opacity {value {which both}} {
    set name [my GraphicsOpacity $value $which]
    my content "[::tclpdf::pdfObj name $name] gs\n"
    return $name
  }

  # $doc blend Multiply
  #
  # The blend mode decides how a colour is combined with what is already on the
  # page: Normal replaces it, Multiply darkens, Screen lightens, and the rest of
  # the sixteen do what their names say. Like the alpha it is graphics state, so
  # it holds until changed - and like the alpha a shape can take it per call
  # through -blend, which wraps it in the shape's own q/Q.
  method blend {mode} {
    set name [my GraphicsBlend $mode]
    my content "[::tclpdf::pdfObj name $name] gs\n"
    return $name
  }

  # $doc overprint -fill 1 -stroke 1 -mode 1
  #
  # OVERPRINTING (8.6.7): whether what is painted here KNOCKS OUT what is
  # under it on the other colourants, or leaves it standing. It is the one
  # graphics state parameter that changes nothing a reader shows and
  # everything a press prints.
  #
  # Black text on a cyan panel is the standing example. Knocked out - the
  # default - the cyan plate is punched where the letters go, and the paper
  # has to line up to a tenth of a millimetre or a white edge shows around
  # every letter. Overprinted, the cyan runs on underneath and a misregister
  # is invisible. That is why black text is set to overprint almost
  # everywhere, and why this is worth having at all.
  #
  # AND THE TRAP, which is why control strips exist: overprinting a LIGHT
  # colour is a mistake. Yellow over cyan, overprinted, is green - the yellow
  # was wanted and green comes out. No viewer shows it, no validator reports
  # it, and the proof is where it is found. This package writes what it is
  # asked for and says so here rather than deciding for the caller.
  #
  # Three switches, and they are separate because they answer different
  # questions:
  #
  #   -stroke   /OP,  what a stroke does           (PDF 1.2)
  #   -fill     /op,  what a fill does             (PDF 1.3)
  #   -mode     /OPM, what a ZERO in a CMYK value means (PDF 1.3): 0 leaves
  #             the plate alone, 1 - "nonzero overprint" - paints it at
  #             nought, which is how a caller sets one plate without
  #             disturbing the rest
  #
  # An option left out is not written, so a call names what it means to
  # change. A call that names nothing at all is refused rather than writing a
  # resource that changes nothing - the lesson [GraphicsOpacity] already
  # carries.
  #
  # WHAT /OP ALONE MEANS, and why -stroke is not simply /OP: Table 58 says of
  # OP "Specifying an OP entry shall set BOTH parameters unless there is also
  # an op entry in the same graphics state parameter dictionary", and of op
  # "If this entry is absent, the OP entry, if any, shall also set this
  # parameter." So a dictionary carrying /OP and no /op governs filling as
  # well - measured with poppler on 2026-08-26, "overprint -stroke 1" over a
  # cyan panel turned a yellow FILL green. That is the opposite of what
  # "an option left out is not written" promises, so the fill side is
  # written out whenever the stroke side is named: from -fill if the call
  # names it, from the fill overprint in force otherwise. See
  # [GraphicsOverprint].
  method overprint {args} {
    set options [::tclpdf::option parse {fill {} stroke {} mode {}} \
        $args overprint]
    set name [my GraphicsOverprint $options]
    my content "[::tclpdf::pdfObj name $name] gs\n"
    # Unlike a shape's -overprint this is NOT inside a q/Q: it stands until
    # changed, and the next call that names only -stroke has to know what
    # the fill side is. Remembered per stream and taken back by [restore],
    # exactly as the colours of [style] are.
    my GraphicsOverprintRemember $options
    return $name
  }

  # What the fill side of the overprint is at this moment in this stream, as
  # a boolean. Empty - never set - is false: 8.6.7 gives both parameters an
  # initial value of false.
  method GraphicsOverprintFill {} {
    set value [my streamState overprintFill]
    return [expr {$value eq {} ? 0 : $value}]
  }

  # And the record. Only calls that stand OUTSIDE a q/Q write it: a shape's
  # own -overprint is taken back by the Q that closes the shape, and
  # remembering it would leave the document believing in a state the reader
  # has already dropped.
  # Only -fill moves it. A call that names -stroke alone writes the fill side
  # out (see [GraphicsOverprint]) but writes it UNCHANGED, whichever of the
  # two spellings the dictionary uses - so there is nothing to record.
  # The MODE is remembered beside it, and for a second reason: /OPM 1 is the
  # one graphics state value that PDF/A forbids in company (ISO 19005-2 and
  # -3, 6.2.4.2: not 1 while an ICCBased CMYK space is overprinted). Knowing
  # what is in force is what lets that combination be caught at all - see
  # [GraphicsOverprintIcc]. Not scoped by -fill/-stroke: OPM is one value for
  # both sides (Table 58).
  method GraphicsOverprintRemember {options} {
    if {[dict get $options fill] ne {}} {
      my streamState overprintFill [expr {[dict get $options fill] ? 1 : 0}]
    }
    if {[dict exists $options mode] && [dict get $options mode] ne {}} {
      my streamState overprintMode [dict get $options mode]
    }
    return
  }

  # The resource without the operator, so a shape can put its "gs" inside its
  # own q/Q - the same separation [GraphicsOpacity] makes, and for the same
  # reason: an overprint that leaks into the rest of the page is worse than
  # one that was never set, because nothing on screen shows it.
  method GraphicsOverprint {options} {
    # Every value first, nothing written and nothing recorded: a refused
    # -mode used to leave an ExtGState behind for the -fill before it.
    set values {}
    foreach option {stroke fill} {
      set value [dict get $options $option]
      if {$value eq {}} {
        continue
      }
      if {![string is boolean -strict $value]} {
        return -code error \
            -errorcode [list TCLPDF GRAPHICS OVERPRINT $option] \
            "tclpdf: overprint -$option is true or false, not \"$value\""
      }
      dict set values $option [expr {$value ? 1 : 0}]
    }
    # THE FILL SIDE IS NEVER LEFT TO /OP (Table 58, see [overprint]). Naming
    # the stroke therefore says something about the fill as well, and what it
    # says is "unchanged": the value in force in this stream.
    if {[dict exists $values stroke] && ![dict exists $values fill]} {
      dict set values fill [my GraphicsOverprintFill]
    }
    set pairs {Type /ExtGState}
    set name GO
    # Both parameters and the same answer for each: that is what /OP alone
    # means, word for word, and writing it that way keeps the dictionary
    # inside PDF 1.2, where there is no /op at all. Two different answers, or
    # only one of the two known, need the two keys - and with them 1.3.
    if {[dict size $values] == 2
        && [dict get $values stroke] == [dict get $values fill]} {
      set flag [expr {[dict get $values stroke] ? {true} : {false}}]
      lappend pairs OP $flag
      append name Both $flag
    } else {
      foreach {option key} {stroke OP fill op} {
        if {![dict exists $values $option]} {
          continue
        }
        set flag [expr {[dict get $values $option] ? {true} : {false}}]
        lappend pairs $key $flag
        append name [string totitle $option] $flag
      }
    }
    set mode [dict get $options mode]
    if {$mode ne {}} {
      # 0 or 1, and nothing else: Table 58 gives OPM those two values, and a
      # 2 would be written into the file and mean whatever a reader made of
      # it.
      if {$mode ni {0 1}} {
        return -code error -errorcode [list TCLPDF GRAPHICS OVERPRINT mode] \
            "tclpdf: overprint -mode is 0 or 1, not \"$mode\" - 0 leaves a\
            plate alone where its value is zero, 1 paints it at nought"
      }
      lappend pairs OPM $mode
      append name Mode $mode
    }
    if {[llength $pairs] == 2} {
      return -code error -errorcode [list TCLPDF GRAPHICS OVERPRINT NONE] \
          "tclpdf: overprint takes at least one of -fill, -stroke and -mode -\
          a call naming none of them would write a graphics state that\
          changes nothing"
    }
    # /OP is PDF 1.2, /op and /OPM are 1.3 (Table 58). Asked for what the
    # call actually WRITES rather than for the options it was given: a
    # dictionary of /OP alone is a 1.2 dictionary whichever option produced
    # it, and one that has to spell the two sides apart is a 1.3 one.
    if {[lsearch -exact $pairs op] >= 0 || $mode ne {}} {
      my RequireVersion 1.3 "overprint with a fill side of its own, and -mode"
    } else {
      my RequireVersion 1.2 "overprint"
    }
    if {[my resource ExtGState $name] eq {}} {
      my resource ExtGState $name [[my writer] ref [[my writer] add \
          [::tclpdf::pdfObj dictionary $pairs]]]
    }
    return $name
  }

  # THE ONE COMBINATION PDF/A FORBIDS OUTRIGHT: an overprinted fill or stroke
  # in an ICCBased CMYK space while /OPM is 1. ISO 19005-2 and -3, 6.2.4.2:
  # "the value of the OPM key ... shall not be 1 when an ICCBased CMYK
  # colour space is used for fill and overprinting for fill is set to true";
  # veraPDF reports it as 6.2.4.2-2, and measured on 2026-08-27 the package
  # wrote such a file without a word - "pdfa -part 3", "overprint -mode 1
  # -fill 1", a fill of {icc press 0 1 1 0}, isCompliant="false". With
  # {cmyk 0 1 1 0} the same drawing is conformant, which is what makes it a
  # combination rather than a value: neither half is wrong on its own, and
  # neither half knows about the other.
  #
  # NOTHING IS REFUSED HERE. The fact is recorded and the refusal is made at
  # the WRITE ([GraphicsOverprintBeforeWrite]), which is what the manual
  # promises of every PDF/A refusal ("refuses at the write whatever does not
  # fit the intent, naming the call") and the only way to catch both orders:
  # the claim may be made after the drawing as easily as before it.
  #
  # What is NOT seen: the stroke side of a stream-level [overprint -stroke],
  # which this package does not remember at all (only the fill side is, see
  # [GraphicsOverprintFill]), and a colour set by [text] rather than through
  # a shape's -fill. Both would be over-refusals to guess at; what is caught
  # is every road that states the colour and the overprint in the calls this
  # module owns.
  method GraphicsOverprintIcc {parsed which options what} {
    if {[my streamState overprintMode] ne "1"} {
      return
    }
    if {[lindex $parsed 0] ne "icc"} {
      return
    }
    lassign [lindex $parsed 1] alias values
    # CMYK is four components - the profile said so when it was embedded,
    # and the colour carries as many as the profile takes ([IccColourUsed]
    # refuses any other count).
    if {[llength $values] != 4} {
      return
    }
    # Is this side overprinted at this moment? A shape's own -overprint sets
    # both sides for the length of its q/Q; otherwise only the fill side is
    # on record.
    if {[dict exists $options overprint] && [dict get $options overprint] ne {}} {
      set on [expr {[dict get $options overprint] ? 1 : 0}]
    } else {
      set on [expr {$which eq "fill" ? [my GraphicsOverprintFill] : 0}]
    }
    if {!$on} {
      return
    }
    set where "$what -$which \{icc $alias ...\}"
    set page [my page current]
    if {$page >= 0} {
      append where " on page [expr {$page + 1}]"
    }
    set seen [my state overprintIcc]
    if {$where ni $seen} {
      lappend seen $where
      my state overprintIcc $seen
    }
    # Subscribed on the first one and never again, the arrangement [save]
    # keeps for the unbalanced "q".
    if {[my state overprintIccHooked] eq {}} {
      my state overprintIccHooked 1
      my onSelf beforeWrite GraphicsOverprintBeforeWrite
    }
    return
  }

  # And the refusal, at the write, when a PDF/A claim stands.
  #
  # The claim is read out of the state directly rather than through
  # [pdfa state]: that method belongs to a module which is loaded on its
  # first call, and asking it here would pull the PDF/A machinery and tdom
  # into every document that ever overprinted. An empty key means no claim
  # was ever made, and then there is nothing to check.
  method GraphicsOverprintBeforeWrite {} {
    if {[my state pdfa] eq {} || ![llength [my state overprintIcc]]} {
      return
    }
    return -code error -errorcode [list TCLPDF GRAPHICS OVERPRINT pdfa] \
        "tclpdf: PDF/A forbids an overprinted ICC based CMYK colour while\
        the overprint mode is 1 (ISO 19005-2 and -3, 6.2.4.2) -\
        [join [my state overprintIcc] {, }]; use \"overprint -mode 0\", or\
        paint that colour as {cmyk ...} rather than through the profile"
  }

  # The sixteen standard modes (11.3.5). Deliberately NOT accepted:
  #
  #   Compatible - deprecated since 1.4 and identical to Normal, so it says
  #   nothing a reader could act on. The array form of /BM is deprecated too;
  #   this writes a single name.
  #
  # PDF/A: parts 2 and 3 permit every standard mode, and part 1 - which allows
  # only Normal - is refused by [pdfa] for other reasons anyway, so there is
  # nothing to check here.
  method GraphicsBlend {mode} {
    set known {Normal Multiply Screen Overlay Darken Lighten ColorDodge
        ColorBurn HardLight SoftLight Difference Exclusion Hue Saturation
        Color Luminosity}
    set match [lsearch -exact -nocase $known $mode]
    if {$match < 0} {
      if {[string equal -nocase $mode Compatible]} {
        return -code error -errorcode [list TCLPDF GRAPHICS BLEND Compatible] \
            "tclpdf: the blend mode Compatible is deprecated\
            and means Normal - name Normal instead"
      }
      return -code error -errorcode [list TCLPDF GRAPHICS BLEND $mode] \
          "tclpdf: unknown blend mode \"$mode\" - known are:\
          [join $known {, }]"
    }
    # The spelling of the standard, whatever the caller typed: a name is a
    # name, and /multiply is not /Multiply to a reader.
    set mode [lindex $known $match]
    # Blend modes came with transparency in PDF 1.4 (Reference 1.7, 7.2.4).
    my RequireVersion 1.4 "blend"
    set name GB$mode
    if {[my resource ExtGState $name] eq {}} {
      my resource ExtGState $name [[my writer] ref [[my writer] add \
          [::tclpdf::pdfObj dictionary [list Type /ExtGState \
              BM [::tclpdf::pdfObj name $mode]]]]]
    }
    return $name
  }

  # The resource without writing the operator - so that a shape can put the
  # "gs" INSIDE its own q/Q instead of leaking the alpha into the rest of the
  # page. Writing it from here directly used to place it before the "q" that
  # GraphicsStyle now emits, which is exactly the leak this separation ends.
  method GraphicsOpacity {value {which both}} {
    # [finite] rather than "string is double": NaN is a double to Tcl and
    # compares false against BOTH bounds, so "< 0 || > 1" let it through and
    # the ExtGState was written with a /ca of NaN - measured 2026-08-26,
    # "opacity NaN" answered {TCL VALUE DOUBLE NAN} from deep inside [num].
    if {![::tclpdf::option finite $value] || $value < 0 || $value > 1} {
      return -code error -errorcode [list TCLPDF GRAPHICS OPACITY value] \
          "tclpdf: opacity is a number from 0 to 1, not \"$value\""
    }
    # Refused rather than shrugged off: an unknown side used to produce an
    # ExtGState with neither ca nor CA - a resource that changes nothing, and
    # a call that did nothing without a word.
    if {$which ni {fill stroke both}} {
      return -code error -errorcode [list TCLPDF GRAPHICS OPACITY $which] \
          "tclpdf: opacity applies to fill, stroke or both,\
          not \"$which\""
    }
    # /ca and /CA are PDF 1.4 (Reference 1.7, Table 4.8). Checked after the
    # value, so that a wrong number is still reported as a wrong number.
    my RequireVersion 1.4 "opacity"
    set pairs {Type /ExtGState}
    if {$which in {fill both}} {
      lappend pairs ca [::tclpdf::pdfObj num $value]
    }
    if {$which in {stroke both}} {
      lappend pairs CA [::tclpdf::pdfObj num $value]
    }
    # One resource per distinct value, reused across the document: a name
    # derived from the value is what makes that automatic - from the value
    # as the file spells it, not as the caller typed it. Measured before
    # 2026-08-18 the name was built from the caller's text, and 0.5, .5,
    # 0.50 and 5e-1 were four ExtGState objects with the same /ca.
    set name GS[string map {. _ - m} [::tclpdf::pdfObj num $value]][string index $which 0]
    if {[my resource ExtGState $name] eq {}} {
      my resource ExtGState $name \
          [[my writer] ref [[my writer] add [::tclpdf::pdfObj dictionary $pairs]]]
    }
    return $name
  }

  # -- shared internals ---------------------------------------------------

  # Does this call set anything that outlives the shape?
  #
  # Colour, line width, dash, caps, joins and alpha are all GRAPHICS STATE
  # (8.4.1): they survive the painting operator and apply to everything drawn
  # afterwards. So "rect -width 3 -dash {2 2}" used to make the NEXT line thick
  # and dashed as well, with nothing in that call to explain it - measured in
  # the content stream. A shape that sets any of them is therefore wrapped in
  # q/Q by GraphicsStyle and GraphicsPaint together.
  #
  # [style] deliberately does NOT guard: its whole purpose is to set the state
  # until changed, which is what the manual promises.
  method GraphicsGuarded {options} {
    foreach key {fill stroke width dash cap join miter opacity blend overprint} {
      if {[dict exists $options $key] && [dict get $options $key] ne {}} {
        return 1
      }
    }
    return 0
  }

  # Colour, line width, dash and joins - the part every shape needs and none
  # of them should spell out. "what" names the calling command - "rect",
  # "style" - for the colour space record, see [ColourUsed].
  method GraphicsStyle {options guard what} {
    # The operators are assembled and every value checked BEFORE the mark is
    # taken and the "q" is written: a refused cap or colour used to leave the
    # structure state believing a mark was open, and the next shape on the
    # page then went unmarked. Nothing here writes; the caller does, once.
    #
    # The colours come LAST, once every other value has passed, and are put
    # in FRONT of the result - the stream reads "rg ... w ... d" as it always
    # did. Last, because translating a colour records its space for the
    # PDF/A intent check ([ColourUsed]): done first, a refused width left a
    # record of a colour that never reached the stream, and a later write
    # under [pdfa] named a rectangle that was not there.
    set result {}
    # The fill rule is read by GraphicsPaint, but checked here, with the
    # rest: by the time the painting operator is derived the mark below has
    # been taken. Anything but the two names of 8.5.3.3 used to paint
    # nonzero without a word.
    if {[dict exists $options rule] && [dict get $options rule] ni {nonzero evenodd}} {
      return -code error -errorcode [list TCLPDF GRAPHICS ARGUMENT rule] \
          "tclpdf: -rule is nonzero or evenodd, not\
          \"[dict get $options rule]\""
    }
    if {[dict exists $options opacity] && [dict get $options opacity] ne {}} {
      append result "[::tclpdf::pdfObj name \
          [my GraphicsOpacity [dict get $options opacity]]] gs\n"
    }
    # A second "gs" rather than one combined state: the operator is cumulative
    # (11.6.6), so setting the mode leaves the alpha standing and the two stay
    # one resource each instead of one per combination.
    if {[dict exists $options blend] && [dict get $options blend] ne {}} {
      append result "[::tclpdf::pdfObj name \
          [my GraphicsBlend [dict get $options blend]]] gs\n"
    }
    # -overprint on a shape is BOTH sides, since a shape that is filled and
    # stroked in one call has no way of saying which it meant. The three
    # switches apart are what [overprint] is for; here the question is only
    # whether this shape knocks out what is under it.
    if {[dict exists $options overprint]
        && [dict get $options overprint] ne {}} {
      set value [dict get $options overprint]
      set overprintOptions [dict create fill $value stroke $value mode {}]
      append result "[::tclpdf::pdfObj name \
          [my GraphicsOverprint $overprintOptions]] gs\n"
      # [style] sets the state until changed and is not wrapped in q/Q, so
      # what it says about the fill side has to be remembered - the next
      # [overprint -stroke] reads it. A shape's own -overprint is inside the
      # bracket and is taken back by its Q; remembering that one would leave
      # the document believing in a state the reader has dropped.
      if {!$guard} {
        my GraphicsOverprintRemember $overprintOptions
      }
    }
    if {[dict exists $options width] && [dict get $options width] ne {}} {
      # Zero is allowed and means the thinnest line the device can draw
      # (8.4.3.2); less than that is not a width.
      set width [dict get $options width]
      if {![string is double -strict $width] || $width < 0} {
        return -code error -errorcode [list TCLPDF GRAPHICS ARGUMENT width] \
            "tclpdf: -width is a number of 0 or more, not \"$width\""
      }
      append result "[::tclpdf::pdfObj num [my distance $width]] w\n"
    }
    if {[dict exists $options dash] && [dict get $options dash] ne {}} {
      set dash [dict get $options dash]
      if {$dash in {none solid {}}} {
        append result "\[\] 0 d\n"
      } else {
        # 8.4.3.6: the lengths shall be non-negative and not all zero - an
        # all-zero array would ask for a line made of nothing, and a reader
        # is free to do anything with it, including nothing at all.
        #
        # AND "ABOVE ZERO" MEANS IN THE FILE. The array is written in points
        # with five decimals (7.3.3), so "-dash {1e-6 1e-6}" - two numbers
        # that are plainly above zero to Tcl - went out as "[0 0] 0 d",
        # measured 2026-08-27: exactly the array 8.4.3.6 forbids, past a
        # check that was looking at the caller's numbers. [pdfObj written]
        # is the one place that question is asked; the length is converted
        # first, because points are what the file carries and a millimetre
        # rounds elsewhere.
        set positive 0
        foreach number $dash {
          if {![string is double -strict $number] || $number < 0} {
            return -code error -errorcode [list TCLPDF GRAPHICS ARGUMENT dash] \
                "tclpdf: -dash takes lengths of 0 or more,\
                not \"$number\""
          }
          if {[::tclpdf::pdfObj written [my distance $number]] > 0} {
            set positive 1
          }
        }
        if {!$positive} {
          return -code error -errorcode [list TCLPDF GRAPHICS ARGUMENT dash] \
              "tclpdf: -dash needs at least one length above\
              zero in the file - {[join $dash { }]} is written as an array of\
              zeros (a PDF real carries five decimals, 7.3.3) and would draw\
              nothing"
        }
        set lengths [lmap number $dash {::tclpdf::pdfObj num [my distance $number]}]
        append result "\[[join $lengths { }]\] 0 d\n"
      }
    }
    if {[dict exists $options cap] && [dict get $options cap] ne {}} {
      set caps {butt 0 round 1 square 2}
      set cap [dict get $options cap]
      if {![dict exists $caps $cap]} {
        return -code error -errorcode [list TCLPDF GRAPHICS ARGUMENT cap] \
            "tclpdf: line cap must be butt, round or square,\
            not \"$cap\""
      }
      append result "[dict get $caps $cap] J\n"
    }
    if {[dict exists $options join] && [dict get $options join] ne {}} {
      set joins {miter 0 round 1 bevel 2}
      set style [dict get $options join]
      if {![dict exists $joins $style]} {
        return -code error -errorcode [list TCLPDF GRAPHICS ARGUMENT join] \
            "tclpdf: line join must be miter, round or bevel,\
            not \"$style\""
      }
      append result "[dict get $joins $style] j\n"
    }
    if {[dict exists $options miter] && [dict get $options miter] ne {}} {
      # The limit is the ratio of miter length to line width and cannot be
      # under 1 (8.4.3.5) - 1 already bevels every join.
      # NaN passes "string is double" and compares false against every
      # bound, so "< 1" waved it through and it died in [num] - or, worse,
      # reached the file. Asked with the one predicate the package has for
      # the question (option.tcl).
      # And a number the file can hold (Annex C.2, about +/-3.403e38), asked
      # through [pdfObj fits] where that figure stands. Without it "-miter
      # 1e39" walked past both bounds above and died one line further down
      # in [pdfObj num] under TCLPDF PDFOBJ NUMBER - the LAST line of
      # defence answering for a value this call had already read, and a
      # foreign error class for a caller who is catching this command's own.
      # Measured 2026-08-27.
      set miter [dict get $options miter]
      if {![::tclpdf::option finite $miter] || $miter < 1
          || ![::tclpdf::pdfObj fits $miter]} {
        return -code error -errorcode [list TCLPDF GRAPHICS ARGUMENT miter] \
            "tclpdf: -miter is a number from 1 to about 3.403e38 (the range\
            of a PDF real, ISO 32000-1 Annex C.2), not \"$miter\""
      }
      append result "[::tclpdf::pdfObj num $miter] M\n"
    }
    set colours {}
    foreach {key which} {fill fill stroke stroke} {
      if {[dict exists $options $key] && [dict get $options $key] ne {}} {
        set parsed [::tclpdf::color parse \
            [my GraphicsColour [dict get $options $key] $what]]
        my GraphicsOverprintIcc $parsed $which $options $what
        append colours [::tclpdf::color operator $parsed $which] "\n"
      }
    }
    set result $colours$result
    # In a tagged document a shape is marked content like anything else:
    # inside an open Figure it belongs to that Figure, and everywhere else it
    # is decoration and says so. Under PDF/UA content that is neither counts
    # as a defect.
    #
    # The bracket opens here and closes in GraphicsPaint, the two ends of
    # every primitive in this package - seven methods share them, and putting
    # it in each of them is how the pair drifts apart. The mark travels
    # through the state because the two are separate calls; shapes do not
    # nest, so one slot is enough. Taken LAST, once nothing above can refuse
    # any more - the mark changes state the moment it is taken.
    #
    # And taken only for a SHAPE - "guard" is what tells a shape from
    # [style]. A style call paints nothing: its operators are graphics
    # state, which no marked-content bracket has to enclose, and nothing
    # of it reaches GraphicsPaint, where the bracket is closed. Measured
    # before 2026-08-18: in a tagged document [style] opened an artifact
    # BDC that nothing closed, and every shape and every text after it sat
    # unmarked inside that bracket (14.6.1; PDF/UA-1 7.1).
    set prologue {}
    if {$guard && [my state tagged] eq "1"} {
      set mark [my StructureMark auto]
      my state structureShape $mark
      append prologue [my StructureBegin $mark]
    }
    if {$guard && [my GraphicsGuarded $options]} {
      append prologue "q\n"
    }
    return $prologue$result
  }

  # A caller's point - -at, -from, -to, -center, -focus - as PDF
  # coordinates, refused unless it is exactly two numbers. [coords] takes a
  # third argument, the page whose height to mirror against, and a point
  # with a third number used to hand it that number: {20 20 1} landed
  # mirrored against page 2, or died on a page that did not exist, with
  # nothing to say the point was the problem. Every site that turns an
  # option into a point goes through here; "option" and "what" name them
  # in the refusal ("-at of image place").
  method GraphicsPoint {value option what} {
    if {[llength $value] != 2} {
      return -code error -errorcode [list TCLPDF GRAPHICS POINT $option] \
          "tclpdf: $option of $what is a point {x y}, not\
          \"$value\""
    }
    # AND TWO NUMBERS A PAGE HAS ROOM FOR. The shape is checked above, in
    # this module's own words - four test files read them, and the wording
    # is a promise like any other. What was missing is the value: a NaN
    # coordinate has the right shape, passes [string is double], and dies in
    # the arithmetic of [coords] far from the call that wrote it. Asked here
    # per coordinate rather than handed to option::point whole, so that both
    # halves of the answer keep the words they had.
    foreach coordinate $value {
      # ONLY over what is a double at all. A word is not a coordinate
      # either, but [geometry toPoints] has said so in its own words since
      # the beginning and four test files read them; what was missing is the
      # double that is not a number, and that is what this asks about.
      if {[string is double -strict $coordinate]} {
        ::tclpdf::option number $coordinate $option $what
      }
    }
    return [my coords {*}$value]
  }

  # Translate a caller's colour into one the colour module can read.
  #
  # Only {pattern <name>} needs translating, and it needs it here because the
  # caller's name is a document-wide alias while the content stream wants the
  # resource name. The colour module knows colour spaces, the document knows
  # names - neither could do this alone. Everything else is not translated
  # but RECORDED on the way through - which colour space "what" is about to
  # paint in - and a separation is registered as well: the operator names a
  # colour space resource that has to exist, and color.tcl writes it on
  # first use.
  method GraphicsColour {spec what} {
    if {[llength $spec] == 2 && [string tolower [lindex $spec 0]] eq "pattern"} {
      package require tclpdf::pattern
      return [list pattern [my PatternResource [lindex $spec 1]]]
    }
    # The Separation colour space is PDF 1.2 (Reference 1.7, Table 4.12);
    # gated in [ColourUsed] behind the separation's own checks, so a
    # refused separation does not pin the version floor.
    return [my ColourUsed $spec $what]
  }

  # The painting operator. Six spellings, and the wrong one draws nothing at
  # all without any error - which is why this is derived rather than typed.
  method GraphicsPaint {options {guard 0}} {
    # A shape paints what it names - and what [style] named before it, for
    # the sides it left unnamed: the colour operators are in the stream
    # already, only the painting operator has to know. A shape that cannot
    # take a side at all (a line has no -fill) is not given it either.
    set hasFill [expr {[dict exists $options fill]
        && ([dict get $options fill] ne {} || [my streamState styleFill] ne {})}]
    set hasStroke [expr {[dict exists $options stroke]
        && ([dict get $options stroke] ne {} || [my streamState styleStroke] ne {})}]
    set evenOdd [expr {[dict exists $options rule]
        && [dict get $options rule] eq "evenodd"}]
    # The counterpart to the "q" GraphicsStyle wrote - the same condition, so
    # the two cannot get out of step.
    set close [expr {$guard && [my GraphicsGuarded $options] ? "Q\n" : ""}]
    # And the counterpart to the bracket it opened. It goes AFTER the Q, so
    # the marked content encloses the whole thing rather than crossing it -
    # BDC and q have to nest, not overlap (14.6.1).
    if {[my state tagged] eq "1"} {
      set mark [my state structureShape]
      my state structureShape {}
      append close [my StructureEnd $mark]
    }
    if {$hasFill && $hasStroke} {
      return [expr {$evenOdd ? "B*\n" : "B\n"}]$close
    }
    if {$hasFill} {
      return [expr {$evenOdd ? "f*\n" : "f\n"}]$close
    }
    if {$hasStroke} {
      return "S\n$close"
    }
    # Neither given: end the path without painting, so the path construction
    # does not leak into whatever comes next.
    return "n\n$close"
  }

}

package provide tclpdf::graphics 1.9