#
# tclpdf - PDF generation for Tcl
#
# timestamp - a document timestamp (ISO 32000-2, 12.8.5) on a finished file:
# the byte-range digest is sent to an RFC 3161 timestamp authority and the
# TimeStampToken that comes back becomes the /Contents of a /DocTimeStamp
# signature dictionary, appended as an incremental update. The file needs no
# signature for this: a timestamp proves that these bytes existed at the time
# in the token, and says nothing about who wrote them.
#
# Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
#
# See the file "license.terms" for information on usage and redistribution
# of this file (MIT License).
#
# The authority is configurable and defaults to Open TSA (https://open-tsa.eu),
# a free RFC 3161 service. Any other authority is reached either through -url,
# or - where the transport is not plain RFC 3161 over HTTP(S), or needs
# authentication - through -tsa, a command prefix that takes the request bytes
# and answers the response bytes, so the caller owns the transport the same
# way a signer owns its key.
#
# HTTPS needs the tls package. It is required only when an https:// URL is
# actually used; without it the refusal names -tsa as the way through, and a
# plain http:// authority works with the http package of the Tcl core alone.
#
# What is deliberately NOT here: the timestamp of a SIGNATURE (PAdES B-T).
# That token is an unsigned attribute inside the CMS object, put there by the
# signer - see the manual at [sign], "A timestamp needs nothing here".

package require Tcl 8.6.11-
# 1.8 for [sign::Ranged], which joins the appendix and fills its /ByteRange.
package require tclpdf::sign 1.8-
package require tclpdf::crypto 1.0-

namespace eval ::tclpdf::sign {}

# ---------------------------------------------------------------------------
# DER, written and read
#
# The request is built and the response is read here rather than by a library
# because the structures are small and fixed: a TimeStampReq is five fields,
# and the walk into the token below touches eight. sign.tcl checks DER, it
# does not build any - this is the one module that does, so the helpers live
# here.
# ---------------------------------------------------------------------------

proc ::tclpdf::sign::DerTag {tag content} {
  set length [string length $content]
  if {$length < 128} {
    set prefix [binary format cc $tag $length]
  } elseif {$length < 256} {
    set prefix [binary format ccc $tag 0x81 $length]
  } else {
    set prefix [binary format ccS $tag 0x82 $length]
  }
  return $prefix$content
}

proc ::tclpdf::sign::DerSequence {args} {
  return [DerTag 0x30 [join $args {}]]
}

# An INTEGER from bytes, most significant first: a leading zero is added
# where the top bit is set, since DER integers are signed and a nonce or a
# hash-sized number has to stay positive.
proc ::tclpdf::sign::DerInteger {bytes} {
  binary scan [string index $bytes 0] cu first
  if {$first > 127} {
    set bytes \x00$bytes
  }
  return [DerTag 0x02 $bytes]
}

proc ::tclpdf::sign::DerOid {dotted} {
  set parts [split $dotted .]
  set bytes [binary format c \
      [expr {40 * [lindex $parts 0] + [lindex $parts 1]}]]
  foreach part [lrange $parts 2 end] {
    set chunk [binary format c [expr {$part & 0x7f}]]
    set part [expr {$part >> 7}]
    while {$part > 0} {
      set chunk [binary format c [expr {($part & 0x7f) | 0x80}]]$chunk
      set part [expr {$part >> 7}]
    }
    append bytes $chunk
  }
  return [DerTag 0x06 $bytes]
}

