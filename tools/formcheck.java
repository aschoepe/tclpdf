//
// tclpdf - does an interactive form actually WORK, not just parse
//
//   java -cp tools/Mustang-CLI-<v>.jar tools/formcheck.java <file.pdf> ...
//
// Copyright (C) 2026 Alexander Schoepe, Bochum, DE, <alx.tcl@sowaswie.de>
//
// See the file "license.terms" for information on usage and redistribution
// of this file (MIT License).
//
// No build step and no new dependency: the Mustang jar this project already
// carries for the ZUGFeRD check contains a complete Apache PDFBox 3.0.8, and
// java runs a single .java file straight from source (JEP 330). The jar is
// the classpath, this file is the program.
//
// WHY a second reader at all. qpdf answers whether the bytes are a PDF and
// verapdf whether the file obeys a profile; neither of them ever USES a
// field. PDFBox does: setValue() builds the appearance stream from /DA and
// /DR the way a viewer would, and refuses when the two disagree. Measured on
// a file whose /DA names a font missing from /DR: "qpdf --check" says "No
// syntax or stream encoding errors found", "qpdf --generate-appearances"
// writes an /AP calling a font that is not there, and only PDFBox says
// "Could not find font: /Xyzz". That is the likeliest mistake a fresh form
// writer makes, and this is the only tool on the machine that sees it.
//
// The order matters: every widget is INSPECTED first and written afterwards,
// because setValue() creates the missing appearance stream it is supposed to
// prove was there. Checking after writing would check this program's work.
//
// Output is one line per fact, prefix first, so a shell can grep it:
//
//   FORM   <file> fields=<n> needappearances=<bool> xfa=<bool>
//   FIELD  name=<fqn> type=<ft>/<class> value=[..] tu=[..] widgets=<n> ap=<..>
//   SET    name=<fqn> ok value=[..]
//   ERROR  <what went wrong>
//   OK|FAIL <file>: <summary>
//
// The FAIL line repeats the first ERROR of that file, so a caller handed
// several files at once can report each one from its own verdict line
// without having to work out which ERROR belonged to which document.
//
// Exit status 0 only when every field carried; 1 on any ERROR, 2 when the
// file could not be read or names no form at all.

import org.apache.pdfbox.Loader;
import org.apache.pdfbox.pdmodel.PDDocument;
import org.apache.pdfbox.pdmodel.interactive.annotation.PDAnnotationWidget;
import org.apache.pdfbox.pdmodel.interactive.annotation.PDAppearanceDictionary;
import org.apache.pdfbox.pdmodel.interactive.form.PDAcroForm;
import org.apache.pdfbox.pdmodel.interactive.form.PDField;
import org.apache.pdfbox.pdmodel.interactive.form.PDSignatureField;
import org.apache.pdfbox.pdmodel.interactive.form.PDTextField;
import org.apache.pdfbox.pdmodel.common.PDRectangle;

import java.io.File;
import java.util.List;

public class formcheck {

  private static int errors = 0;
  private static String firstError = "";

  public static void main(String[] argv) {
    if (argv.length == 0) {
      System.out.println("usage: java -cp <mustang.jar> tools/formcheck.java <file.pdf> ...");
      System.exit(2);
    }
    int worst = 0;
    for (String name : argv) {
      int rc = check(new File(name));
      if (rc > worst) {
        worst = rc;
      }
    }
    System.exit(worst);
  }

