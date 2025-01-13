#!/bin/bash

cd "`dirname "$0"`"

rm -f cherry-pick-skip.sh cherry-pick-show.sh

REBASE_HEAD_COMMIT="f9f1712128832b04d5a340c0667c6d68e421b57f"

function already_applied_commits {
    git log --grep='(cherry picked from commit' ${REBASE_HEAD_COMMIT}.. | grep '(cherry picked from commit' | awk '{print $5}' | tr -d ")"
}

commit_id="`grep -v -f<(already_applied_commits) commits_to_apply | grep -v '^#' | head -1`"

echo "Apply the following commit:"
echo
echo "  ${commit_id}"
echo
echo "========================================================================"
git log -1 "$commit_id"
echo "========================================================================"

git cherry-pick -X ignore-all-space -x "$commit_id"

if [ "$?" = "0" ]; then
    echo "HOLY CRAP IT WORKED"
else
    echo "git show ${commit_id}" > cherry-pick-show.sh
    chmod a+x cherry-pick-show.sh

    echo
    echo "To show it:"
    echo
    echo "./cherry-pick-show.sh"

    echo
    echo "To skip it:"

    echo "git cherry-pick --abort; cat commits_to_apply | sed 's/^${commit_id}/#${commit_id}/' > commits_to_apply.tmp && mv commits_to_apply.tmp commits_to_apply" > cherry-pick--skip.sh
    chmod a+x cherry-pick--skip.sh

    echo
    echo "./cherry-pick--skip.sh"
    echo
fi
