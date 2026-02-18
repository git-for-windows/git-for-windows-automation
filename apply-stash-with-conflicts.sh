#!/bin/sh
#
# Like `git stash apply`, but for stashes that contain merge conflicts
# (created by stash-with-conflicts.sh). `git stash` itself cannot
# handle unmerged index entries, so this script reconstructs the full
# conflict state from the octopus merge commit.
#
# Expects a commit with exactly 4 parents:
#   Parent 1: HEAD at time of stash
#   Parent 2: stage 1 tree (common ancestor)
#   Parent 3: stage 2 tree (ours)
#   Parent 4: stage 3 tree (theirs)
#   Tree:     worktree state (with conflict markers)
#
# Usage: apply-stash-with-conflicts.sh <commit> [<dir>]
# Reconstructs the unmerged index and restores the worktree with
# conflict markers, without moving HEAD (just like `git stash apply`).

die () { echo "fatal: $*" >&2; exit 1; }

commit=${1:?usage: apply-stash-with-conflicts.sh <commit> [<dir>]}
dir=${2:-.}

# Like `git stash apply`: refuse to apply on a dirty state
git -C "$dir" update-index -q --refresh ||
	die "unable to refresh index"
git -C "$dir" write-tree >/dev/null ||
	die "cannot apply a stash in the middle of a merge"

parents=$(git -C "$dir" cat-file -p "$commit" | grep '^parent ' | awk '{print $2}') ||
	die "cannot read commit '$commit'"
count=$(echo "$parents" | wc -l)
test "$count" -eq 4 ||
	die "expected 4 parents, got $count"

b_commit=$(echo "$parents" | sed -n '1p')
stage1_commit=$(echo "$parents" | sed -n '2p')
stage2_commit=$(echo "$parents" | sed -n '3p')
stage3_commit=$(echo "$parents" | sed -n '4p')

b_tree=$(git -C "$dir" rev-parse "${b_commit}^{tree}") ||
	die "cannot resolve base tree"
stage1_tree=$(git -C "$dir" rev-parse "${stage1_commit}^{tree}") ||
	die "cannot resolve stage 1 tree"
stage2_tree=$(git -C "$dir" rev-parse "${stage2_commit}^{tree}") ||
	die "cannot resolve stage 2 tree"
stage3_tree=$(git -C "$dir" rev-parse "${stage3_commit}^{tree}") ||
	die "cannot resolve stage 3 tree"
worktree_tree=$(git -C "$dir" rev-parse "${commit}^{tree}") ||
	die "cannot resolve worktree tree"

c_tree=$(git -C "$dir" write-tree) ||
	die "cannot determine current index state"

# If HEAD has moved since the stash was created, refuse: the conflict
# state is tied to a specific base and cannot be rebased automatically
test "$c_tree" = "$b_tree" ||
	die "HEAD tree differs from stash base; cannot apply"

# Find conflicted paths by comparing the three stage trees
conflicted=$(
	{
		git -C "$dir" diff-tree -r --name-only \
			"$stage1_tree" "$stage2_tree"
		git -C "$dir" diff-tree -r --name-only \
			"$stage1_tree" "$stage3_tree"
		git -C "$dir" diff-tree -r --name-only \
			"$stage2_tree" "$stage3_tree"
	} | sort -u
)

# Load the stage-2 tree (ours) as the starting index, like
# merge-recursive would leave it for the non-conflicted files
git -C "$dir" read-tree "$stage2_tree" ||
	die "failed to read stage 2 tree into index"

if test -n "$conflicted"; then
	# Replace stage-0 entries for conflicted paths with proper
	# stage 1/2/3 entries
	{
		echo "$conflicted" | while read -r path; do
			echo "0 0000000000000000000000000000000000000000 0	$path"
			for stage in 1 2 3; do
				eval "tree=\$stage${stage}_tree"
				entry=$(git -C "$dir" ls-tree "$tree" -- "$path")
				test -n "$entry" || continue
				mode=$(echo "$entry" | awk '{print $1}')
				oid=$(echo "$entry" | awk '{print $3}')
				echo "$mode $oid $stage	$path"
			done
		done
	} | git -C "$dir" update-index --index-info ||
		die "failed to reconstruct unmerged index entries"
fi

# Restore the worktree: resolved files from the index, then overlay
# conflicted files with their worktree state (conflict markers)
git -C "$dir" checkout-index -a -f ||
	die "failed to restore worktree"
echo "$conflicted" | while read -r path; do
	test -n "$path" || continue
	oid=$(git -C "$dir" ls-tree "$worktree_tree" -- "$path" | awk '{print $3}')
	test -n "$oid" || continue
	git -C "$dir" cat-file -p "$oid" >"$dir/$path"
done