  private static int check(File file) {
    errors = 0;
    firstError = "";
    PDDocument doc = null;
    try {
      doc = Loader.loadPDF(file);
    } catch (Throwable e) {
      System.out.println("ERROR  " + file.getName() + " unreadable: " + brief(e));
      System.out.println("FAIL   " + file.getName() + ": not a readable PDF");
      return 2;
    }
    try {
      // getAcroForm(null) - the RAW form. The no-argument call applies
      // AcroFormDefaultFixup, and that runs AcroFormGenerateAppearancesProcessor:
      // measured on a file carrying /NeedAppearances true, PDFBox built the
      // missing appearances itself and then reported needappearances=false. A
      // checker that repairs its subject before looking at it reports on its
      // own work, so the fixup is refused here and every appearance below is
      // the one the file really carries.
      PDAcroForm form = doc.getDocumentCatalog().getAcroForm(null);
      if (form == null) {
        // Not this program's business to decide, but it IS a contradiction:
        // this tool is only ever handed documents that announced a form.
        System.out.println("ERROR  " + file.getName() + " has no /AcroForm");
        System.out.println("FAIL   " + file.getName() + ": no interactive form");
        return 2;
      }

      List<PDField> fields;
      try {
        fields = form.getFields();
      } catch (Throwable e) {
        System.out.println("ERROR  " + file.getName() + " field list unreadable: " + brief(e));
        System.out.println("FAIL   " + file.getName() + ": field tree broken");
        return 1;
      }

      boolean xfa = form.getXFA() != null;
      int count = 0;
      for (PDField f : form.getFieldTree()) {
        count++;
      }
      System.out.println("FORM   " + file.getName()
          + " fields=" + count
          + " needappearances=" + form.getNeedAppearances()
          + " xfa=" + xfa
          + " rootfields=" + fields.size());

      // NeedAppearances shifts the work onto the viewer, and a viewer that
      // does not do it shows an empty field. ISO 19005 forbids the value
      // outright (6.4.1), so it is wrong here in every case.
      if (form.getNeedAppearances()) {
        fail("/NeedAppearances is true - the file leaves the appearance to the viewer");
      }
      if (xfa) {
        fail("/XFA present - forbidden in PDF/A and PDF/UA, and withdrawn in PDF 2.0");
      }

      int text = 0;
      for (PDField f : form.getFieldTree()) {
        // INSPECT. Nothing below this point may write, or the /AP report
        // would describe a stream this program had just made itself.
        String fqn = f.getFullyQualifiedName();
        String kind = f.getFieldType() + "/" + f.getClass().getSimpleName();
        String tu = f.getAlternateFieldName();
        String value;
        try {
          // A signature field answers getValueAsString() with the toString()
          // of its PDSignature, identity hash and all, so the same document
          // checked twice would print two different lines. Two words instead.
          if (f instanceof PDSignatureField) {
            value = ((PDSignatureField) f).getSignature() == null ? "unsigned" : "signed";
          } else {
            value = f.getValueAsString();
          }
        } catch (Throwable e) {
          value = "?";
          fail("field '" + fqn + "' value unreadable: " + brief(e));
        }

        List<PDAnnotationWidget> widgets;
        try {
          widgets = f.getWidgets();
        } catch (Throwable e) {
          widgets = List.of();
          fail("field '" + fqn + "' widget list unreadable: " + brief(e));
        }

        StringBuilder ap = new StringBuilder();
        // Collected, not reported yet: the FIELD line has to come before the
        // faults found in it, or a reader cannot tell which field they belong to.
        List<String> faults = new java.util.ArrayList<>();
        int n = 0;
        for (PDAnnotationWidget w : widgets) {
          if (n++ > 0) {
            ap.append(',');
          }
          PDAppearanceDictionary d = w.getAppearance();
          boolean visible = !w.isHidden() && !w.isNoView() && hasArea(w.getRectangle());
          if (d == null) {
            ap.append("none");
            if (visible) {
              // A widget with no appearance dictionary is drawn by nobody.
              // poppler papers over it by inventing one, which is why
              // pdftotext must never be believed here.
              faults.add("field '" + fqn + "' widget " + n + " is visible and has no /AP");
            }
          } else if (d.getNormalAppearance() == null) {
            ap.append("no-N");
            if (visible) {
              faults.add("field '" + fqn + "' widget " + n + " is visible and its /AP has no /N");
            }
          } else {
            ap.append(visible ? "yes" : "yes(hidden)");
          }
        }
        if (widgets.isEmpty() && f.getFieldType() != null) {
          ap.append("no-widget");
        }

        System.out.println("FIELD  name=" + safe(fqn)
            + " type=" + kind
            + " value=[" + safe(value) + "]"
            + " tu=[" + safe(tu) + "]"
            + " widgets=" + widgets.size()
            + " ap=" + (ap.length() == 0 ? "-" : ap.toString()));
        for (String fault : faults) {
          fail(fault);
        }

        if (f instanceof PDTextField) {
          text++;
        }
      }

      // USE. Every text field is written once, which is what forces the
      // appearance stream to be built from /DA against /DR. The document is
      // never saved - the file on disk is not touched.
      for (PDField f : form.getFieldTree()) {
        if (!(f instanceof PDTextField)) {
          continue;
        }
        PDTextField t = (PDTextField) f;
        String fqn = t.getFullyQualifiedName();
        String before;
        try {
          before = t.getValue();
        } catch (Throwable e) {
          before = "";
        }
        String probe = (before == null || before.isEmpty()) ? "tclpdf" : before;
        try {
          t.setValue(probe);
        } catch (Throwable e) {
          fail("field '" + fqn + "' setValue: " + brief(e));
          continue;
        }
        String back;
        try {
          back = t.getValueAsString();
        } catch (Throwable e) {
          fail("field '" + fqn + "' value not readable back: " + brief(e));
          continue;
        }
        if (!probe.equals(back)) {
          fail("field '" + fqn + "' wrote [" + safe(probe) + "] and read back [" + safe(back) + "]");
          continue;
        }
        boolean built = true;
        for (PDAnnotationWidget w : t.getWidgets()) {
          PDAppearanceDictionary d = w.getAppearance();
          if (d == null || d.getNormalAppearance() == null) {
            built = false;
          }
        }
        if (!built) {
          fail("field '" + fqn + "' has no /AP even after setValue");
          continue;
        }
        System.out.println("SET    name=" + safe(fqn) + " ok value=[" + safe(probe) + "]");
      }

      if (errors == 0) {
        System.out.println("OK     " + file.getName() + ": " + count + " field(s), "
            + text + " text field(s) written");
        return 0;
      }
      System.out.println("FAIL   " + file.getName() + ": " + errors + " error(s): " + firstError);
      return 1;
    } catch (Throwable e) {
      System.out.println("ERROR  " + file.getName() + ": " + brief(e));
      System.out.println("FAIL   " + file.getName() + ": check aborted");
      return 1;
    } finally {
      try {
        doc.close();
      } catch (Throwable ignored) {
        // closing a document that was only read cannot lose anything
      }
    }
  }

