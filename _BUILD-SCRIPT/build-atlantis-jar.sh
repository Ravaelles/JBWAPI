#!/usr/bin/env bash
#
# Build the Atlantis flavour of JBWAPI and install it into Atlantis.
#
# WHY THIS EXISTS
# ---------------
# Atlantis runs its E2E tests on OpenBW, and OpenBW does not publish a BWAPI region
# graph (`regionCount = 0`). Stock JBWAPI answers `Game.hasPath(...)` over that graph, so
# it returned `false` for EVERY pair of positions - including a position paired with
# itself. JBWAPI's own `Game.canBuildHere` consults `hasPath` as the builder-reachability
# check, so `Unit.build(...)` refused a tile the builder was standing on and Atlantis
# could not place a single building. Measured: 104 of 104 build attempts refused while
# every other precondition read correct.
#
# The fix lives on the branch `feature/fix-regions-for-openbw`: when the region graph is
# empty, `hasPath` answers from terrain instead. Detected from the DATA, not from a
# version string or a flag, so an engine that does publish regions keeps the behaviour it
# had and the patch is inert there.
#
# Usage:  bash _BUILD-SCRIPT/build-atlantis-jar.sh [output-path]
# Default output: /sc-ai/Atlantis/lib/jbwapi-2.2.0-atlantis.jar
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_OUT="/sc-ai/Atlantis/lib/jbwapi-2.2.0-atlantis.jar"
OUT="${1:-$DEFAULT_OUT}"

ARTIFACT_NAME="jbwapi-2.2.0"
FAT_JAR="$REPO_DIR/target/$ARTIFACT_NAME-jar-with-dependencies.jar"

say() { echo "[build-atlantis-jar] $*"; }
fail() { echo "[build-atlantis-jar] ERROR: $*" >&2; exit 1; }

cd "$REPO_DIR"

# The patch must be present, or this script would happily ship stock JBWAPI under a name
# that promises a fix - the exact failure mode that wastes a session ("why is placement
# still broken? the jar says atlantis").
grep -q "Atlantis patch" src/main/java/bwapi/Game.java \
  || fail "the Atlantis patch is not in src/main/java/bwapi/Game.java - check the branch"

say "branch: $(git rev-parse --abbrev-ref HEAD)"
say "commit: $(git rev-parse --short HEAD)"

# `package` runs the library's own tests by default; they are unrelated to the patch and
# the budget here is 120 s (CONVENTIONS §13), so they are skipped - stated rather than
# hidden. The verification that matters for this jar is the Atlantis run it enables.
say "building (mvn package -DskipTests)..."
timeout 110 mvn -q package -DskipTests || fail "maven build failed"

[ -f "$FAT_JAR" ] || fail "expected artefact not produced: $FAT_JAR"

mkdir -p "$(dirname "$OUT")"
cp "$FAT_JAR" "$OUT"

# The class-file major version is two big-endian bytes at offset 6 (after CAFEBABE and
# the 2-byte minor). Reading one byte at offset 6 yields `0` for every Java 8 class, which
# is what a first version of this check did - it reported "major is 0" on a perfectly good
# build. Both bytes are read and combined, and the result is cross-checked with javap
# because the guard is meant to catch a wrong JDK, not to be a puzzle of its own.
MAJOR_BYTES=($(unzip -p "$OUT" bwapi/Game.class | od -An -tu1 -j6 -N2))
MAJOR=$(( MAJOR_BYTES[0] * 256 + MAJOR_BYTES[1] ))
[ "$MAJOR" = "52" ] || fail "bytecode major is $MAJOR, expected 52 (Java 8) - CONVENTIONS §16"

JAVAP_MAJOR="$(cd "$(mktemp -d)" && unzip -q -o "$OUT" bwapi/Game.class && javap -v bwapi/Game.class 2>/dev/null | sed -n 's/.*major version: //p' | head -1)"
[ "$JAVAP_MAJOR" = "52" ] || fail "javap disagrees about the bytecode version ($JAVAP_MAJOR) - build is not reproducible"

say "installed: $OUT ($(stat -c%s "$OUT") bytes, bytecode major $MAJOR)"
say ""
say "Atlantis picks this up by default (scripts/build-bot-jar.sh). For a comparison build"
say "against STOCK JBWAPI: BWAPI_JAR=lib/jbwapi-2.2.0.jar bash scripts/build-bot-jar.sh"
