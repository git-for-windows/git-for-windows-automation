#!/bin/sh
#
# Rebase a shears/* branch onto a new upstream base.
#
# Usage: rebase-branch.sh <shears-branch> <upstream-branch> [<scripts-dir>]
#
# Parameters:
#   shears-branch   - The branch to rebase (e.g., shears/seen)
#   upstream-branch - The upstream branch to rebase onto (e.g., upstream/seen)
#   scripts-dir     - Optional: directory containing this script and agents
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

# Generate a correspondence map between two commit ranges using range-diff
# Usage: generate_correspondence_map <our-range> <their-range> <output-file>
generate_correspondence_map () {
	git -c core.abbrev=false range-diff --no-color "$1" "$2" >"$3" || :
}

# Find a corresponding commit in a map file
# Usage: find_correspondence <oid> <map-file>
# Returns: corresponding OID on stdout, exit 0 if found, 1 if not
# Sets CORRESPONDENCE_TYPE to "=" (identical) or "!" (modified)
find_correspondence () {
	test -s "$2" || return 1
	match=$(sed -n "s/^[0-9]*: $1 \([!=]\) [0-9]*: \([0-9a-f]*\).*/\1 \2/p" "$2" | head -1)
	test -n "$match" || return 1
	CORRESPONDENCE_TYPE=${match% *}
	echo "${match#* }"
}

# Run a rebase, automatically skipping commits that match upstream exactly
# and trying to reuse sibling resolutions via merge-tree
# Usage: run_rebase <rebase-args...>
run_rebase () {
	if GIT_EDITOR=: git rebase "$@" 2>&1; then
		return
	fi

	REBASE_MERGE_DIR=$(git rev-parse --git-path rebase-merge)
	while test -d "$REBASE_MERGE_DIR"; do
		git rev-parse --verify REBASE_HEAD >/dev/null 2>&1 ||
			die "rebase metadata exists but REBASE_HEAD is missing"
		rebase_head_oid=$(git rev-parse REBASE_HEAD)
		rebase_head_oneline=$(git show --no-patch --format='%h %s' REBASE_HEAD)

		# Check upstream correspondence (= means identical, skip it)
		if corresponding_oid=$(find_correspondence "$rebase_head_oid" "$UPSTREAM_MAP") &&
		   test "$CORRESPONDENCE_TYPE" = "="; then
			echo "::notice::Trivial skip (upstream: $corresponding_oid): $rebase_head_oneline"
			if GIT_EDITOR=: git rebase --skip; then
				break
			fi
			continue
		fi

		# Try previous/sibling correspondences (reuse their resolution via merge-tree)
		for map_file in "$PREVIOUS_MAP" "$SIBLING_MAP"; do
			test -s "$map_file" || continue
			corresponding_oid=$(find_correspondence "$rebase_head_oid" "$map_file") || continue
			echo "::notice::Found correspondence: $corresponding_oid for $rebase_head_oneline"
			if result_tree=$(git merge-tree --write-tree HEAD^ REBASE_HEAD "$corresponding_oid") &&
			   git read-tree --reset -u "$result_tree" &&
			   git commit -C REBASE_HEAD; then
				echo "::notice::Used resolution from: $corresponding_oid"
				if GIT_EDITOR=: git rebase --continue; then
					break 2
				fi
				continue 2
			fi
		done

		# Non-trivial conflict — invoke AI
		if resolve_conflict_with_ai; then
			break
		fi
	done
}

