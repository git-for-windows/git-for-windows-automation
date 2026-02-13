#!/bin/sh
#
# Rebase a shears/* branch onto a new upstream base.
#
# Usage: rebase-branch.sh <shears-branch> <upstream-branch>
#
# Parameters:
#   shears-branch   - The branch to rebase (e.g., shears/seen)
#   upstream-branch - The upstream branch to rebase onto (e.g., upstream/seen)
#
# Preconditions:
#   - Must be run from a git repository with both branches fetched
#
# The script creates a worktree, rebases the branch, and leaves the result
# ready for inspection or push.

set -ex

die () {
	echo "error: $*" >&2
	exit 1
}

usage () {
	die "usage: $0 <shears-branch> <upstream-branch>"
}

# Parse arguments
test $# -ge 2 || usage
SHEARS_BRANCH=$1
UPSTREAM_BRANCH=$2

# Validate branches exist
git rev-parse --verify "origin/$SHEARS_BRANCH" >/dev/null 2>&1 ||
	die "Branch not found: origin/$SHEARS_BRANCH"
git rev-parse --verify "$UPSTREAM_BRANCH" >/dev/null 2>&1 ||
	die "Branch not found: $UPSTREAM_BRANCH"

# Set up worktree
WORKTREE_DIR="$PWD/rebase-worktree-${SHEARS_BRANCH##*/}"
REPORT_FILE="$WORKTREE_DIR/conflict-report.md"

echo "::group::Setup worktree"
echo "Creating worktree at $WORKTREE_DIR..."
git worktree add -B "$SHEARS_BRANCH" "$WORKTREE_DIR" "origin/$SHEARS_BRANCH" ||
	die "Could not create worktree at $WORKTREE_DIR"
cd "$WORKTREE_DIR"
echo "::endgroup::"

# Find the merging-rebase marker
OLD_MARKER=$(git rev-parse "HEAD^{/Start.the.merging-rebase}") ||
	die "Could not find merging-rebase marker in $SHEARS_BRANCH"
OLD_UPSTREAM=$(git rev-parse "$OLD_MARKER^1")
NEW_UPSTREAM=$(git rev-parse "$UPSTREAM_BRANCH")
TIP_OID=$(git rev-parse HEAD)

echo "::notice::Old marker: $OLD_MARKER"
echo "::notice::Old upstream: $OLD_UPSTREAM"
echo "::notice::New upstream: $NEW_UPSTREAM"
echo "::notice::Current tip: $TIP_OID"

# Save original values for the range-diff (before any sync/adoption)
ORIG_OLD_MARKER=$OLD_MARKER
ORIG_TIP_OID=$TIP_OID

# Sync with origin/main if it has commits we don't have yet
GFW_MAIN_BRANCH="origin/main"
BEHIND_COUNT=$(git rev-list --count "$TIP_OID..$GFW_MAIN_BRANCH") ||
	die "Could not determine how far behind $GFW_MAIN_BRANCH we are"

if test "$BEHIND_COUNT" -gt 0; then
	if git rev-list --grep='^Start the merging-rebase' "$TIP_OID..$GFW_MAIN_BRANCH" | grep -q .; then
		# origin/main was rebased — adopt its state directly
		echo "::notice::origin/main was rebased, adopting its $BEHIND_COUNT commits"
		git checkout -B "$SHEARS_BRANCH" "$GFW_MAIN_BRANCH" ||
			die "Could not adopt $GFW_MAIN_BRANCH"
		TIP_OID=$(git rev-parse HEAD)
		OLD_MARKER=$(git rev-parse "HEAD^{/Start.the.merging-rebase}")
		OLD_UPSTREAM=$(git rev-parse "$OLD_MARKER^1")
	else
		echo "::notice::Syncing $BEHIND_COUNT commits from $GFW_MAIN_BRANCH"
		echo "::group::Rebasing $BEHIND_COUNT commits from $GFW_MAIN_BRANCH on top of $SHEARS_BRANCH"
		GIT_EDITOR=: git rebase -r HEAD "$GFW_MAIN_BRANCH"
		git checkout -B "$SHEARS_BRANCH" ||
			die "Could not update $SHEARS_BRANCH"
		TIP_OID=$(git rev-parse HEAD)
		echo "::endgroup::"
	fi