# One TLV read at "offset": answers tag, the content offsets, and where the
# next TLV begins. The forms above 0x82 do not occur in a timestamp response
# small enough to embed, and are refused rather than misread.
proc ::tclpdf::sign::DerRead {bytes offset what} {
  binary scan [string index $bytes $offset] cu tag
  binary scan [string index $bytes [expr {$offset + 1}]] cu first
  if {$first < 128} {
    set length $first
    set start [expr {$offset + 2}]
  } elseif {$first == 0x81} {
    binary scan [string index $bytes [expr {$offset + 2}]] cu length
    set start [expr {$offset + 3}]
  } elseif {$first == 0x82} {
    binary scan [string range $bytes [expr {$offset + 2}] \
        [expr {$offset + 3}]] Su length
    set start [expr {$offset + 4}]
  } else {
    return -code error -errorcode [list TCLPDF TIMESTAMP TOKEN length] \
        "tclpdf: the timestamp response for $what carries a DER\
        length form beyond three bytes, which no response that fits a\
        signature field uses - the response is damaged or not DER"
  }
  set end [expr {$start + $length}]
  if {$end > [string length $bytes]} {
    return -code error -errorcode [list TCLPDF TIMESTAMP TOKEN truncated] \
        "tclpdf: the timestamp response for $what states a length\
        that runs past its own end - $length bytes at offset $start of\
        [string length $bytes]. The response is truncated"
  }
  return [list $tag $start $end]
}

# Walks INTO a constructed TLV whose tag is checked on the way: the token
# structure is fixed, so a wrong tag means a wrong response, named by field.
proc ::tclpdf::sign::DerEnter {bytes offset tag field what} {
  lassign [DerRead $bytes $offset $what] found start end
  if {$found != $tag} {
    return -code error -errorcode [list TCLPDF TIMESTAMP TOKEN $field] \
        "tclpdf: the timestamp response for $what carries tag\
        0x[format %02x $found] where $field expects\
        0x[format %02x $tag] - this is not an RFC 3161 response"
  }
  return [list $start $end]
}

# ---------------------------------------------------------------------------
# The request
# ---------------------------------------------------------------------------

# TimeStampReq (RFC 3161, 2.4.1): version 1, the digest under its algorithm,
# an optional policy, a random nonce, and certReq TRUE - the token has to
# carry the signing certificate, because the file will be verified long after
# the authority may have changed it.
proc ::tclpdf::sign::TsQuery {digest algorithmOid policy nonce} {
  set imprint [DerSequence \
      [DerSequence [DerOid $algorithmOid] [DerTag 0x05 {}]] \
      [DerTag 0x04 $digest]]
  set body [DerInteger \x01]
  append body $imprint
  if {$policy ne {}} {
    append body [DerOid $policy]
  }
  append body [DerInteger $nonce]
  append body [DerTag 0x01 \xff]
  return [DerSequence $body]
}

# ---------------------------------------------------------------------------
# The response
# ---------------------------------------------------------------------------

# TimeStampResp = PKIStatusInfo, then the token. Status 0 and 1 are granted
# (RFC 3161, 2.4.2); everything else is the authority's refusal, and its own
# words are carried into the message where it sent any.
proc ::tclpdf::sign::TsAnswer {response what} {
  lassign [DerEnter $response 0 0x30 TimeStampResp $what] start end
  lassign [DerEnter $response $start 0x30 PKIStatusInfo $what] sStart sEnd
  lassign [DerEnter $response $sStart 0x02 PKIStatus $what] vStart vEnd
  binary scan [string range $response $vStart [expr {$vEnd - 1}]] cu status
  if {$status > 1} {
    set said {}
    if {$vEnd < $sEnd} {
      regsub -all {[^ -~]+} \
          [string range $response $vEnd [expr {$sEnd - 1}]] { } said
      set said [string trim $said]
    }
    return -code error -errorcode [list TCLPDF TIMESTAMP STATUS $status] \
        "tclpdf: the timestamp authority refused the request for\
        $what with PKIStatus $status[expr {$said ne {} ? " - \"$said\"" : {}}]\
        (RFC 3161, 2.4.2). Nothing was written"
  }
  if {$sEnd >= $end} {
    return -code error -errorcode [list TCLPDF TIMESTAMP TOKEN missing] \
        "tclpdf: the timestamp authority granted the request for\
        $what but sent no TimeStampToken - a granted TimeStampResp carries\
        one (RFC 3161, 2.4.2). Nothing was written"
  }
  return [string range $response $sEnd [expr {$end - 1}]]
}

