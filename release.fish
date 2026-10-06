#!/usr/bin/env fish
#
# usage:
#   ./release.fish                 release HEAD as a stable version (tags vN+1 if untagged)
#   ./release.fish hotfix <desc>   current stable + qualifier, eg v0-desc.1a2b3c4d
#   ./release.fish beta <desc>     next stable + qualifier,    eg v1-desc.1a2b3c4d
#
# stable versions are tags matching ^v[0-9]+$. hotfix/beta builds are not tagged.

set -l name crispy-chainsaw
set -l outdir (path resolve (status dirname)/releases/)

function die
    echo "release: $argv" >&2
    exit 1
end

function stable_tags
    # all stable tags, highest first; extra args are passed to `git tag`
    git tag -l $argv | string match -r '^v[0-9]+$' | sort -t v -k 2 -n -r
end

cd (status dirname); or die "cannot cd to repo"

# --- preflight -------------------------------------------------------------

git rev-parse --git-dir >/dev/null 2>&1; or die "not a git repository"
git update-index -q --refresh
git diff-index --quiet HEAD --; or die "working tree has uncommitted changes"

# --- work out the version --------------------------------------------------

set -l mode release
if set -q argv[1]
    set mode $argv[1]
end

set -l desc
switch $mode
    case hotfix beta
        set -q argv[2]; or die "$mode needs a description"
        set desc $argv[2]
        string match -qr '^[A-Za-z0-9-]+$' -- $desc; or die "description must match [A-Za-z0-9-]+"
    case release
    case '*'
        die "unknown mode '$mode' (expected: hotfix, beta, or nothing)"
end

set -l hash (git rev-parse --short=8 HEAD)
# "current" is the nearest stable tag in HEAD's history; "next" is one past the
# highest stable tag anywhere, so a new tag can never collide with an old one.
set -l current (stable_tags --merged HEAD)[1]
set -l latest (stable_tags)[1]
set -l next v0
if test -n "$latest"
    set next v(math (string sub -s 2 -- $latest) + 1)
end

set -l ver
switch $mode
    case release
        set -l here (stable_tags --points-at HEAD)[1]
        if test -n "$here"
            set ver $here
        else
            set ver $next
            git tag -a $ver -m $ver; or die "failed to create tag $ver"
            echo "tagged $hash as $ver (push with: git push origin $ver)"
        end
    case hotfix
        test -n "$current"; or die "no stable tag in HEAD's history to hotfix"
        set ver $current-$desc.$hash
    case beta
        set ver $next-$desc.$hash
end

# --- stage -----------------------------------------------------------------

set -l stage (mktemp -d); or die "mktemp failed"
function cleanup --on-event fish_exit --inherit-variable stage
    rm -rf $stage
end

set -l root $stage/$name
git archive --prefix=$name/ HEAD | tar -x -C $stage; or die "git archive failed"

# git archive leaves submodules empty; fill them in at the recorded commit
for sub in (git config -f .gitmodules --get-regexp '\.path$' | string split -f2 ' ')
    set -l sha (git rev-parse HEAD:$sub)
    git -C $sub archive --prefix=$name/$sub/ $sha | tar -x -C $stage
    or die "failed to archive submodule $sub at $sha (is it checked out?)"
end

# --- stamp -----------------------------------------------------------------

set -l lua $root/$name.lua
sed -i -E "s/^(addon\.version[[:space:]]*=[[:space:]]*)'[^']*'/\1'$ver'/" $lua
grep -q "^addon.version *= *'$ver'" $lua; or die "failed to stamp version into $name.lua"

# --- package ---------------------------------------------------------------

set -l zip $outdir/$name-$ver.zip
rm -f $zip
pushd $stage
zip -qr -X $zip $name; or die "zip failed"
popd

echo "built $zip"
