---
name: finish-task
description: Finish a task in the Apple Cohesion client: run the checks, update docs, commit only your own files in a checkout that may hold the maintainer's uncommitted work, push to master, and write the final report. Use when the code change is done and before you report back.
---

# Finish a task

## 1. Check

Run `verify-change`. A change that doesn't build isn't done. A pre-existing
failure in someone else's files gets reported, not fixed.

## 2. Docs

Update what your change made wrong, in the same commit: `mac/ARCHITECTURE.md`,
`CLAUDE.md`, `README.md`, these skills, and for a change to the page's
side, `docs/serving-the-webui.md` in cohesion.

## 3. Commit only your own work

The checkout is often dirty with the maintainer's work, here.
Run `git status` before you start and again now.

- Never revert, stash, reset, checkout or commit changes you didn't make.
- Stage by path: `git add <your files>`. Never `git add -A`, `.` or `-a`.
- If you had to edit a file that was already dirty (often `project.pbxproj`
  or `CohesionApp.swift`), stage only your hunks without interactive
  staging:
  ```sh
  git diff <file> > /tmp/all.patch      # edit down to your hunks
  git apply --cached /tmp/all.patch
  git diff --cached <file>              # confirm only yours is staged
  ```
  If your hunks can't be separated cleanly, leave that file uncommitted and
  say so in the report.
- Check `git diff --cached --stat` before committing.

Write commit messages in the repo's conventional style: `feat:`, `fix:`,
`refactor:`, `docs:` or `chore:` and a lowercase summary of what changed
("feat: hide the Mac title bar and add Cohesion > Unpair"), with a body if the
why isn't obvious. Make one commit per coherent change.

## 4. Push

```sh
git push origin master
```

If the push is
rejected because the remote moved, `git pull --rebase origin master` and push
again. Never force-push. Don't archive, upload to TestFlight or otherwise deploy
unless told.

## 5. Report

Use the format in `CLAUDE.md` and keep it brief. Include the commit hashes
(`git log --oneline -n <k>`), the exact checks and their results, every choice
you made without asking, and what the maintainer should check by eye (usually
anything past the pairing screen, and both platforms for layout changes).