# Into the token as far as TSTInfo: ContentInfo > [0] > SignedData >
# encapContentInfo > eContent [0] > OCTET STRING. The content type is held
# to id-ct-TSTInfo on the way - a signed object of any other kind is not a
# timestamp, however valid its signature.
proc ::tclpdf::sign::TstInfo {token what} {
  lassign [DerEnter $token 0 0x30 ContentInfo $what] start end
  lassign [DerRead $token $start $what] tag oStart oEnd
  lassign [DerEnter $token $oEnd 0xa0 content $what] cStart cEnd
  lassign [DerEnter $token $cStart 0x30 SignedData $what] dStart dEnd
  # version, then the digest algorithm SET, then encapContentInfo.
  lassign [DerRead $token $dStart $what] tag vStart vEnd
  lassign [DerRead $token $vEnd $what] tag aStart aEnd
  lassign [DerEnter $token $aEnd 0x30 encapContentInfo $what] eStart eEnd
  lassign [DerRead $token $eStart $what] tag tStart tEnd
  set contentType [string range $token $eStart [expr {$tEnd - 1}]]
  if {$contentType ne [DerOid 1.2.840.113549.1.9.16.1.4]} {
    return -code error -errorcode [list TCLPDF TIMESTAMP TOKEN contentType] \
        "tclpdf: the signed object in the timestamp response for\
        $what is not a TSTInfo - its content type is not id-ct-TSTInfo\
        (RFC 3161, 2.4.2)"
  }
  lassign [DerEnter $token $tEnd 0xa0 eContent $what] wStart wEnd
  lassign [DerEnter $token $wStart 0x04 {eContent octets} $what] iStart iEnd
  return [string range $token $iStart [expr {$iEnd - 1}]]
}

# What the token states, held against what was asked: the imprint has to be
# THIS file's digest under THIS algorithm, and the nonce has to be the one
# sent - without that check a replayed token for other bytes would embed
# without a word. Answers genTime and the serial for the caller's record.
proc ::tclpdf::sign::TstVerified {tstInfo digest algorithmOid nonce what} {
  lassign [DerEnter $tstInfo 0 0x30 TSTInfo $what] start end
  lassign [DerRead $tstInfo $start $what] tag vStart vEnd
  lassign [DerRead $tstInfo $vEnd $what] tag pStart pEnd
  lassign [DerEnter $tstInfo $pEnd 0x30 messageImprint $what] mStart mEnd
  lassign [DerRead $tstInfo $mStart $what] tag aStart aEnd
  lassign [DerEnter $tstInfo $aEnd 0x04 hashedMessage $what] hStart hEnd
  set imprint [string range $tstInfo $hStart [expr {$hEnd - 1}]]
  if {$imprint ne $digest} {
    return -code error -errorcode [list TCLPDF TIMESTAMP IMPRINT $what] \
        "tclpdf: the timestamp token carries a digest that is not\
        the one sent for $what - the authority answered for other bytes, and\
        embedding this token would timestamp nothing. Nothing was written"
  }
  set algorithm [string range $tstInfo $aStart [expr {$aEnd - 1}]]
  lassign [DerRead $algorithm 0 $what] tag gStart gEnd
  if {[string range $algorithm $gStart [expr {$gEnd - 1}]] \
      ne [string range [DerOid $algorithmOid] 2 end]} {
    return -code error -errorcode [list TCLPDF TIMESTAMP IMPRINT algorithm] \
        "tclpdf: the timestamp token names a different hash\
        algorithm than the one the digest for $what was made with"
  }
  lassign [DerEnter $tstInfo $mEnd 0x02 serialNumber $what] nStart nEnd
  binary scan [string range $tstInfo $nStart [expr {$nEnd - 1}]] H* serial
  lassign [DerRead $tstInfo $nEnd $what] tag tStart tEnd
  set genTime [string range $tstInfo $tStart [expr {$tEnd - 1}]]
  # Behind genTime: accuracy (SEQUENCE), ordering (BOOLEAN), nonce (INTEGER),
  # each optional - the tags tell them apart (RFC 3161, 2.4.2).
  set tokenNonce {}
  set offset $tEnd
  while {$offset < $end} {
    lassign [DerRead $tstInfo $offset $what] tag cStart cEnd
    if {$tag == 0x02} {
      set tokenNonce [string range $tstInfo $cStart [expr {$cEnd - 1}]]
      break
    }
    set offset $cEnd
  }
  set sent $nonce
  binary scan [string index $sent 0] cu first
  if {$first > 127} {
    set sent \x00$sent
  }
  if {$tokenNonce ne {} && $tokenNonce ne $sent} {
    return -code error -errorcode [list TCLPDF TIMESTAMP NONCE $what] \
        "tclpdf: the timestamp token answers a different nonce\
        than the request for $what carried - this is not the answer to this\
        request. Nothing was written"
  }
  return [list $serial $genTime]
}

