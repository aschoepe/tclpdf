#
# tclpdf examples - what more than one example does the same way
#
#   source [file join $here common.tcl]
#   ...
#   exampleFooter $doc ?family?
#
# Every example puts the same footer on its last page, and for a while every
# example carried its own copy of it. Eighteen copies of ten lines is how a
# block starts drifting: one gets a fix, the others do not, and nobody notices
# because each file on its own still looks right. So it lives here once.
#
# The rule since then is the same one the package follows: a block that turns
# up in a SECOND example moves here, at once, rather than being copied. The
# footer was the first, [exampleIccFacts] came with the pair 05.11/05.12, and
# the openssl scaffolding at the end of this file with the pair 08.01/08.02.
# Nothing here runs while the file is sourced, and nothing here requires a
# topical package - every example in the tree loads it, whatever it is about.
#
# The price is that an example is no longer a single file you can lift out of
# the tree and run. That is the trade, made knowingly - the assets next door
# are needed just as much, so an example was never self-contained anyway.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).

# Draw the footer: which script drew the page, and which font is in the file.
#
# Both are read back OUT OF THE DOCUMENT rather than passed in, so the footer
# cannot claim a face the file does not carry. A page that turns up on a desk
# months later then answers the two questions it otherwise cannot: where does
# this come from, and is the type embedded or a standard face.
#
# The family is left alone by default, because a PDF/A document may not fall
# back to Helvetica and an example ending on an embedded face must keep it.
# Pass one where the page ends on a face that cannot set the footer - a symbol
# font, or one without the punctuation the line needs.
proc exampleFooter {doc {family {}} {colour {0.45 0.45 0.5}}} {
    # [info script] inside a proc reports the file being sourced right now,
    # which by the time this runs is the example again - common.tcl is long
    # finished. Checked under both interpreters; without that it would name
    # this file in every footer.
    set script [file tail [info script]]

    set aliases [$doc font names]
    set fonts {}
    foreach alias $aliases {
        lappend fonts [dict get [$doc font info $alias] family]
    }
    # An "if", not an "expr": expr normalises what it returns, and a value that
    # only looks like a number comes back changed. That cost this package a
    # defect once already, in the line breaker.
    set families [lsort -unique $fonts]
    if {[llength $fonts]} {
        set fonts "embedded: [join $families {, }]"
    } else {
        set fonts "standard faces, nothing embedded"
    }

    lassign [$doc page size] width height

    # The footer leaves NO state of its own behind. It sets a face, a size and
    # a colour, and font state carries from one page to the next - so without
    # this the next page began in the footer's grey and its face (Courier or
    # Helvetica-Bold, whichever the page happened to end on). Read the caller's
    # state, restore it at the end, and the footer is transparent to the page.
    set saved [$doc font]
    dict unset saved resolved

    # The footer's own face, CHOSEN here rather than inherited. Inherited, it
    # took whatever the page happened to end on: Courier after a block of code
    # (03.06, 03.07, 06.03, 08.01, 08.03), Helvetica-Bold after a heading
    # (01.06), and in 03.08 a different face on each of the two pages of one
    # document. Nobody chose any of that.
    #
    # Helvetica where a standard face is allowed at all. Where the document
    # embeds faces it may be an archivable one, and PDF/A refuses a standard
    # font outright - measured: with Helvetica forced here, 05.01, 05.02 and
    # 05.13 stop at "PDF/A requires every font to be embedded". So there the
    # first face the document embedded sets the line, which is the body face
    # in every example that gets this far.
    if {$family eq {}} {
        if {[llength $aliases]} {
            set family [lindex $aliases 0]
        } else {
            set family helvetica
        }
    }
    # The colour is a parameter for one reason: a document under a CMYK
    # output intent (05.09) may not paint DeviceRGB, footer included.
    $doc font -family $family -style {} -size 6 -color $colour
    # A footer that names twelve families (02.09, whose thirteen embedded
    # faces are twelve families because two of them are cuts of Noto Sans) is
    # wider than the page and ran off its left edge - measured 243 mm on A4.
    # Where the list does not fit between the margins, the count stands in for
    # it; the page that embeds that many has a table of them anyway. The count
    # is of FAMILIES, because that is what $families holds - a face is a cut
    # of a family, and the footer above lists family names.
    if {[$doc textWidth "$script - $fonts"] > $width - 20} {
        set fonts "embedded: [llength $families] font families"
    }
    # -tag Artifact: a footer is a fact about the sheet, not about the text,
    # and in a tagged document it has to say so or a reader announces it as
    # content. Harmless everywhere else - an untagged document ignores it.
    $doc text "$script - $fonts" \
        -at [list [expr {$width - 10}] [expr {$height - 7}]] -align right \
        -tag Artifact

    # Put the caller's font state back, so a footer drawn on one page leaves
    # the next to begin exactly as it would have without it.
    set restore {}
    dict for {key value} $saved {
        lappend restore -$key $value
    }
    $doc font {*}$restore
}