fi

# Check if there's anything to rebase after syncing
UPSTREAM_AHEAD=$(git rev-list --count "$OLD_UPSTREAM..$NEW_UPSTREAM")
if test "$UPSTREAM_AHEAD" -eq 0; then
	echo "::notice::Nothing to rebase: upstream has no new commits since $OLD_UPSTREAM"
	# Still need to push if we synced
	if test "$BEHIND_COUNT" -gt 0 && test -n "$GITHUB_OUTPUT"; then
		echo "to_push=$SHEARS_BRANCH" >>"$GITHUB_OUTPUT"
	fi
	exit 0
fi

# Initialize report
cat >"$REPORT_FILE" <<EOF
## Rebase Summary: ${SHEARS_BRANCH##*/}

**From**: $(git show --no-patch --format='[%h](https://github.com/git-for-windows/git/commit/%H) (%s, %as)' "$TIP_OID") ([$(git rev-parse --short "$OLD_MARKER")..$(git rev-parse --short "$TIP_OID")](https://github.com/git-for-windows/git/compare/$(git rev-parse "$OLD_MARKER")...$(git rev-parse "$TIP_OID")))
EOF

# Create new marker with two parents: upstream + origin/main
echo "::group::Creating marker and running rebase"
MARKER_OID=$(git commit-tree "$UPSTREAM_BRANCH^{tree}" \
	-p "$UPSTREAM_BRANCH" \
	-p "$GFW_MAIN_BRANCH" \
	-m "Start the merging-rebase to $UPSTREAM_BRANCH

This commit starts the rebase of $OLD_MARKER to $NEW_UPSTREAM") ||
	die "Could not create marker commit"

# Use a graft so that the marker looks like a single-parent commit during rebase
git replace --graft "$MARKER_OID" "$UPSTREAM_BRANCH" ||
	die "Could not create graft for marker $MARKER_OID"

REBASE_TODO_COUNT=$(git rev-list --count "$OLD_MARKER..$TIP_OID")
echo "Rebasing $REBASE_TODO_COUNT commits onto $MARKER_OID"

GIT_EDITOR=: git rebase -r --onto "$MARKER_OID" "$OLD_MARKER"
echo "::endgroup::"

# Clean up graft and verify
git replace -d "$MARKER_OID" ||
	die "Could not remove graft for marker $MARKER_OID"
MARKER_IN_RESULT=$(git rev-parse "HEAD^{/Start.the.merging-rebase}")
PARENT_COUNT=$(git rev-list --parents -1 "$MARKER_IN_RESULT" | wc -w)
test "$PARENT_COUNT" -eq 3 || # commit itself + 2 parents
	die "Marker should have 2 parents, found $((PARENT_COUNT - 1))"

# Generate range-diff comparing original patches with rebased patches
RANGE_DIFF=$(git range-diff "$ORIG_OLD_MARKER..$ORIG_TIP_OID" \
	"$MARKER_IN_RESULT..HEAD" || echo "Unable to generate range-diff")

# Finalize report
NEW_TIP=$(git rev-parse HEAD)
cat >>"$REPORT_FILE" <<EOF
**To**: $(git show --no-patch --format='[%h](https://github.com/git-for-windows/git/commit/%H) (%s, %as)' "$NEW_TIP") ([$(git rev-parse --short "$MARKER_IN_RESULT")..$(git rev-parse --short "$NEW_TIP")](https://github.com/git-for-windows/git/compare/$(git rev-parse "$MARKER_IN_RESULT")...$NEW_TIP))

<details>
<summary>Range-diff (click to expand)</summary>

\`\`\`
$RANGE_DIFF
\`\`\`

</details>

EOF

echo "Rebase completed: $(git rev-parse --short HEAD)"
cat "$REPORT_FILE"

# Write to GitHub Actions job summary
if test -n "$GITHUB_STEP_SUMMARY"; then
	cat "$REPORT_FILE" >>"$GITHUB_STEP_SUMMARY"
fi