# ---------------------------------------------------------------------------
# The transport
# ---------------------------------------------------------------------------

# RFC 3161 over HTTP (3.4): POST the request as application/timestamp-query,
# read the response as bytes. An https authority needs the tls package, and
# only then - a caller with neither reaches any authority through -tsa.
proc ::tclpdf::sign::TsFetch {url timeout tsq what} {
  package require http
  if {[string match https://* $url]} {
    if {[catch {package require tls} version]} {
      return -code error -errorcode [list TCLPDF TIMESTAMP TLS $url] \
          "tclpdf: $url is an https authority and the tls package\
          is not available ($version) - install tcltls, use an http://\
          authority, or hand the transport over with -tsa, a command prefix\
          that takes the DER request and answers the DER response"
    }
    ::http::register https 443 [list ::tls::socket -autoservername true]
  }
  set token [::http::geturl $url -binary true -timeout $timeout \
      -type application/timestamp-query -query $tsq]
  try {
    upvar #0 $token state
    if {[::http::status $token] ne "ok"} {
      return -code error -errorcode [list TCLPDF TIMESTAMP HTTP \
          [::http::status $token]] \
          "tclpdf: the timestamp authority $url did not answer\
          within $timeout ms for $what - [::http::status $token]\
          [::http::error $token]. Nothing was written"
    }
    if {[::http::ncode $token] != 200} {
      return -code error -errorcode [list TCLPDF TIMESTAMP HTTP \
          [::http::ncode $token]] \
          "tclpdf: the timestamp authority $url answered HTTP\
          [::http::ncode $token] for $what where 200 with a timestamp reply\
          was expected. Nothing was written"
    }
    return [::http::data $token]
  } finally {
    ::http::cleanup $token
  }
}

# ---------------------------------------------------------------------------
# The entry point
# ---------------------------------------------------------------------------

# The /DocTimeStamp dictionary: Type is required by Table 255, the SubFilter
# is the one 12.8.5.2 names, and there is no /M and no name or reason - the
# time is IN the token, stated by the authority, and a second statement
# beside it could only disagree.
proc ::tclpdf::sign::TsDictionary {size} {
  variable byteRangePlaceholder
  return [::tclpdf::pdfObj dictionary [list \
      Type /DocTimeStamp \
      Filter /Adobe.PPKLite \
      SubFilter /ETSI.RFC3161 \
      ByteRange $byteRangePlaceholder \
      Contents <[string repeat 0 [expr {2 * $size}]]>]]
}

# A document timestamp onto a finished file, as an incremental update.
# Answers a dictionary: field, page, size, byteRange, length (of the token),
# appended, serial and time (genTime as the token spells it, UTC), and url
# or tsa - whichever transport answered.
proc ::tclpdf::sign::timestamp {path args} {
  package require tclpdf::update 1.0-

  set options [::tclpdf::option parse {
    url https://tsr.open-tsa.eu tsa {} hash sha256 size 8192
    field {} page 0 policy {} timeout 15000
  } $args "for ::tclpdf::sign timestamp"]

  set hash [dict get $options hash]
  # The three the authorities of today take; SHA-1 is not offered at all.
  switch -- $hash {
    sha256 {set algorithmOid 2.16.840.1.101.3.4.2.1}
    sha384 {set algorithmOid 2.16.840.1.101.3.4.2.2}
    sha512 {set algorithmOid 2.16.840.1.101.3.4.2.3}
    default {
      return -code error -errorcode [list TCLPDF TIMESTAMP HASH $hash] \
          "tclpdf: unknown -hash \"$hash\" for ::tclpdf::sign\
          timestamp - known are: sha256, sha384, sha512"
    }
  }
  set size [Size [dict get $options size] "::tclpdf::sign timestamp"]
  set page [dict get $options page]

  set data [::tclpdf::io read $path]
  set what "\"$path\""
  # A file with no signature at all is the plain case here - a timestamp
  # proves existence and needs nobody to have signed. Where signatures ARE
  # present, the same two questions [add] asks are asked: the newest one has
  # to describe this very file, and none may still be waiting for its value,
  # since this update would move the bytes it is yet to sign.
  if {[string first /ByteRange $data] >= 0} {
    Describes $data [Locate $data $what 0] $what
    WaitingAnywhere $data
  }

  set upd [::tclpdf::update open $path]
  try {
    if {[$upd base] != [string length $data]} {
      return -code error -errorcode [list TCLPDF SIGN CHANGED $what] \
          "tclpdf: $what changed while it was being timestamped -\
          it was [string length $data] bytes and the update read [$upd base]"
    }
    set catalog [Number [$upd trailer Root] $what "the trailer's /Root"]
    set catalogValue [Value [$upd body $catalog]]
    set pageNumber [PageNumber $upd $catalogValue $page $what]
    set docMdp [DocMdp $upd $catalogValue]
    if {$docMdp eq "1"} {
      return -code error -errorcode [list TCLPDF SIGN STATE certified] \
          "tclpdf: $what is certified with DocMDP /P 1, which\
          permits no change at all (ISO 32000-2, 12.8.4.2, Table 257) - but\
          its NOTE for P exempts document timestamps only under /P 2 and\
          /P 3, not under 1. The file is unchanged"
    }
    set field [FieldName $upd $catalogValue [dict get $options field] \
        Timestamp $what]
    set signature [$upd add [TsDictionary $size]]
    set widget [$upd add [Widget $field [$upd ref $signature] \
        [$upd ref $pageNumber] {} {}]]
    Enlist $upd $catalog $catalogValue $widget
    Annotate $upd $pageNumber $widget
    set appended [$upd appendix]
  } finally {
    $upd destroy
  }

  lassign [Ranged $data $appended $what] data located byteRange length

  set digest [::tclpdf::crypto::$hash [Bytes $data $byteRange]]
  set nonce [::tclpdf::crypto::random 8]
  set tsq [TsQuery $digest $algorithmOid [dict get $options policy] $nonce]

  if {[dict get $options tsa] ne {}} {
    set answered [uplevel #0 [dict get $options tsa] [list $tsq]]
    set through [list tsa [dict get $options tsa]]
  } else {
    set answered [TsFetch [dict get $options url] \
        [dict get $options timeout] $tsq $what]
    set through [list url [dict get $options url]]
  }
  set token [TsAnswer $answered $what]
  lassign [TstVerified [TstInfo $token $what] $digest $algorithmOid \
      $nonce $what] serial genTime

  if {2 * [string length $token] > 2 * $size} {
    return -code error -errorcode [list TCLPDF TIMESTAMP SIZE \
        [string length $token]] \
        "tclpdf: the timestamp token for $what is\
        [string length $token] bytes and the field reserves $size - call\
        again with -size [expr {[string length $token] + 1024}] or more.\
        The file is unchanged"
  }
  set data [Fill $data $located $token]
  if {[string length $data] != $length} {
    return -code error -errorcode [list TCLPDF SIGN INTERNAL length] \
        "tclpdf: writing the token into $what changed the file\
        length, which cannot be - the /ByteRange describes its own file"
  }
  ::tclpdf::io write $path $data

  return [dict create field $field page $page size $size \
      byteRange $byteRange length [string length $token] \
      appended [string length $appended] serial $serial time $genTime \
      {*}$through]
}

package provide tclpdf::timestamp 1.1