# What an archivable example reports when it is done: the level it declared
# and the faces the file carries.
#
# Both are read back OUT of the document rather than repeated from the script
# above, so the line cannot claim a conformance the file does not have or a
# font it does not carry - the same reason the footer asks the document for
# its fonts.
proc exampleArchival {doc} {
    set state [$doc pdfa state]
    return "PDF/A-[dict get $state part][dict get $state conformance],\
        fonts: [join [$doc font names] {, }]"
}

# The closing lines of an ARCHIVABLE example: footer, write, and the two
# console lines that say what came out.
#
# Only for the PDF/A ones - the others end with a plain [write] and have
# nothing to report beyond the file name. Pulled out when the third example
# had the same seven lines; [exampleArchival] alone was not enough, because
# what repeated was the whole ending.
proc exampleDone {doc target {family {}} {colour {0.45 0.45 0.5}}} {
    exampleFooter $doc $family $colour
    $doc write $target
    puts "  written: $target"
    puts "  [exampleArchival $doc]"
    $doc destroy
}

# What an ICC profile says about itself, read off its bytes - for the pair of
# examples 05.11/05.12 that write the same page under two sRGB profiles and
# print the difference rather than assert it. Returns a dictionary:
#
#   size (bytes on disk) flate (bytes as the Flate stream a PDF carries -
#   the number that counts for the document, and not what the disk size
#   suggests: the 1024-point curves of the older profile compress well)
#   version class space desc cprt wtpt (three numbers) chad (0|1)
#   bkpt (three numbers or {}) tags (the tag signatures)
#
# ICC.1 header: version at 8, class at 12, data colour space at 16; the tag
# table at 128 (count, then signature/offset/length triples). desc is either
# a v2 'desc' record (ASCII, length at 8) or a v4 'mluc'; cprt a 'text'
# record. Nothing else of the format is needed here.
proc exampleIccFacts {path} {
    set f [open $path rb]
    set bytes [read $f]
    close $f
    binary scan $bytes @8cu4a4a4 v class space
    lassign $v v0 v1
    set version [format %d.%d $v0 [expr {$v1 >> 4}]]
    binary scan $bytes @128Iu count
    set tags {}
    set table {}
    for {set i 0} {$i < $count} {incr i} {
        binary scan $bytes @[expr {132 + 12 * $i}]a4IuIu sig off len
        lappend tags $sig
        dict set table $sig [list $off $len]
    }
    set facts [dict create size [string length $bytes] \
        flate [string length [zlib compress $bytes 9]] version $version \
        class [string trim $class] space [string trim $space] tags $tags \
        desc {} cprt {} wtpt {} chad [dict exists $table chad] bkpt {}]
    if {[dict exists $table desc]} {
        lassign [dict get $table desc] off len
        binary scan $bytes @${off}a4 type
        if {$type eq "desc"} {
            binary scan $bytes @[expr {$off + 8}]Iu n
            binary scan $bytes @[expr {$off + 12}]a[expr {$n - 1}] text
            dict set facts desc $text
        } elseif {$type eq "mluc"} {
            binary scan $bytes @[expr {$off + 20}]IuIu n first
            dict set facts desc [encoding convertfrom unicode \
                [string range $bytes [expr {$off + $first}] [expr {$off + $first + $n - 1}]]]
        }
    }
    if {[dict exists $table cprt]} {
        lassign [dict get $table cprt] off len
        binary scan $bytes @${off}a4 type
        if {$type eq "text"} {
            binary scan $bytes @[expr {$off + 8}]a[expr {$len - 9}] text
            dict set facts cprt [string trimright $text \0]
        }
    }
    foreach tag {wtpt bkpt} {
        if {[dict exists $table $tag]} {
            lassign [dict get $table $tag] off len
            binary scan $bytes @[expr {$off + 8}]III x y z
            dict set facts $tag [lmap n [list $x $y $z] {format %.4f [expr {$n / 65536.0}]}]
        }
    }
    return $facts
}

