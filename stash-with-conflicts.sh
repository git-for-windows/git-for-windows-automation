#!/bin/sh
#
# Create a stash-like commit that preserves the full conflict state of
# a working directory, including unmerged index entries that `git stash`
# cannot handle.
#
# The result is a fake octopus merge with exactly 4 parents and the
# worktree state (conflict markers and all) as its tree:
#
#   Parent 1: HEAD
#   Parent 2: stage 1 tree (common ancestor)
#   Parent 3: stage 2 tree (ours)
#   Parent 4: stage 3 tree (theirs)
#
# Each stage tree contains all resolved (stage 0) files plus the
# conflicted files replaced by their stage-N blob. When a stage has
# no entry for a conflicted path (e.g. delete/modify), that path is
# simply absent from the tree.
#
# Usage: stash-with-conflicts.sh [<dir>]
# Prints the commit hash on stdout.

die () { echo "fatal: $*" >&2; exit 1; }

dir=${1:-.}

p=$(git -C "$dir" rev-parse --git-path index) ||
	die "cannot find index for '$dir'"
case "$p" in /*) ;; *) p="$(cd "$dir" && pwd)/$p" ;; esac

# Capture unmerged entries before any index modification
unmerged=$(git -C "$dir" ls-files -u)

# Worktree tree: copy index to temp, stage everything, write-tree
cp "$p" "$p.worktree" &&
GIT_INDEX_FILE="$p.worktree" git -C "$dir" add -A &&
worktree_tree=$(GIT_INDEX_FILE="$p.worktree" git -C "$dir" write-tree) ||
	die "failed to write worktree tree"

parents="-p HEAD"
for stage in 1 2 3; do
	# Start from a copy of the real index, then remove conflicted
	# entries and re-add them promoted to stage 0
	cp "$p" "$p.stage$stage" ||
		die "failed to copy index for stage $stage"
	{
		echo "$unmerged" | awk '
			{ p = $0; sub(/^[^\t]*\t/, "", p) }
			!seen[p]++ { print "0 0000000000000000000000000000000000000000 0\t" p }
		'
		echo "$unmerged" |
			awk -v s="$stage" '$3 == s { sub(/ [0-9]+\t/, " 0\t"); print }'
	} | GIT_INDEX_FILE="$p.stage$stage" \
		git -C "$dir" update-index --index-info ||
		die "failed to build stage $stage index"
	stage_tree=$(GIT_INDEX_FILE="$p.stage$stage" \
		git -C "$dir" write-tree) ||
		die "failed to write stage $stage tree"
	stage_commit=$(git -C "$dir" commit-tree "$stage_tree" \
		-p HEAD -m "index stage $stage") ||
		die "failed to create stage $stage commit"
	parents="$parents -p $stage_commit"
done

git -C "$dir" commit-tree "$worktree_tree" \
	$parents -m "Failed rebase state" ||
	die "failed to create stash commit"

# Reset the worktree and index to HEAD, like `git stash` would
git -C "$dir" reset --hard >&2
