#
# tclpdf - PDF generation for Tcl
#
# encrypt - the standard security handler, revision 6 (AES-256) (Etappe 8)
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# One call encrypts a document:
#
#   $doc encrypt -user geheim -owner chef -permissions {print copy}
#
# What that produces is revision 6 of PDF's standard security handler, and
# nothing else: AES-256 in CBC mode, /V 5, /R 6, /CFM /AESV3. Revisions 2 to 4
# - RC4 and AES-128, keys derived from /ID - are deprecated in PDF 2.0
# (ISO 32000-2, 7.6.4.1) and are not written here. A writer that offers them
# is offering a choice whose wrong half looks exactly like the right one from
# the outside.
#
# The three things about R6 worth knowing before reading on, because each of
# them contradicts what revision 4 taught:
#
#   The file encryption key is RANDOM. It is not derived from the passwords
#   and not from /ID (7.6.4.4.1: "the file encryption key shall be a 256-bit
#   (32-byte) value generated with a strong random number generator"). The
#   passwords only WRAP it - /UE and /OE are that key encrypted under a hash
#   of the password. Which is why two passwords can open one file, and why
#   this module needs nothing from the writer and nothing from /ID.
#
#   The object key IS the file key. Algorithm 1.A (7.6.3.3) uses the file
#   encryption key directly, with no object and generation number mixed in.
#   So a string does not have to know which object it will land in - which is
#   what makes the string seam in document.tcl a command prefix and not a
#   callback carrying an object number.
#
#   The password check is a HASH, not a decryption. Algorithm 2.B (7.6.4.3.4)
#   runs at least 64 rounds of AES-128 and SHA-2 over the password; the salts
#   in /U and /O are what a reader repeats it with.
#
# The strings of the encryption dictionary itself are the one exception in
# the file: 7.6.2 exempts them ("shall not be encrypted") and requires them to
# be direct objects. This module therefore builds them with the bare
# ::tclpdf::pdfObj hexStr and never with the document's [HexStr], which is the
# seam that encrypts. That single difference is the reason encrypt.tcl is the
# one module test document-strings-24.5 does not sweep.
#
# What is deliberately not here: reading an encrypted file (import.tcl refuses
# one by name), revisions 4 and earlier, public-key handlers, and encrypting
# only the attachments. The manual's "Limits" paragraph names them.
#

package require Tcl 8.6.11-
package require TclOO
package require tclpdf::pdfObj 1.0-
package require tclpdf::option 1.0-
package require tclpdf::document 1.0-
package require tclpdf::crypto 1.0-

namespace eval ::tclpdf::encrypt {
  namespace export {[a-z]*}
  namespace ensemble create

  # The access permissions of Table 22, by the name a caller writes and the
  # bit position the standard gives them. Names rather than numbers because
  # "-permissions {print copy}" says what it grants and "-permissions -44"
  # does not - and because the bit positions are counted from 1, which is one
  # off from every shift a reader of this file would write by hand.
  #
  # Four bit positions of the table are not offered:
  #
  #   1-2    reserved, must be zero
  #   7-8    reserved, must be one
  #   10     "PDF readers shall ignore this bit and PDF writers shall always
  #          set this bit to 1" - it used to control extraction for
  #          accessibility and that restriction is deprecated in PDF 2.0
  #   13-32  reserved, must be one
  #
  # They are not a choice, so they are set by [flags] and cannot be named.
  variable bits {
    print 3
    modify 4
    copy 5
    annotate 6
    fill 9
    assemble 11
    highres 12
  }

  # An initialisation vector of sixteen zero bytes: what algorithms 8 and 9
  # prescribe for wrapping the file key into /UE and /OE. A constant, and
  # correct as one - the key it is used with is fresh random and used once.
  variable zeroIv [string repeat \x00 16]
}

#
# ---------------------------------------------------------------------------
# The algorithms of 7.6, as functions
# ---------------------------------------------------------------------------
#
# They take and return BYTES, they hold no state, and they are separate from
# the document methods below on purpose: each one can be checked against the
# standard on its own, and a test can mutate one and see exactly which
# guarantee falls over.
#