# ---------------------------------------------------------------------------
# What the signature examples share
# ---------------------------------------------------------------------------
#
# 08.01 (an invisible signature), 08.02 (a visible one), 08.03 (a second
# signature appended to a finished file), 08.04 (a signed ZUGFeRD invoice) and
# 08.05 (a described signature in a PDF/UA-1 tree) show five different things
# about the same mechanism, and all five need the same outside world to show
# it: a test CA, an end certificate under it, a command prefix that answers a
# CMS object, and a way to ask openssl what it thinks of its own work. All of
# that stood twice, line for line, until it moved here.
#
# NOTHING BELOW RUNS WHILE THIS FILE IS SOURCED. Eighty of the 81 examples
# load it - 00.01 is the one that does not, because it is about how little it
# takes - and 75 of them have nothing to do with signatures, so there is no
# [package require tclpdf::sign] here, no openssl call, and no work in the
# body - procedures only, called by the five examples that want them.
#
# What is NOT here is what those five differ in, and that is the larger half:
# the wording on their pages, the appearance form 08.02 draws, the dates it
# needs for it, and the [$doc sign] calls themselves. A signature example
# whose central call sat behind a helper would be showing the helper.

# Every call to an outside program goes through here for one reason: openssl
# writes its progress to stderr, and [exec] turns any stderr output at all
# into an error. "2>@1" merges the two, so the EXIT STATUS decides - which is
# what it is for.
proc exampleRun {args} {
    return [exec {*}$args 2>@1]
}

# Bytes in and out, with -translation binary ALONE: Tcl 9 no longer knows the
# channel encoding "binary", and the translation setting picks the
# byte-transparent encoding by itself.
proc exampleReadBinary {path} {
    set channel [open $path r]
    fconfigure $channel -translation binary
    set data [read $channel]
    close $channel
    return $data
}

proc exampleWriteBinary {path data} {
    set channel [open $path w]
    fconfigure $channel -translation binary
    puts -nonewline $channel $data
    close $channel
}

# A temporary directory, made the way both interpreters can: [file tempfile]
# hands out a unique NAME as well as a channel, and a directory of that name
# is then ours alone. [file tempdir] would be shorter and exists in Tcl 9 only.
proc exampleTempDirectory {} {
    set channel [file tempfile path]
    close $channel
    file delete $path
    file mkdir $path
    return $path
}

# A test CA and one end certificate under it. Measured on this machine: the
# pair takes 0.08 s.
#
# The two extensions on each are not decoration. A CA without
# basicConstraints CA:TRUE signs nothing a verifier accepts, and an end
# certificate without digitalSignature in its keyUsage is not a signing
# certificate - the second is what a reader checks before it looks at the
# digest at all.
proc exampleCertificates {dir} {
    exampleRun openssl req -x509 -newkey rsa:2048 \
        -keyout [file join $dir ca.key] -out [file join $dir ca.pem] \
        -days 3650 -nodes -subj "/C=DE/O=tclpdf test/CN=tclpdf test CA" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign"
    exampleWriteBinary [file join $dir leaf.cnf] \
        "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,nonRepudiation\n"
    # TWO end certificates under the one CA, because a document signed twice is
    # signed by two PEOPLE - and a reader takes the name from the CERTIFICATE,
    # not from /Name (Table 255 asks for /Name only "when it is not possible to
    # extract the name from the signature"). With one certificate for both,
    # Acrobat shows the same person twice however the dictionaries are filled,
    # which is exactly the wrong lesson for an example about countersigning.
    # A loop rather than a second copy of the block: the two differ in a name.
    foreach {stem person} {leaf "Erika Mustermann" second "Max Mustermann"} {
        exampleRun openssl req -newkey rsa:2048 \
            -keyout [file join $dir $stem.key] -out [file join $dir $stem.csr] \
            -nodes -subj "/C=DE/O=tclpdf test/CN=$person"
        exampleRun openssl x509 -req -in [file join $dir $stem.csr] \
            -CA [file join $dir ca.pem] -CAkey [file join $dir ca.key] \
            -CAcreateserial -out [file join $dir $stem.pem] -days 730 \
            -extfile [file join $dir leaf.cnf]
    }
    return
}

