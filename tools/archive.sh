#!/bin/sh

set -e

if [ $# -lt 3 ]; then
    echo "usage: $0 PACKAGE_NAME PACKAGE_VERSION PKG_TCL_SOURCES" >&2
    echo "intended to be called via 'make release' (or 'make archive')" >&2
    exit 1
fi

# CDPATH would make cd print the target directory
unset CDPATH

PACKAGE_NAME=$1
PACKAGE_VERSION=$2
# all remaining arguments are the Tcl source files, whether the caller
# passed them as one quoted list or as individual words
shift 2
PKG_TCL_SOURCES="$@"

# ignore AppleDouble files
# macOS 10.4
COPY_EXTENDED_ATTRIBUTES_DISABLE=1
export COPY_EXTENDED_ATTRIBUTES_DISABLE
# macOS >= 10.5
COPYFILE_DISABLE=1
export COPYFILE_DISABLE

rm -f uv/${PACKAGE_NAME}*.zip uv/${PACKAGE_NAME}*.tar.gz

mkdir -p uv/${PACKAGE_NAME}${PACKAGE_VERSION}

cp ${PKG_TCL_SOURCES} manifest.txt pkgIndex.tcl license.terms uv/${PACKAGE_NAME}${PACKAGE_VERSION}

# icc/ goes into the BINARY archive as well: the output intent profile is a
# runtime part, not documentation - without it no PDF/A and therefore no
# ZUGFeRD. The directory name is kept, the package looks for
# [file join $dir icc sRGB.icc].
cp -R icc uv/${PACKAGE_NAME}${PACKAGE_VERSION}/

# xattr -r -d com.apple.provenance .: recursively (-r) deletes the extended attribute com.apple.provenance from the specified file or directory. com.apple.provenance: An extended attribute used by macOS (e.g., Finder or Gatekeeper) to track the origin of a file, such as downloaded sources.
# tar --no-mac-metadata: Do not store or restore Mac extended metadata (e.g., resource forks, Finder info, and so forth). This metadata is stored in special “AppleDouble” files or as extended attributes. This option is useful when creating archives to be used on non-Mac platforms.
# tar --disable-copyfile: This option is equivalent to setting the environment variable COPYFILE_DISABLE=1. It disables copying of extended attributes and resource forks by preventing the use of the copyfile() API. Use this when you want to avoid creation of ._* AppleDouble files or when those are not needed.
# tar --no-xattrs: Do not store or restore extended file attributes (xattrs). These are often system or application metadata not relevant or supported on other systems.

# Readable for everyone. cp keeps the modes of the checkout, and Fossil does
# not track read bits, so a file created with 0600 by an editor or a tool
# stays 0600 through every commit and clone - and travelled that way into a
# release: a user reported 37 of the modules as -rw------- in the tarball,
# unreadable once unpacked into a shared library directory. The modes are
# set on the copy, never on the checkout.
chmod -R u=rwX,go=rX uv/${PACKAGE_NAME}${PACKAGE_VERSION}

cd uv
zip -x '.DS_Store' -x '*/.DS_Store' -qr ${PACKAGE_NAME}${PACKAGE_VERSION}.zip ${PACKAGE_NAME}${PACKAGE_VERSION}
tar --no-xattrs --no-mac-metadata --disable-copyfile --exclude='.DS_Store' --exclude='*/.DS_Store' -czf ${PACKAGE_NAME}${PACKAGE_VERSION}.tar.gz ${PACKAGE_NAME}${PACKAGE_VERSION}
rm -fr ${PACKAGE_NAME}${PACKAGE_VERSION}

# The download page is optional: without the template it is skipped rather
# than failing the whole archive run.
if [ -f template-download.html ]; then
    cp template-download.html download.html
    ex - download.html <<!
g/PACKAGE_VERSION/s//${PACKAGE_VERSION}/g
wq
!
else
    echo "archive: template-download.html is missing - download.html not generated" >&2
fi

# The source archive takes the whole tree minus the exclusions below.
#
# examples/out holds what "make examples" produced. Built output has no place
# in a SOURCE archive - and the exclusion is needed because the tar below takes
# the whole tree rather than a list of files, so anything created in the
# checkout travels unless it is named here.
#
# docs/ is INTERNAL and does not travel. It is German working material - the
# state of play, the feature list with its reasoning, the conventions, a copy
# of the agent memory - and it is not even under version control:
# .fossil-settings/ignore-glob lists it, next to .claude/ and CLAUDE.md, which
# are excluded below for the same reason.
#
# It also held the ISO specifications themselves at one point - PDF 32000-1,
# 32000-2, the PDF/UA parts - 34 MB of LICENSED THIRD-PARTY DOCUMENTS that must
# not be redistributed. Measured before this line existed: the source archive
# was 34.4 MB against 115 KB for the binary one, and two of those directories
# landed OUTSIDE the package directory because their names carry spaces and a
# colon. "make publish" would have put all of it on a public server.
#
# examples/assets/xml used to be excluded for an unsettled licence. It is
# settled: both invoices carry the FeRD terms as an XML comment in their own
# head - measured, 5 708 bytes of the 7 929 in the MINIMUM file, 72 per cent of
# it - and those terms grant free use including redistribution and commercial
# products. The block is what makes them redistributable, so it MUST NOT be
# stripped when the files are copied or trimmed.
#
# examples/assets/fonts/adobe-standard-14 is the opposite case, and it is not
# a licence that is unsettled but one that is settled the other way. Those are
# the original fourteen as Adobe published them, Type 1 and OpenType, and every
# file says "All Rights Reserved" in its own copyright notice; Helvetica and
# Times are trademarks of Heidelberger Druckmaschinen, ZapfDingbats of ITC.
# They exist here for INTERNAL TESTING ONLY - to measure a substitute against
# the original - and they may not leave this machine. The exclusion is repeated
# in .fossil-settings/ignore-glob so that neither a commit nor an archive picks
# them up. Do not remove either one.
#
# tools/Mustang-CLI-*.jar is the same shape of problem in the smaller: the
# ZUGFeRD validator "make check" runs is a SEPARATE PROJECT under Apache 2.0
# and a 59 MB jar that whoever wants that check downloads themselves. It is
# ignore-globbed as well, so it never reaches a commit - but the tar below
# takes the working tree rather than the repository, so without this line it
# would ride along in the source archive, quadrupling it and putting foreign
# code into an MIT tarball without its licence.

# The source archive is taken through a staging copy for the same reason: the
# tree itself is not touched, the copy gets the modes, and the tar takes the
# copy. bsdtar cannot rewrite modes on the way in.
cd ../..
STAGE=${PACKAGE_NAME}/uv/${PACKAGE_NAME}${PACKAGE_VERSION}-src-stage
rm -rf ${STAGE}
mkdir -p ${STAGE}
tar --no-xattrs --no-mac-metadata --disable-copyfile \
    --exclude='uv/*' \
    --exclude="${PACKAGE_NAME}/examples/out" \
    --exclude="${PACKAGE_NAME}/examples/assets/fonts/adobe-standard-14" \
    --exclude="${PACKAGE_NAME}/docs" \
    --exclude="${PACKAGE_NAME}/.fslckout" \
    --exclude="${PACKAGE_NAME}/.fossil-settings" \
    --exclude="${PACKAGE_NAME}/.claude" \
    --exclude="${PACKAGE_NAME}/tools/Mustang-CLI-*.jar" \
    --exclude="${PACKAGE_NAME}/CLAUDE.md" \
    --exclude="${PACKAGE_NAME}/.gitattributes" \
    --exclude="${PACKAGE_NAME}/.vscode" \
    --exclude='.DS_Store' --exclude='*/.DS_Store' \
    --exclude='autom4te.cache' --exclude='configure~' --exclude='config.*' \
    -cf - ${PACKAGE_NAME} | (cd ${STAGE} && tar -xf -)
chmod -R u=rwX,go=rX ${STAGE}/${PACKAGE_NAME}
tar --no-xattrs --no-mac-metadata --disable-copyfile \
    -czf ${PACKAGE_NAME}/uv/${PACKAGE_NAME}${PACKAGE_VERSION}-src.tar.gz -C ${STAGE} ${PACKAGE_NAME}
rm -rf ${STAGE}

# And measured, not assumed: no entry of either tarball may lack the read bit
# for group and others. Fails the build if one does.
for archive in ${PACKAGE_NAME}/uv/${PACKAGE_NAME}${PACKAGE_VERSION}.tar.gz \
    ${PACKAGE_NAME}/uv/${PACKAGE_NAME}${PACKAGE_VERSION}-src.tar.gz; do
    unreadable=`tar -tzvf ${archive} | awk '$1 !~ /^.r..r..r../ {print $NF}'`
    if [ -n "${unreadable}" ]; then
        echo "archive: entries without read permission for everyone in ${archive}:" >&2
        echo "${unreadable}" >&2
        exit 1
    fi
done
