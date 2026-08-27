# PDF/A and ZUGFeRD / Factur-X / Order-X

Everything here needs **tdom** - the XMP packet is built with it.

## A PDF/A-3 document

```tcl
package require tclpdf
set doc [tclpdf new -unit mm]
$doc info Title "Reference: PDF/A"        ;# a title: 3a and UA insist, and it costs nothing
$doc language en-GB
$doc page add

# EVERY face embedded - the standard fourteen are not allowed. Metric stand-ins for
# them: URW Core 35 (NimbusSans for Helvetica, NimbusRoman for Times, NimbusMonoPS
# for Courier), or Liberation Sans/Serif/Mono (Arimo/Tinos/Cousine at Google Fonts).
$doc font embed body $ttf
$doc font embed bodyBold $ttfBold

# Part 2 or 3, and neither of the others can be reached: part 1 forbids transparency,
# which this package writes through opacity and PNG soft masks, and part 4 is refused
# outright because every PDF/A claim here is written as PDF 1.7 (a 2.0 document is
# refused the claim, and pdfa lowers nothing). Conformance B (default), U or A.
# Without -profile the shipped sRGB profile is the output intent. Raises the file
# to 1.7 - configure -version 2.0 is refused from here on. Part 2 refuses attachments.
$doc pdfa -part 3 -conformance U
puts "pdfa: [$doc pdfa state]"            ;# part conformance profile identifier extensions registered

$doc font -family body -size 10
$doc text "PDF/A-3U: looks the same in fifteen years, text extractable." -at {20 20}
$doc rect -at {20 30} -size {40 10} -fill steelblue           ;# RGB under an sRGB intent: fine
$doc rect -at {65 30} -size {40 10} -fill {gray 0.5}          ;# grey passes under EVERY intent
if {[catch {$doc rect -at {110 30} -size {40 10} -fill {cmyk 0 0.16 1 0}; $doc write [file join $out ref-10-wrong.pdf]} message]} {
    puts "CMYK under an sRGB intent is refused at the write: [string range $message 0 120]..."
} else {
    puts "CMYK under an sRGB intent: NOT REFUSED"
}
```

`U` is the stronger claim at no cost - the ToUnicode map is written anyway. `A` needs `tagged 1` before anything is drawn. Order does not matter: the font and colour checks run when the file is written, whether `pdfa` came before or after the drawing.

## The colour rule, and the ways round it

ISO 19005-2, 6.2.4.3: DeviceGray under any intent, DeviceRGB only under an RGB one, DeviceCMYK only under a CMYK one - on every road: fills, strokes, text, a picture's space (Indexed PNG = RGB, CMYK JPEG = CMYK), a shading, the content of a pattern or a form, the alternate of a separation. The write refuses the offenders naming the calls and pages.

```tcl
# The wrong rectangle above is in the page for good - a refused WRITE does not undo
# drawing. Start over for the CMYK case: a CMYK press intent, and colours that fit it.
$doc destroy
set doc [tclpdf new -unit mm]
$doc info Title "Reference: PDF/A under a CMYK intent"
$doc page add
$doc font embed body $ttf
$doc pdfa -part 3 -conformance B -profile $iccCmyk -identifier "ISO Coated v2 (ECI)"
$doc font -family body -size 10 -color {cmyk 0 0 0 1}
$doc text "Process colours under a CMYK output intent" -at {20 20}
$doc rect -at {20 30} -size {40 10} -fill {cmyk 0 0.16 1 0}
$doc rect -at {65 30} -size {40 10} -fill {gray 0.5}                  ;# grey: always
$doc icc embed srgb $iccRgb
$doc rect -at {110 30} -size {40 10} -fill {icc srgb 0.2 0.45 0.75}   ;# ICC based: anchored to its profile, admitted
# A table's striped head is RGB: override it under a CMYK intent.
$doc table -at {20 50} -width 100 -theme striped -head {{Item Sum}} -body {{parts 18.20}} \
    -style {family body size 9 lineColor {gray 0.6}} -headStyle {fill {cmyk 1 0.5 0 0.2} color {gray 1}} \
    -alternateFill {gray 0.95} -columns {{} {align decimal}}
$doc write [file join $out ref-10-pdfa-cmyk.pdf]
$doc destroy
```