# THE SIGNER. This is the whole of the outside world as tclpdf sees it: a
# command prefix that is handed the bytes and answers a CMS SignedData object
# in DER. It is called as "{*}$prefix $bytes", so the directory and the extra
# switches are bound in through the prefix and the bytes arrive last.
#
# "extra" is a list of further openssl arguments, and there is exactly one in
# use: 08.01 asks for -cades, which produces the CAdES-BES object that
# /SubFilter /ETSI.CAdES.detached promises, because that example is about the
# refusal such a claim runs into. 08.02 signs with the default profile and
# passes nothing. -binary keeps openssl from treating the bytes as text with
# line endings, which for the middle of a PDF would be fatal. Measured: 28 ms,
# and 2599 bytes of DER with an RSA-2048 certificate and its issuer in it.
#
# Both files stay where they are afterwards on purpose - [exampleOpensslVerify]
# needs exactly these two, the detached content and the signature over it.
proc exampleOpensslSigner {dir extra stem bytes} {
    exampleWriteBinary [file join $dir content.bin] $bytes
    exampleRun openssl cms -sign -binary -in [file join $dir content.bin] \
        -signer [file join $dir $stem.pem] -inkey [file join $dir $stem.key] \
        -certfile [file join $dir ca.pem] {*}$extra -md sha256 \
        -outform DER -out [file join $dir signature.der]
    return [exampleReadBinary [file join $dir signature.der]]
}

# The prefix for a signer other than the first - "second" is the countersigner
# of example 8.4. The first one comes ready-made from [exampleSigningSetup];
# this is for a script that needs a SECOND person, and it exists so that no
# example has to know how the prefix is put together.
proc exampleSigner {dir {stem leaf} {extra {}}} {
    return [list exampleOpensslSigner $dir $extra $stem]
}

# What openssl says about its own work, checked against the test CA. Not a
# formality: it is the one line in these scripts that would notice if the
# bytes handed to the signer were not the bytes the file ends up covering.
proc exampleOpensslVerify {dir} {
    if {[catch {
        exampleRun openssl cms -verify -inform DER \
            -in [file join $dir signature.der] \
            -content [file join $dir content.bin] -binary \
            -CAfile [file join $dir ca.pem] -purpose any -out /dev/null
    } answer]} {
        return "openssl says: [lindex [split $answer \n] 0]"
    }
    return "openssl cms -verify: successful, against the test CA"
}

# Whether there is a signature to be had, decided ONCE and before the first
# [$doc sign] call - not inside the signer. A signer that fails is a write
# that fails, and by then half a document is on disk; a missing openssl has to
# be known while the page is still being laid out, because the page says so.
#
# Answers three values for [lassign]:
#
#   dir     the temporary directory holding the certificates, {} if there are
#           none - hand it back to [exampleSigningEnd] when the script is done
#   signer  a command prefix ready for -signer, {} if openssl is unusable
#   why     why not, in a sentence, {} when there is a signer
#
# It prints NOTHING. What a missing signature means differs per document and
# is the example's sentence to write, on its page and on the console.
proc exampleSigningSetup {{extra {}}} {
    if {![llength [auto_execok openssl]]} {
        return [list {} {} "openssl was not found on the PATH"]
    }
    set dir [exampleTempDirectory]
    if {[catch {exampleCertificates $dir} message]} {
        file delete -force $dir
        return [list {} {} "openssl is here but would not make the\
            certificates: [lindex [split $message \n] 0]"]
    }
    return [list $dir [exampleSigner $dir leaf $extra] {}]
}

# The closing lines of a signature example: throw the test certificates away
# and print, for each document written, the commands a reader can check it
# with. "commands" is a command prefix called with the plain file name - the
# list differs per example, so the example that knows it supplies it.
#
# The heading counts the names it was handed rather than saying "both": three
# of the five callers (08.03, 08.04, 08.05) write ONE document, and the line
# used to promise a second one that is not there.
proc exampleSigningEnd {dir names commands} {
    if {$dir ne {}} {
        file delete -force $dir
    }
    switch -- [llength $names] {
        1 {puts "  check it with:"}
        2 {puts "  check both with:"}
        default {puts "  check each with:"}
    }
    foreach name $names {
        foreach line [{*}$commands [file tail $name]] {
            puts "    $line"
        }
    }
    return
}

# The three commands every signed file answers to, which is what the signature
# examples print and put on their pages; "extra" appends the lines one of them
# wants on top of that. Not a fourth and fifth line here with a switch to leave
# them out: what 08.01 adds needs the detached content only that script keeps.
proc exampleSignatureChecks {name {extra {}}} {
    return [concat [list \
        "pdfsig $name" \
        "qpdf --check $name" \
        "pdfsig -dump $name"] $extra]
}