# Run copilot with standard tool permissions
# Usage: run_copilot <prompt>
# Outputs to stdout (also tees to stderr for logging)
# Runs from the automation repo root so that .github/agents/ there is used
# (not any .github/agents/ in the worktree, which is untrusted remote code).
run_copilot () {
	(cd "$SCRIPTS_DIR" &&
	  export WORKTREE_DIR &&
	  copilot -p "$1" \
		--add-dir "$WORKTREE_DIR" \
		${COPILOT_MODEL:+--model "$COPILOT_MODEL"} \
		--agent conflict-resolver \
		--allow-tool 'view' \
		--allow-tool 'write' \
		--allow-tool 'shell(awk)' \
		--allow-tool 'shell(cat)' \
		--allow-tool 'shell(git show)' \
		--allow-tool 'shell(git diff)' \
		--allow-tool 'shell(git log)' \
		--allow-tool 'shell(git range-diff)' \
		--allow-tool 'shell(git add)' \
		--allow-tool 'shell(git grep)' \
		--allow-tool 'shell(git rev-list)' \
		--allow-tool 'shell(git checkout)' \
		--allow-tool 'shell(git rm)' \
		--allow-tool 'shell(grep)' \
		--allow-tool 'shell(head)' \
		--allow-tool 'shell(ls)' \
		--allow-tool 'shell(sed)' \
		--allow-tool 'shell(tail)' \
		2>&1
	  echo $? >"$WORKTREE_DIR/copilot.exitcode") | tee /dev/stderr
	return $(cat "$WORKTREE_DIR/copilot.exitcode")
}

# Resolve a single conflict with AI
# Usage: resolve_conflict_with_ai
resolve_conflict_with_ai () {
	conflicting_files=$(git diff --name-only --diff-filter=U)
	echo "Conflict detected in: $conflicting_files"

	prompt="Resolve merge conflict during rebase of commit REBASE_HEAD.

IMPORTANT:
- The target repository/worktree is: $WORKTREE_DIR
- You are launched from a different directory only to load the custom agent.
- For each shell command, start with: cd \"$WORKTREE_DIR\" &&
- Read and edit files only inside: $WORKTREE_DIR

Conflicting files: $conflicting_files

Investigation commands:
- See the patch: cd \"$WORKTREE_DIR\" && git show REBASE_HEAD
- See conflict markers: view \"$WORKTREE_DIR/<file>\"
- Check if upstreamed: cd \"$WORKTREE_DIR\" && git range-diff REBASE_HEAD^! REBASE_HEAD..

Decision rules:
1. If range-diff shows correspondence (e.g. '1: abc = 1: def'), output: skip <upstream-oid>
2. If patch needs surgical resolution, edit files, stage with 'cd \"$WORKTREE_DIR\" && git add', output: continue
3. If unresolvable, output: fail

Your FINAL line must be exactly: skip <oid>, continue, or fail"

	echo "Invoking AI for conflict resolution..."
	ai_output=$(run_copilot "$prompt")
	ai_exit_code=$?

	# Log the AI output in a collapsible group
	echo "::group::AI Output for $rebase_head_oneline"
	echo "$ai_output"
	if test $ai_exit_code -ne 0; then
		echo "::warning::Copilot exited with code $ai_exit_code"
	fi
	echo "::endgroup::"

	# Extract the decision from the last meaningful line
	decision=$(echo "$ai_output" | sed -n '/^continue$/p; /^skip [0-9a-f]/p; /^skip$/p; /^fail$/p' | tail -1)
	decision_verb=$(echo "$decision" | awk '{print $1}')

	case "$decision_verb" in
	skip)
		upstream_oid=$(echo "$decision" | awk '{print $2}')
		if test -n "$upstream_oid"; then
			echo "::notice::Skipping commit (upstream: $upstream_oid): $rebase_head_oneline"
		else
			echo "::notice::Skipping commit (obsolete): $rebase_head_oneline"
		fi
		if GIT_EDITOR=: git rebase --skip; then
			return 0
		fi
		return 1
		;;
	continue)
		echo "::notice::Resolved conflict surgically: $rebase_head_oneline"
		if GIT_EDITOR=: git rebase --continue; then
			return 0
		fi
		return 1
		;;
	fail)
		echo "::error::AI could not resolve conflict: $rebase_head_oneline"
		exit 2
		;;
	*)
		echo "::error::Unexpected AI decision '$decision_verb': $rebase_head_oneline"
		exit 2
		;;
	esac
}

# Parse arguments
test $# -ge 2 || usage
SHEARS_BRANCH=$1
UPSTREAM_BRANCH=$2
SCRIPTS_DIR=${3:-$(cd "$(dirname "$0")" && pwd)}