Shipped profiles beside the package: `sRGB.icc` (default), `sRGB2014.icc`, `ISOcoated_v2_bas.ICC` (CMYK, FOGRA39), `ISOcoated_v2_grey1c_bas.ICC` (grey). Achromatic names (`black`, `white`, `gray`) are written as DeviceGray by themselves.

## An extension schema of your own (PDF/A admits only described metadata)

```tcl
set doc [tclpdf new -unit mm]
$doc info Title "Reference: PDF/A extension schema"
$doc page add
$doc font embed body $ttf
$doc pdfa -part 3 -conformance B
$doc font -family body -size 10
$doc text "A property of our own in the packet, with its schema described first." -at {20 20}

# ISO 19005-2, 6.6.2.3.1: the schema block first - name, namespace, prefix,
# every property with type, category, description - then the values.
$doc pdfa extension {<rdf:Description rdf:about="" xmlns:pdfaExtension="http://www.aiim.org/pdfa/ns/extension/" xmlns:pdfaSchema="http://www.aiim.org/pdfa/ns/schema#" xmlns:pdfaProperty="http://www.aiim.org/pdfa/ns/property#">
  <pdfaExtension:schemas>
    <rdf:Bag>
      <rdf:li rdf:parseType="Resource">
        <pdfaSchema:schema>Calibration certificate schema</pdfaSchema:schema>
        <pdfaSchema:namespaceURI>urn:example:calibration:1.0#</pdfaSchema:namespaceURI>
        <pdfaSchema:prefix>cal</pdfaSchema:prefix>
        <pdfaSchema:property>
          <rdf:Seq>
            <rdf:li rdf:parseType="Resource">
              <pdfaProperty:name>Laboratory</pdfaProperty:name>
              <pdfaProperty:valueType>Text</pdfaProperty:valueType>
              <pdfaProperty:category>external</pdfaProperty:category>
              <pdfaProperty:description>The laboratory that issued the certificate</pdfaProperty:description>
            </rdf:li>
          </rdf:Seq>
        </pdfaSchema:property>
      </rdf:li>
    </rdf:Bag>
  </pdfaExtension:schemas>
</rdf:Description>}
$doc pdfa extension {<rdf:Description rdf:about="" xmlns:cal="urn:example:calibration:1.0#">
  <cal:Laboratory>Calibration laboratory, Bochum</cal:Laboratory>
</rdf:Description>}
$doc write [file join $out ref-10-pdfa-extension.pdf]
$doc destroy
```

## ZUGFeRD / Factur-X: one call

```tcl
set doc [tclpdf new -unit mm]
$doc info Title "Invoice 2026-114"
$doc page add
$doc font embed body $ttf
$doc font -family body -size 10
$doc text "Invoice 2026-114 - the human-readable half of a hybrid invoice" -at {20 20}
$doc table -at {20 30} -width 170 -theme grid -head {{Item Net}} \
    -body {{"Consulting, 4 h" 480.00}} -foot {{{text "Net total" align right} 480.00}} \
    -columns {{} {width 30 align decimal}} -style {family body size 9}

# Reads the profile from BT-24, declares PDF/A-3B, writes the sRGB output intent,
# adds the Factur-X extension schema, attaches the XML as factur-x.xml with the
# /AFRelationship the profile prescribes (Data for MINIMUM and BASIC WL,
# Alternative for the fuller ones), uncompressed byte for byte. Returns the profile.
set profile [$doc zugferd $invoiceXml]
puts "profile from BT-24: $profile"
puts "zugferd: [$doc zugferd state]"       ;# name profile type version relationship bytes

# BT-24 read ahead, without writing anything (the XML as bytes, not a path):
set channel [open $invoiceXml rb]; set xml [read $channel]; close $channel
puts "zugferd profile: [$doc zugferd profile $xml]"

# Raise the claim afterwards: 3U keeps the extension in place; A needs tagged 1 besides.
$doc pdfa -conformance U
$doc write [file join $out ref-10-zugferd.pdf]
$doc destroy
```