# A password on its way into algorithm 2.B (7.6.4.2): UTF-8, truncated to the
# first 127 bytes.
#
# SASLprep (RFC 4013) is NOT applied, and that is a limitation rather than an
# oversight: it needs Unicode normalisation tables this package does not
# carry. The consequence is precise and small - a password written with
# combining characters, or with characters that SASLprep would map away, may
# be spelled one way here and another way by a reader that does normalise, and
# then not open the file. ASCII passwords, which is what a password typed into
# a dialogue box is, are unaffected: SASLprep is the identity on them.
proc ::tclpdf::encrypt::password {text} {
  set bytes [encoding convertto utf-8 $text]
  # Bytes, not characters - and truncation may cut a UTF-8 sequence in half.
  # That is what the standard says ("truncated to the first 127 bytes"), and
  # a reader truncating the same password does the same cut.
  if {[string length $bytes] > 127} {
    set bytes [string range $bytes 0 126]
  }
  return $bytes
}

# Algorithm 2.B (7.6.4.3.4): the hardened hash.
#
# "userKey" is the 48-byte /U value and is passed ONLY when the owner password
# is being checked or the owner key computed; for the user side it is empty.
# That asymmetry is the standard's, and it is what binds /O to /U.
#
# Written from the standard text and from nothing else. Three "deviations"
# from it circulate in ports of this algorithm, and all three were measured
# here and are not deviations:
#
#   The order in step (a) is password, K, user key - the text says so.
#
#   The modulo 3 in step (c) is over "the first 16 bytes of E as an unsigned
#   big-endian integer". Since 256 = 1 (mod 3), that remainder equals the
#   remainder of the SUM of those bytes, which is what is computed here - a
#   128-bit bignum per round, avoided. Cross-checked over 20 000 blocks
#   against the bignum form, identical every time.
#
#   K keeps the length of the hash chosen in step (c) - 32, 48 or 64 bytes -
#   and is not cut back to 32 between rounds. Only the RESULT is the first 32
#   bytes of the final K.
proc ::tclpdf::encrypt::hash {password salt {userKey {}}} {
  set k [::tclpdf::crypto sha256 $password$salt$userKey]
  set round 0
  while {1} {
    # (a) 64 repetitions of password, K, user key.
    set k1 [string repeat $password$k$userKey 64]
    # (b) AES-128 CBC without padding, first half of K the key, second half
    # the initialisation vector. The one place in the package that uses
    # AES-128; crypto.tcl keeps it out of its ensemble for that reason.
    set e [::tclpdf::crypto::Aes128CbcNoPad [string range $k 0 15] \
        [string range $k 16 31] $k1]
    # (c) which hash comes next, and (d) the hash itself.
    binary scan [string range $e 0 15] cu16 leading
    set sum 0
    foreach byte $leading {
      incr sum $byte
    }
    set k [::tclpdf::crypto [lindex {sha256 sha384 sha512} \
        [expr {$sum % 3}]] $e]
    incr round
    # (e) and (f): from round 64 on, the last byte of E decides whether
    # another round follows. "round" counts the rounds performed, so it is
    # the round number the standard starts numbering at 64.
    if {$round >= 64} {
      binary scan [string index $e end] cu last
      if {$last <= $round - 32} {
        break
      }
    }
  }
  return [string range $k 0 31]
}

# Algorithm 8 (7.6.4.4.7): /U and /UE from the user password.
#
# Returns the two as a list. /U is 48 bytes - a 32-byte hash over password and
# validation salt, then the two salts - and /UE is the file key wrapped under
# a hash over password and key salt.
proc ::tclpdf::encrypt::userKeys {password fileKey} {
  variable zeroIv
  set salts [::tclpdf::crypto random 16]
  set validation [string range $salts 0 7]
  set keySalt [string range $salts 8 15]
  set u [hash $password $validation]$validation$keySalt
  set ue [::tclpdf::crypto aesEncrypt [hash $password $keySalt] $zeroIv $fileKey]
  return [list $u $ue]
}