# Validate environment
command -v copilot >/dev/null 2>&1 || die "copilot CLI not found in PATH"
test -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ||
	die "GH_TOKEN or GITHUB_TOKEN must be set"

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

PREVIOUS_MAP=""

if test "$BEHIND_COUNT" -gt 0; then
	if git rev-list --grep='^Start the merging-rebase' "$TIP_OID..$GFW_MAIN_BRANCH" | grep -q .; then
		# origin/main was rebased — generate correspondence before adopting
		PREVIOUS_MAP="$WORKTREE_DIR/previous-correspondence.map"
		MAIN_MARKER=$(git rev-parse "$GFW_MAIN_BRANCH^{/Start.the.merging-rebase}")
		generate_correspondence_map "$MAIN_MARKER..$GFW_MAIN_BRANCH" "$OLD_MARKER..$TIP_OID" "$PREVIOUS_MAP"

		echo "::notice::origin/main was rebased, adopting its $BEHIND_COUNT commits"
		git checkout -B "$SHEARS_BRANCH" "$GFW_MAIN_BRANCH" ||
			die "Could not adopt $GFW_MAIN_BRANCH"
		TIP_OID=$(git rev-parse HEAD)
		OLD_MARKER=$(git rev-parse "HEAD^{/Start.the.merging-rebase}")
		OLD_UPSTREAM=$(git rev-parse "$OLD_MARKER^1")
	else
		echo "::notice::Syncing $BEHIND_COUNT commits from $GFW_MAIN_BRANCH"
		echo "::group::Rebasing $BEHIND_COUNT commits from $GFW_MAIN_BRANCH on top of $SHEARS_BRANCH"
		run_rebase -r HEAD "$GFW_MAIN_BRANCH"
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
	cat >"$REPORT_FILE" <<-UPTODATE_EOF
	## Rebase Summary: ${SHEARS_BRANCH##*/}

	Already up to date with [Git for Windows' \`main\`](https://github.com/git-for-windows/git/compare/$(git rev-parse "$TIP_OID")...$(git rev-parse "$GFW_MAIN_BRANCH")) and with [\`${UPSTREAM_BRANCH}\`](https://github.com/git-for-windows/git/compare/$(git rev-parse "$TIP_OID")...$(git rev-parse "$NEW_UPSTREAM")).

	UPTODATE_EOF
	cat "$REPORT_FILE"
	if test -n "$GITHUB_STEP_SUMMARY"; then
		cat "$REPORT_FILE" >>"$GITHUB_STEP_SUMMARY"
	fi
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

# Generate upstream correspondence map (our commits vs upstream, for trivial skips)
UPSTREAM_MAP="$WORKTREE_DIR/upstream-correspondence.map"
generate_correspondence_map "$OLD_MARKER..$TIP_OID" "$OLD_UPSTREAM..$NEW_UPSTREAM" "$UPSTREAM_MAP"

# Generate sibling correspondence map (seen→next→main→maint hierarchy)
# When rebasing main, the next branch may already have resolved the same conflicts;
# when rebasing next, the seen branch is the sibling.
SIBLING_MAP=""
case "${SHEARS_BRANCH##*/}" in
maint) SIBLING_BRANCH="origin/shears/main" ;;
main) SIBLING_BRANCH="origin/shears/next" ;;
next) SIBLING_BRANCH="origin/shears/seen" ;;
*)    SIBLING_BRANCH="" ;;
esac
if test -n "$SIBLING_BRANCH" && git rev-parse --verify "$SIBLING_BRANCH" >/dev/null 2>&1; then
	SIBLING_MARKER=$(git rev-parse "$SIBLING_BRANCH^{/Start.the.merging-rebase}" 2>/dev/null) || SIBLING_MARKER=""
	if test -n "$SIBLING_MARKER"; then
		SIBLING_MAP="$WORKTREE_DIR/sibling-correspondence.map"
		generate_correspondence_map "$OLD_MARKER..$TIP_OID" "$SIBLING_MARKER..$SIBLING_BRANCH" "$SIBLING_MAP"
	fi
fi

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

run_rebase -r --onto "$MARKER_OID" "$OLD_MARKER"
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
