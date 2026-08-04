#!/usr/bin/env bash
# DESIGN-INDEX-P1 — the L2 core of the "load design context before editing a feature" reflex.
#
# The reflex (CLAUDE.md Workflow): before touching a feature, read its row in docs/DESIGN-INDEX.md
# (FDD + tri-model synthesis + TODO section) FIRST. That reflex is only useful if the index actually
# MAPS every feature's design docs — an index that silently rots (a new FDD/synthesis lands, no row)
# sends a fresh-context reader looking in a map with a hole exactly where they needed it. This gate
# stops the rot: it fails if the index is missing, or if any FDD / tri-model synthesis has no row.
#
# What it CANNOT do (the honest L4 residue, named not hidden): it cannot make an agent actually READ
# and INTEGRATE the right row before editing — an agent can still narrow-scope past a present, correct
# index. Same shape the federation names for B-PERSONA ("the actual READ stays the L4 cognitive
# residue"). This gate guards the MAP's completeness; the reading is judgment.
#
# Coverage rule: every docs/fdds/*.md (top level) and every docs/research/*-synthesis.md must have its
# basename appear somewhere in DESIGN-INDEX.md. Legs/briefs are intentionally NOT required (the index
# points at decisions, not their working papers).
#
# Overridable for the self-proof: DOCS_ROOT=<dir> (and optionally INDEX=<file>) runs against a fixture
# tree so the coverage logic is proven with no dependence on the real repo docs.
set -uo pipefail
cd "$(dirname "$0")/.." 2>/dev/null || true

DOCS_ROOT="${DOCS_ROOT:-docs}"
INDEX="${INDEX:-$DOCS_ROOT/DESIGN-INDEX.md}"

fail=0
echo "DESIGN-INDEX-P1 coverage lint (index=$INDEX)"

if [ ! -f "$INDEX" ]; then
	echo "  FAIL: $INDEX does not exist — the feature→docs map the 'load design context' reflex depends on"
	echo "        is missing. Create it (see the reference shape in the repo history)."
	echo ""
	echo "DESIGN-INDEX-P1 FAIL — no index."
	exit 1
fi

index_body=$(cat "$INDEX")

check_covered() { # $1 = dir, $2 = find-name pattern, $3 = human label
	local dir="$1" pat="$2" label="$3" f base
	[ -d "$dir" ] || return 0
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		base=$(basename "$f")
		if printf '%s' "$index_body" | grep -qF "$base"; then
			echo "  PASS $label: $base has a row"
		else
			echo "  FAIL $label: $base has NO row in the index — a reader looking for its feature's"
			echo "       design context finds a hole. Add a row (or fold it into an existing feature row)."
			fail=1
		fi
	done < <(find "$dir" -maxdepth 1 -name "$pat" 2>/dev/null | sort)
}

check_covered "$DOCS_ROOT/fdds" '*.md' 'FDD'
check_covered "$DOCS_ROOT/research" '*-synthesis.md' 'synthesis'

echo ""
if [ "$fail" -eq 0 ]; then
	echo "DESIGN-INDEX-P1 PASS — every FDD and tri-model synthesis is mapped in the design index."
else
	echo "DESIGN-INDEX-P1 FAIL — the index has holes (above). A rotted map defeats the reflex that reads it."
fi
exit "$fail"
