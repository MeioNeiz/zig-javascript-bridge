#!/usr/bin/env bash
# Steps of .github/workflows/upstream.yml. `compare` finds out whether upstream main moved
# past this fork's $MIRROR branch; `report` handles a move. Needs UPSTREAM, MIRROR,
# BRANCHES and GH_TOKEN from the workflow.
set -euo pipefail

out() { echo "$1" >>"$GITHUB_OUTPUT"; }
keep() { echo "$1" >>"$GITHUB_ENV"; }

compare() {
    git fetch -q --no-tags "https://github.com/$UPSTREAM.git" main
    local new old zig
    new=$(git rev-parse FETCH_HEAD)
    old=$(git rev-parse "origin/$MIRROR")
    if [ "$old" = "$new" ]; then
        echo "upstream main unchanged at $new"
        out changed=false
        return
    fi
    # Build with the Zig version our main's README names; upstream may still be on an
    # older one. The report flags a difference.
    zig=$(readme_zig origin/main)
    out changed=true
    out "zig=${zig:-latest}"
    keep "OLD=$old"
    keep "NEW=$new"
    keep "ZIG=${zig:-latest}"
}

readme_zig() {
    git show "$1:README.md" | grep -oE 'work with Zig [0-9]+\.[0-9]+\.[0-9]+' |
        head -n 1 | awk '{print $NF}'
}

builds() {
    zig build
    if zig build -l | grep -qE '^  test( |$)'; then
        zig build test
    fi
    (cd example && zig build)
    (cd simple && zig build)
}

report() {
    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
    local url="https://github.com/$UPSTREAM"
    local body=report.md
    local base note range
    base=$(git merge-base "origin/main" "$NEW")

    local ff=false
    if git merge-base --is-ancestor "$OLD" "$NEW"; then
        ff=true
        note="Fast-forwarded \`$MIRROR\` to it."
        range="$OLD..$NEW"
    else
        note="Upstream rewrote history (not a fast-forward), so \`$MIRROR\` was left at"
        note="$note $OLD; move it by hand."
        range="$(git merge-base "$OLD" "$NEW")..$NEW"
    fi

    {
        echo -n "@$GITHUB_REPOSITORY_OWNER upstream main moved to"
        echo " [${NEW:0:7}]($url/commit/$NEW)."
        echo "$note"
        echo
        echo "New commits:"
        echo
        git log --reverse --date=short \
            --format="- [%h]($url/commit/%H) %s (%an, %ad)" "$range"
        echo
    } >"$body"

    local ours theirs both
    ours=$(git diff --name-only "$base" origin/main -- . ':(exclude).github' | sort)
    theirs=$(git diff --name-only "$base" "$NEW" | sort)
    both=$(comm -12 <(echo "$ours") <(echo "$theirs") | sed '/^$/d')
    if [ -n "$both" ]; then
        {
            echo "Upstream changed files that our \`main\` commits also change"
            echo "(did upstream do our fix? then drop our commit):"
            echo
            # shellcheck disable=SC2016 # backticks are markdown
            echo "$both" | sed 's/^/- `/; s/$/`/'
            echo
        } >>"$body"
    else
        echo "Upstream changed none of the files our \`main\` commits change." >>"$body"
        echo >>"$body"
    fi

    local theirs_zig
    theirs_zig=$(readme_zig "$NEW")
    if [ "$theirs_zig" != "$ZIG" ]; then
        echo "Upstream's README names Zig ${theirs_zig:-none}; ours names $ZIG." >>"$body"
        echo >>"$body"
    fi
    echo "Rebase onto it and build with Zig $ZIG (nothing pushed):" >>"$body"
    echo >>"$body"
    local b log dropped conflicts
    for b in $BRANCHES; do
        if ! git rev-parse -q --verify "origin/$b" >/dev/null; then
            continue
        fi
        git checkout -q --detach "origin/$b"
        log="build-$b.log"
        if ! git rebase -q "$NEW" >"$log" 2>&1; then
            conflicts=$(git diff --name-only --diff-filter=U | tr '\n' ' ')
            git rebase --abort
            echo "- \`$b\`: rebase conflicts in $conflicts" >>"$body"
            continue
        fi
        dropped=$(comm -23 \
            <(git log --format=%s "$NEW..origin/$b" | sort) \
            <(git log --format=%s "$NEW..HEAD" | sort) |
            sed 's/^/"/; s/$/"/' | paste -sd, -)
        if builds >"$log" 2>&1; then
            echo "- \`$b\`: rebases cleanly and builds" >>"$body"
        else
            {
                echo "- \`$b\`: rebases cleanly but does not build"
                echo
                echo "  <details><summary>build output (last 40 lines)</summary>"
                echo
                echo '  ```'
                tail -n 40 "$log" | sed 's/^/  /'
                echo '  ```'
                echo
                echo "  </details>"
            } >>"$body"
        fi
        if [ -n "$dropped" ]; then
            echo "  (rebase dropped as already upstream: $dropped)" >>"$body"
        fi
    done
    {
        echo
        echo "Run: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
    } >>"$body"

    gh label create upstream --color 1d76db \
        --description "Upstream zjb moved" 2>/dev/null || true
    local issue
    issue=$(gh issue list --label upstream --state open --json number -q '.[0].number')
    if [ -n "$issue" ]; then
        gh issue comment "$issue" --body-file "$body"
    else
        gh issue create --label upstream --title "Upstream zjb has new commits" \
            --body-file "$body"
    fi
    # Last, so a failed run reports the same commits again next time.
    if [ "$ff" = true ]; then
        git push -q origin "$NEW:refs/heads/$MIRROR"
    fi
}

"$@"