Options: `-name` - the four names the standards allow, each bound to what it names: `factur-x.xml` or `zugferd-invoice.xml` for an ordinary invoice, `xrechnung.xml` for the `XRECHNUNG` profile **and for no other** (Factur-X 1.09.2, 7.7 binds the reference profile's name to it and forbids it every other, so `-profile XRECHNUNG` takes `xrechnung.xml` by default and refuses `factur-x.xml`), and `order-x.xml` for an order. Once the document carries the invoice, `attach` refuses all four for anything else, in any spelling - `factur-x.XML` is a key of its own in the name tree and a reader would find two candidates. `-profile` overrides the level read from BT-24 (`MINIMUM`, `BASIC WL`, `BASIC`, `EN 16931`, `EXTENDED`, `XRECHNUNG`), `-type` (`INVOICE`, `ORDER`, `ORDER_RESPONSE`, `ORDER_CHANGE`), `-icc` another output intent profile (a CMYK one for an invoice in process colours), `-relationship`, `-description`, `-version` (the `fx:Version`, `1.0`), `-compress 1`. Every option is checked before the document is changed; a refused call leaves no claim, no schema, no attachment behind. Any further attachments (`attach`) ride along - part 3 admits them.

## Order-X on the same call

```tcl
set doc [tclpdf new -unit mm]
$doc info Title "Order 2026-77"
$doc page add
$doc font embed body $ttf
$doc font -family body -size 10
$doc text "Order 2026-77" -at {20 20}
# BT-24 urn:order-x.eu:1p0:basic|comfort|extended -> BASIC|COMFORT|EXTENDED, type ORDER
# (or -type ORDER_RESPONSE / ORDER_CHANGE), attached as order-x.xml with Data.
puts "order profile: [$doc zugferd $orderXml]"
puts "type: [dict get [$doc zugferd state] type], name: [dict get [$doc zugferd state] name]"
$doc write [file join $out ref-10-order-x.pdf]
$doc destroy
```

## Checking what came out

Nothing here replaces the validators; run them, with the profile the file claims:

```sh
qpdf --check out.pdf                       # structure and streams
verapdf -f 3b out.pdf                      # or 3u, 3a, 2b ...; --flavour ua1 / ua2 for PDF/UA
java -jar Mustang-CLI.jar --action validate --source invoice.pdf    # ZUGFeRD/Order-X: XML and PDF/A together
pdffonts out.pdf                           # every face embedded, subset tags
pdftotext out.pdf - | head                 # what a reader extracts
pdfinfo -struct-text out.pdf               # the structure tree
pdfsig out.pdf                             # a signature, its ranges and what openssl thinks of it
```

`veraPDF` does not see everything - a null byte in a font name is caught by qpdf only; a wrong printed page number by nobody.

**What an archivable document may still do**: it may be **signed** (`11-encryption-signatures.md` - measured: `isCompliant true`, 0 failed checks, and the embedded invoice byte-identical to the unsigned file's), it may carry **layers** (`/Order` is written for every group, which is what ISO 19005-2/-3, 6.9 asks), it may use **Lab** colours under any output intent, and it may carry a **Type 3** font, where the question of embedding does not arise. What it may **not** do is be encrypted: `pdfa` and `encrypt` are refused together in whichever order they are called. A page taken over with `pdf import` is not judged by the claim - validate the result.