# A paragraph on the CONSOLE, wrapped by hand. For the one thing a signature
# example prints that is longer than a line: the sentence tclpdf refuses
# something with, which is worth reading in full because it names the way out.
# 08.01 prints the refusal of a PAdES claim openssl cannot keep, 08.03 the one
# that comes back when a second signature is asked for over a first that is
# still waiting for its value.
#
# [regexp] rather than [foreach word $text] on purpose - a message has
# quotation marks in it and would not parse as a list.
proc exampleConsoleParagraph {text {width 74}} {
    set line "   "
    foreach word [regexp -all -inline {\S+} $text] {
        if {[string length $line] + [string length $word] >= $width} {
            puts $line
            set line "   "
        }
        append line " " $word
    }
    if {[string trim $line] ne {}} {
        puts $line
    }
    return
}

# Running text on a page of prose, top down. Eighteen examples set the same
# kind of page - the signature and form groups among them - and prose at
# hard-coded coordinates is how paragraphs start overlapping the day one of
# them gains a line: [text] with -width answers the y the next line would
# start at, so the page stays right.
#
# The 20 mm left margin and the 170 mm measure are an A4 page in mm with the
# margins those examples use. An example laid out otherwise sets its text
# itself rather than passing a fourth and fifth argument.
proc exampleHeading {doc yName text} {
    upvar 1 $yName y
    $doc font -family helvetica -style bold -size 11 -color {0 0 0}
    $doc text $text -at [list 20 $y]
    set y [expr {$y + 7}]
    return
}

proc examplePara {doc yName text {colour {0 0 0}}} {
    upvar 1 $yName y
    $doc font -family helvetica -style {} -size 10 -color $colour
    set y [expr {[$doc text $text -at [list 20 $y] -width 170] + 3}]
    return
}

# The same commands on the page, in courier, so that the file carries them
# when it is mailed on and the console is not there any more.
proc exampleCommandBlock {doc yName commands} {
    upvar 1 $yName y
    $doc font -family courier -style {} -size 8.5 -color {0 0 0}
    foreach command $commands {
        $doc text $command -at [list 20 $y]
        set y [expr {$y + 5}]
    }
    set y [expr {$y + 2}]
    return
}

# What could not be signed, said on the page rather than left to the reader to
# discover in a validator. The heading and the colour are the same in both
# examples; what follows is not, because what an unfilled placeholder means
# for an invisible field and for a visible one reads differently. So the
# sentence is the caller's.
proc exampleNotSigned {doc yName text} {
    upvar 1 $yName y
    exampleHeading $doc y "This document is NOT signed"
    examplePara $doc y $text {0.70 0.15 0.15}
    return
}

# The closing lines of a document that comes off the write SIGNED: footer,
# write, and what the finished file says about its own signature.
#
# The report is read back out of the document with [$doc sign state] rather
# than repeated from the [sign] call above, the same reason [exampleArchival]
# asks the document for its fonts: a line that states what was requested
# cannot notice when the file says something else.
#
# Only for the one-stage documents. The two-stage ones end with a plain write
# - their signature does not exist yet at that point, and what they have to
# report comes after [::tclpdf::sign embed] instead.
proc exampleSignatureDone {doc target dir} {
    exampleFooter $doc
    $doc write $target
    set state [$doc sign state]
    $doc destroy
    puts "  written: $target ([file size $target] bytes)"
    if {[dict get $state signed]} {
        puts "  /ByteRange \[[dict get $state byteRange]\],\
            [dict get $state length] bytes of DER in\
            [dict get $state size] reserved"
        puts "  [exampleOpensslVerify $dir]"
    } else {
        puts "  placeholder unfilled, /ByteRange \[[dict get $state byteRange]\]"
    }
    return
}