  // Nothing is drawn in no space, so a widget of zero width or height owes no
  // appearance - ISO 32000-2 says a signature field that is not meant to be
  // seen shall have exactly that rectangle, and this package's invisible
  // signature examples are built that way. Demanding an /AP of them would put
  // a permanent red line under a correct document.
  private static boolean hasArea(PDRectangle r) {
    return r != null && Math.abs(r.getWidth()) > 0.0f && Math.abs(r.getHeight()) > 0.0f;
  }

  private static void fail(String what) {
    errors++;
    if (firstError.isEmpty()) {
      firstError = what;
    }
    System.out.println("ERROR  " + what);
  }

  // The message, not the stack trace: this runs inside a shell report where
  // one line per fault is the whole point. The class name is kept for the
  // exceptions that carry no message at all.
  private static String brief(Throwable e) {
    String m = e.getMessage();
    if (m == null || m.isEmpty()) {
      m = e.getClass().getName();
    } else {
      m = e.getClass().getSimpleName() + ": " + m;
    }
    return safe(m);
  }

  // Field names and values come out of the file under test, so they may hold
  // anything at all. One line per fact only holds if nothing in it can break
  // the line.
  private static String safe(String s) {
    if (s == null) {
      return "";
    }
    StringBuilder b = new StringBuilder(s.length());
    for (int i = 0; i < s.length() && i < 200; i++) {
      char c = s.charAt(i);
      b.append(c < 0x20 || c == 0x7f ? ' ' : c);
    }
    if (s.length() > 200) {
      b.append("...");
    }
    return b.toString();
  }
}