# Algorithm 9 (7.6.4.4.8): /O and /OE from the owner password.
#
# The same shape as algorithm 8 with one difference that is easy to miss and
# fatal to get wrong: the input to the hash carries the 48 bytes of /U as
# well. So the owner keys can only be computed after the user keys, and an /O
# computed against a different /U opens nothing.
proc ::tclpdf::encrypt::ownerKeys {password fileKey u} {
  variable zeroIv
  if {[string length $u] != 48} {
    return -code error "tclpdf: the owner key needs the 48-byte U value of\
        algorithm 8, got [string length $u] bytes"
  }
  set salts [::tclpdf::crypto random 16]
  set validation [string range $salts 0 7]
  set keySalt [string range $salts 8 15]
  set o [hash $password $validation $u]$validation$keySalt
  set oe [::tclpdf::crypto aesEncrypt [hash $password $keySalt $u] $zeroIv \
      $fileKey]
  return [list $o $oe]
}

# Algorithm 10 (7.6.4.4.9): /Perms, the permissions again - encrypted under
# the file key, so that a reader can tell a tampered /P from a genuine one.
#
# AES in ECB mode over exactly one block, which is why crypto.tcl offers a
# block rather than a mode for it.
proc ::tclpdf::encrypt::perms {fileKey p metadata} {
  # (a) and (b): the permissions in bytes 0-7, low order byte first, the
  # upper 32 bits all ones. "i" is the little-endian 32-bit format and takes
  # the negative integer P is, unchanged.
  set block [binary format i $p]
  append block \xff\xff\xff\xff
  # (c) T or F for EncryptMetadata, (d) the three letters, (e) four bytes
  # that are ignored and exist so the block is not the same twice.
  append block [expr {$metadata ? "T" : "F"}] adb [::tclpdf::crypto random 4]
  return [::tclpdf::crypto aesEncryptBlock $fileKey $block]
}

# The /P integer from a list of permission names (Table 22).
#
# "all" is the whole list. The reserved bits are set here and cannot be
# named: bits 7, 8 and 13 to 32 must be 1, and bit 10 must be 1 because the
# table says "PDF writers shall always set this bit to 1".
#
# The result is a SIGNED 32-bit integer, which is why it comes out negative:
# with every reserved high bit set it cannot be anything else, and a PDF
# integer is signed twos-complement (7.6.4.2, NOTE).
proc ::tclpdf::encrypt::flags {names} {
  variable bits
  if {$names eq "all"} {
    set names [dict keys $bits]
  }
  set p 0
  foreach bit {7 8 10} {
    set p [expr {$p | (1 << ($bit - 1))}]
  }
  for {set bit 13} {$bit <= 32} {incr bit} {
    set p [expr {$p | (1 << ($bit - 1))}]
  }
  foreach name $names {
    if {![dict exists $bits $name]} {
      return -code error "tclpdf: unknown permission \"$name\" - known are:\
          [join [dict keys $bits] { }], or \"all\""
    }
    set p [expr {$p | (1 << ([dict get $bits $name] - 1))}]
  }
  set p [expr {$p & 0xffffffff}]
  if {$p >= 0x80000000} {
    incr p -0x100000000
  }
  return $p
}

# The padding of 7.6.3.1: RFC 8018, and the sentence that matters is the last
# one - "the pad is present when M is evenly divisible by 16; it contains 16
# bytes of 0x10". A cipher that skips the full block for an empty stream
# writes a file whose every reader strips real data instead of padding, and an
# empty stream is exactly where that happens first.
proc ::tclpdf::encrypt::pad {data} {
  set count [expr {16 - [string length $data] % 16}]
  return $data[string repeat [binary format c $count] $count]
}

# Algorithm 1.A (7.6.3.3): one string or one stream.
#
# A fresh 16-byte initialisation vector per call, stored as the first 16 bytes
# of the result. Fresh per call and not per document: two identical streams
# under one key must not come out identical, and the vector is what prevents
# it. It is also why an encrypted document is no longer byte-identical from
# one write to the next.
proc ::tclpdf::encrypt::cipher {key data} {
  set iv [::tclpdf::crypto random 16]
  return $iv[::tclpdf::crypto aesEncrypt $key $iv [pad $data]]
}