# Whether a host answers at all: one TCP connect with a short leash. Only
# this probe is time-boxed - the request that follows it gets the timeout of
# whoever makes it. The variable is global because [vwait] needs one; the
# name is this file's own.
proc exampleReachable {url {leash 3000}} {
    if {![regexp {^https?://([^/:]+)(?::(\d+))?} $url -> host port]} {
        return 0
    }
    if {$port eq {}} {
        set port [expr {[string match https://* $url] ? 443 : 80}]
    }
    if {[catch {socket -async $host $port} sock]} {
        return 0
    }
    set deadline [after $leash [list set ::exampleProbe timeout]]
    fileevent $sock writable [list set ::exampleProbe ok]
    vwait ::exampleProbe
    after cancel $deadline
    # Writable fires on a FAILED connect as well - refused is an answer too,
    # just not the one wanted. Only a socket without an error is a host.
    set refused [expr {$::exampleProbe eq "ok"
        && [fconfigure $sock -error] ne {}}]
    catch {close $sock}
    return [expr {$::exampleProbe eq "ok" && !$refused}]
}

# A throwaway timestamp authority: a self-signed certificate whose one
# extended key usage is timeStamping, and the config [openssl ts -reply]
# wants. This is the fallback for a build WITHOUT network - the token it
# issues verifies technically and vouches for nothing, exactly like the test
# CA of the signature examples. The test suite keeps a twin of this in
# tests/timestamp.test, deliberately: examples must run without the suite's
# scaffolding and the suite without the examples'.
proc exampleTsaAuthority {dir} {
    exampleRun openssl req -x509 -newkey rsa:2048 \
        -keyout [file join $dir tsa.key] -out [file join $dir tsa.pem] \
        -days 30 -nodes -subj "/C=DE/O=tclpdf example/CN=throwaway TSA" \
        -addext "extendedKeyUsage=critical,timeStamping"
    exampleWriteBinary [file join $dir tsa.cnf] "\[tsa\]
default_tsa = tsa_config
\[tsa_config\]
serial = [file join $dir serial]
signer_cert = [file join $dir tsa.pem]
signer_key = [file join $dir tsa.key]
default_policy = 1.2.3.4.1
digests = sha256, sha384, sha512
accuracy = secs:1
ordering = no
tsa_name = no
ess_cert_id_chain = no
signer_digest = sha256
"
    exampleWriteBinary [file join $dir serial] "01\n"
    return
}

# The transport for -tsa: request bytes in, response bytes out, through the
# throwaway authority in "dir". What [::tclpdf::sign timestamp] checks about
# the answer - imprint, nonce, status - it checks here exactly as it would
# against a public one; -tsa changes who answers, never what is accepted.
proc exampleTsaTransport {dir tsq} {
    exampleWriteBinary [file join $dir query.tsq] $tsq
    exampleRun openssl ts -reply -config [file join $dir tsa.cnf] \
        -queryfile [file join $dir query.tsq] -out [file join $dir reply.tsr]
    return [exampleReadBinary [file join $dir reply.tsr]]
}

# Where the stamp comes from, decided ONCE and before the document is
# written. Answers three values for [lassign]:
#
#   dir    the throwaway authority's directory, {} when the public one
#          answers - delete it when the script is done
#   stamp  extra arguments for [::tclpdf::sign timestamp]: empty for the
#          public authority, "-tsa ..." for the local fallback
#   why    why neither is to be had, in a sentence; {} otherwise
#
# The public authority first, a local throwaway one without network, and a
# skip only where there is no openssl to build even that.
proc exampleTimestampSetup {{authority https://tsr.open-tsa.eu}} {
    if {[exampleReachable $authority]} {
        return [list {} {} {}]
    }
    if {![llength [auto_execok openssl]]} {
        return [list {} {} "$authority is not reachable and openssl was not\
            found on the PATH, so there is no throwaway authority either"]
    }
    set dir [exampleTempDirectory]
    if {[catch {exampleTsaAuthority $dir} message]} {
        file delete -force $dir
        return [list {} {} "$authority is not reachable and openssl would\
            not make a throwaway authority:\
            [lindex [split $message \n] 0]"]
    }
    return [list $dir [list -tsa [list exampleTsaTransport $dir]] {}]
}

# The stamp itself, shared by the three timestamp examples: the call onto
# the finished file, the report line, and the throwaway authority's directory
# gone when there was one. What differs per example is everything BEFORE this
# - the document - which is why only the tail is shared.
proc exampleStamp {target stamp dir} {
    set stamped [::tclpdf::sign timestamp $target {*}$stamp]
    exampleTimestampReport $stamped
    if {$dir ne {}} {
        file delete -force $dir
    }
    return
}

# The one line every timestamp example prints about its stamp: field, token,
# serial, time, and WHO answered - the public authority by its URL, or the
# throwaway one, named as such so nobody mistakes an offline build's token
# for evidence.
proc exampleTimestampReport {stamped} {
    if {[dict exists $stamped url]} {
        set from "from [dict get $stamped url]"
    } else {
        set from "from a local throwaway authority - offline build, the\
            token vouches for nothing"
    }
    puts "  field [dict get $stamped field]: token [dict get $stamped length]\
        bytes, serial [dict get $stamped serial],\
        time [dict get $stamped time] ($from)"
    return
}