# The BYTES behind a text string - what [pdfObj str] would have written, one
# step earlier.
#
# The rule has to be pdfObj's own, character for character: ASCII stays ASCII
# and everything else becomes UTF-16BE with a byte order mark. A reader
# decrypts the string and then reads it exactly as it reads an unencrypted
# one, so the two have to agree on the encoding. Utf16Be is reached into
# rather than copied for that reason - a second copy of an encoding rule is a
# second answer to the same question.
proc ::tclpdf::encrypt::textBytes {value} {
  if {[regexp {^[\x20-\x7e\r\n\t]*$} $value]} {
    return $value
  }
  return [::tclpdf::pdfObj::Utf16Be $value]
}

#
# ---------------------------------------------------------------------------
# The document's side
# ---------------------------------------------------------------------------
#

oo::define ::tclpdf::document::document {

  # $doc encrypt ?-user text? ?-owner text? ?-permissions list? ?-metadata bool?
  # $doc encrypt state            what was declared, without the secrets
  method encrypt {args} {
    if {[llength $args] && [string index [lindex $args 0] 0] ne "-"} {
      switch -- [lindex $args 0] {
        state {return [my EncryptState]}
        default {
          return -code error "tclpdf: unknown encrypt subcommand\
              \"[lindex $args 0]\" - known is: state"
        }
      }
    }

    # Everything down to the version call is a CHECK and changes nothing: a
    # refused call has to leave the document exactly as it was, down to the
    # version floor. The same rule pdfa.tcl follows and for the same measured
    # reason - a half-applied claim is worse than none.
    #
    # Parsed over the four PUBLIC options only. The state this builds also
    # holds the file key and the four key values, and parsing over the whole
    # of it would make "-key ..." a valid option, name it in the message for
    # a misspelled one, and let a caller hand in a key of their own choosing
    # from a source nobody can vouch for. Found twice before, in pdfa.tcl and
    # in ua.tcl, and both times the state had grown a private key after the
    # defaults were written.
    set options [::tclpdf::option parse \
        {user {} owner {} permissions all metadata 1} $args "encrypt"]

    if {![string is boolean -strict [dict get $options metadata]]} {
      return -code error "tclpdf: encrypt -metadata takes a boolean, not\
          \"[dict get $options metadata]\""
    }
    # Checked here, before anything is generated, so that a misspelled
    # permission costs a message and not a key.
    set p [::tclpdf::encrypt flags [dict get $options permissions]]

    # An empty -user together with no -owner leaves BOTH passwords empty, and
    # that is refused rather than written. Without -owner the user password
    # serves as the owner password too (see below, where that is decided), so
    # with an empty -user there is no owner password either - and the empty
    # password is the one every reader tries first: it authenticates as the
    # OWNER (algorithm 12, 7.6.4.4.11), and an owner is not subject to /P at
    # all. Every permission the call withholds would stand in the file and be
    # lifted by everyone who opened it, and what would be left is a document
    # encrypted under a key anyone can derive.
    #
    # An empty -user BESIDE an owner password is the useful case and stays:
    # the document opens for everyone and the owner password is what lifts
    # the restrictions. That is the one the manual recommends, and the pair of
    # empty ones is what it says is not offered.
    if {[dict get $options user] eq {} && [dict get $options owner] eq {}} {
      return -code error "tclpdf: encrypt with an empty -user and no -owner\
          would leave both passwords empty, and the empty password is the\
          first one every reader tries: it opens the document as its OWNER\
          (ISO 32000-2, 7.6.4.4.11), and an owner is not subject to /P - so\
          every permission withheld here would be lifted by everyone who\
          opens the file. Name an -owner password, which is what lifts the\
          restrictions for whoever knows it; an empty -user beside it is\
          allowed and is usually what is wanted, since the document then\
          opens for everyone"
    }

    if {[my state encrypt] ne {}} {
      return -code error "tclpdf: this document is already encrypted -\
          encrypt is called once. A second call would replace the file key,\
          and every string already written under the first one would be lost"
    }
    # PDF/A forbids encryption outright: ISO 19005, and veraPDF says it as
    # rule 6.1.3-2, "The keyword Encrypt shall not be used in the trailer
    # dictionary". ZUGFeRD is a PDF/A-3 document, so the same holds for it -
    # and an invoice nobody's bookkeeping software can open is the more
    # expensive half of the mistake. Said at whichever call creates the
    # contradiction; the mirror checks belong in those two modules.
    #
    # ZUGFeRD first, and that order is the whole reason both checks exist
    # separately: [zugferd] declares PDF/A-3 as it goes, so an invoice
    # answers to BOTH states and would otherwise be told about a claim it
    # never made by name.
    if {[my state zugferd] ne {}} {
      return -code error "tclpdf: a ZUGFeRD invoice is a PDF/A-3 document\
          and PDF/A forbids encryption (veraPDF rule 6.1.3-2) - an encrypted\
          invoice is one no bookkeeping software can read"
    }
    if {[my state pdfa] ne {}} {
      return -code error "tclpdf: PDF/A forbids encryption - the Encrypt\
          keyword shall not be used in the trailer dictionary (ISO 19005,\
          veraPDF rule 6.1.3-2). This document claims PDF/A-[dict get\
          [my state pdfa] part]"
    }

    # The mirror image of the check in sign.tcl: 7.6.2 takes exactly one
    # thing out of the encryption - "any hexadecimal strings representing
    # the value of the Contents key in a Signature dictionary" - and leaves
    # the other strings of that dictionary in it. Buildable, and measured
    # against no reader, so it is refused at whichever of the two calls
    # comes second rather than written and hoped for.
    if {[my state sign] ne {}} {
      return -code error "tclpdf: this document is being signed, and tclpdf\
          does not encrypt a signed document - 7.6.2 exempts only the\
          /Contents string of a signature dictionary from encryption, not\
          the rest of it. Drop the \[\$doc sign\] call or the encrypt call,\
          they cannot both stand"
    }

    # Before anything is drawn, and refused otherwise. Two measured reasons,
    # and neither of them shows up in the finished file as anything but a
    # document that will not open:
    #
    # Strings. [language] and [link] put finished PDF syntax into the catalog
    # and into the annotation the moment they are called, while [info],
    # [bookmark] and [pageLabels] build theirs during the write (test
    # document-strings-24.4). A cipher installed in between catches the
    # second group and not the first, and the reader finds a plain string in
    # a file whose /Encrypt says there are none.
    #
    # Streams. Measured rather than assumed, and it is not the list one
    # would guess: a picture and an ICC profile become objects during the
    # WRITE, but a tiling pattern, a form XObject and an imported page become
    # one at the call - [form create] fills two objects before a single page
    # has been drawn on. Anything already written down went down in the
    # clear.
    #
    # The two are checked separately because they are two different traces:
    # page content lives in a buffer and never in an object until the write,
    # and an object holding a body is something a page count would not see.
    # A page that exists but holds nothing is fine, and so is a reserved
    # number - [page add] takes one, and it stays empty until the write.
    for {set index 0} {$index < [my page count]} {incr index} {
      if {[my page content $index] ne {}} {
        return -code error "tclpdf: encrypt has to come before anything is\
            drawn - page [expr {$index + 1}] already has content, and a\
            stream written before the cipher was installed stays in the\
            clear. Call \[\$doc encrypt\] right after \[tclpdf new\]"
      }
    }
    # Two entries are built as finished PDF syntax at the CALL, not at write
    # time: [language] puts /Lang into the catalogue and [link] builds its
    # annotation there and then. Written before the cipher was installed they
    # stay in the clear inside a file whose /Encrypt says otherwise - and a
    # reader, decrypting what was never encrypted, silently ends up with an
    # empty value. Measured: /Lang () after qpdf --decrypt, with no complaint
    # from any tool. Refused rather than repaired, which is the same rule the
    # page and object checks above follow.
    if {[my catalogEntry Lang] ne {}} {
      return -code error "tclpdf: encrypt has to come before \[\$doc language\] -\
          the language is written into the catalogue at that call and would\
          stay in the clear. Call \[\$doc encrypt\] right after \[tclpdf new\]"
    }
    if {[dict size [my state annots]]} {
      return -code error "tclpdf: encrypt has to come before the first\
          \[\$doc link\] - a link annotation is built at that call and its\
          text would stay in the clear. Call \[\$doc encrypt\] right after\
          \[tclpdf new\]"
    }
    for {set number 1} {$number <= [[my writer] count]} {incr number} {
      if {[[my writer] body $number] ne {}} {
        return -code error "tclpdf: encrypt has to come before anything is\
            put into the document - object $number is already written (a\
            tiling pattern, a form XObject or an imported page), and it\
            would stay in the clear. Call \[\$doc encrypt\] right after\
            \[tclpdf new\]"
      }
    }

    # From here on the document changes. /V 5 and /R 6 - AESV3 - are PDF 2.0
    # (Table 20; revisions 1 to 4 are deprecated there). Not raised behind
    # the caller's back the way pdfa raises to 1.7: PDF/A DEFINES the
    # version it is written as, encryption does not, and a document that
    # says 1.7 in its header is a promise the caller made. The message names
    # the one call that fixes it.
    my RequireVersion 2.0 "encryption (AESV3, /V 5 /R 6 - ISO 32000-2,\
        Table 20)"

    # The file encryption key: 32 bytes of randomness, made here and now.
    # Nothing about it depends on the writer, on /ID or on the passwords -
    # see the head of this file - so it can be made at the call, which is
    # what lets every string from here on be encrypted as it is built.
    set fileKey [::tclpdf::crypto random 32]
    set user [::tclpdf::encrypt password [dict get $options user]]
    # Without an owner password the user password is the owner password too.
    # A document with one password then behaves as a reader expects: the
    # password opens it, and the permissions are what the file says. The
    # alternative - an empty owner password - would hand every reader full
    # rights, since an empty owner password is the one every reader tries
    # first. Where the user password is empty as well this rule would produce
    # exactly that empty owner password, which is why the check above refuses
    # the pair outright.
    if {[dict get $options owner] eq {}} {
      set owner $user
    } else {
      set owner [::tclpdf::encrypt password [dict get $options owner]]
    }
    set metadata [expr {[dict get $options metadata] ? 1 : 0}]

    lassign [::tclpdf::encrypt userKeys $user $fileKey] u ue
    lassign [::tclpdf::encrypt ownerKeys $owner $fileKey $u] o oe

    # The passwords are not kept. Everything a reader needs of them is in the
    # four values above, and a password left in the document object is one
    # more place it can be read out of.
    my state encrypt [dict create key $fileKey u $u ue $ue o $o oe $oe \
        perms [::tclpdf::encrypt perms $fileKey $p $metadata] p $p \
        permissions [dict get $options permissions] metadata $metadata]

    # The two seams. Exported by hand because a command prefix is called
    # from the global context, where TclOO does not reach a method whose
    # name starts with a capital - the same reason [onSelf] exists.
    oo::objdefine [self] export EncryptStream EncryptString
    [my writer] encryptor [list [self] EncryptStream]
    my state stringEncryptor [list [self] EncryptString]
    my onSelf beforeWrite EncryptWrite

    return [my EncryptState]
  }

  # What was declared - and not the file key, not /U, /O, /UE, /OE. They are
  # in the file where they belong; answering with them here would put them
  # into every log that prints what a document claims.
  method EncryptState {} {
    set current [my state encrypt]
    if {$current eq {}} {
      return {}
    }
    return [dict merge [dict filter $current key permissions metadata p] \
        {version 5 revision 6 method AESV3}]
  }

  # The encryption dictionary (7.6.4.2, Tables 20 and 21).
  #
  # Its strings are the exception 7.6.2 makes: they are not encrypted, and
  # they are direct objects. Hence the bare pdfObj, which is the seam's
  # counterpart and the only place in the package that is allowed past it.
  #
  # Runs on beforeWrite and is idempotent: the reservation hands back the
  # same object number on a second write, the four key values come out of the
  # state unchanged, and the trailer entry is set to what it already said.
  #
  # THERE IS NO /Length HERE, and its absence is the entry Table 20 asks for.
  # The table offers /Length for /V 2 and /V 3 only, as "the length of the
  # file encryption key, in bits ... a multiple of 8 in the range 40 to 128",
  # and PDF 2.0 deprecates it outright - while [encrypt] requires version
  # 2.0, so every dictionary this writes lands in a file the entry was
  # withdrawn from. A "/Length 256" stated bits where the table allows at
  # most 128 and stated them for a revision that has no such entry; it came
  # from a port of revision 4, where /V 2 made it right.
  #
  # The /Length of the crypt filter below is a different entry and stays:
  # Table 25 asks it of a crypt filter dictionary, and there it is the key
  # length in BYTES - 32 for AES-256.
  #
  # WHAT LEAVING IT OUT COSTS, measured rather than left to be found later:
  # qpdf writes /Length 256 into its own /V 5 dictionaries and reads the
  # entry back unconditionally, so "qpdf --check" on a file without it says
  # "dictionary key /Length: operation for integer attempted on object of
  # type null: returning 0" and exits 3 (qpdf 12.4.0). That is qpdf talking
  # about its own reading and not about this file: --decrypt,
  # --show-encryption, pdfinfo and every reader open the document without a
  # word, and Table 20 is unambiguous about which of the two is right.
  method EncryptWrite {} {
    set current [my state encrypt]
    set number [my reservation encrypt.dictionary]
    [my writer] put $number [::tclpdf::pdfObj dictionary [list \
        Filter /Standard \
        V 5 \
        R 6 \
        CF [::tclpdf::pdfObj dictionary [list \
            StdCF [::tclpdf::pdfObj dictionary [list \
                CFM /AESV3 AuthEvent /DocOpen Length 32]]]] \
        StmF /StdCF \
        StrF /StdCF \
        U [::tclpdf::pdfObj hexStr [dict get $current u]] \
        UE [::tclpdf::pdfObj hexStr [dict get $current ue]] \
        O [::tclpdf::pdfObj hexStr [dict get $current o]] \
        OE [::tclpdf::pdfObj hexStr [dict get $current oe]] \
        P [dict get $current p] \
        Perms [::tclpdf::pdfObj hexStr [dict get $current perms]] \
        EncryptMetadata [expr {[dict get $current metadata] ? "true" : "false"}]]]
    # /Encrypt is an indirect reference and has to be one (Table 15): the
    # trailer is what a reader looks at before it can decrypt anything.
    my trailerEntry Encrypt [[my writer] ref $number]
    return
  }

  # The stream seam. Called by the writer for every stream, after the
  # filters, and with "metadata" for the /Metadata stream.
  method EncryptStream {data {which {}}} {
    set current [my state encrypt]
    # /EncryptMetadata false leaves exactly this one stream readable, so that
    # a cataloguing system can index a document it cannot open (7.6.2). The
    # decision is recorded in the encryption dictionary AND in the /Perms
    # block, so the two cannot drift apart.
    if {$which eq "metadata" && ![dict get $current metadata]} {
      return $data
    }
    return [::tclpdf::encrypt cipher [dict get $current key] $data]
  }

  # The string seam. Asked for finished PDF syntax rather than for bytes, so
  # the spelling is decided here: a hexadecimal string, always.
  #
  # A literal string would work too and would be shorter by a third, but it
  # has to escape parentheses, backslashes and every byte outside the
  # printable range - and ciphertext is uniformly distributed, so roughly
  # three bytes in four need escaping anyway. Hex is shorter in practice,
  # cannot be broken by a line-ending translation, and has no way to go
  # wrong on a null byte.
  method EncryptString {kind value} {
    switch -- $kind {
      str {
        set bytes [::tclpdf::encrypt textBytes $value]
      }
      hexStr - bytesStr {
        # Already bytes: a font's WinAnsi codes, an attachment's key, a
        # palette. Encrypted as they are.
        set bytes $value
      }
      default {
        return -code error "tclpdf: the string seam knows str, hexStr and\
            bytesStr, not \"$kind\""
      }
    }
    return [::tclpdf::pdfObj hexStr \
        [::tclpdf::encrypt cipher [dict get [my state encrypt] key] $bytes]]
  }
}

package provide tclpdf::encrypt 1.1
