---
name: verify-change
description: Build and check a change to the Apple Cohesion client (this repo) or to CohesionWebKit before calling it done. Use after any edit to Swift code, the Xcode project, Info.plist, assets or CohesionWebKit, and before committing or reporting.
---

# Verify a change

There are no tests and no linter in this repo. The checks are that the app builds
for both of its platforms without new warnings. Say exactly that in the report
("built for iPad Simulator and Mac"). Don't call it "tested".

## The checks

From the repo root:

```sh
xcodebuild -project mac/cohesion-apple.xcodeproj -scheme Cohesion -destination 'generic/platform=iOS Simulator' build -quiet > /tmp/cohesion-ios.log 2>&1; echo "iOS exit $?"
xcodebuild -project mac/cohesion-apple.xcodeproj -scheme Cohesion -destination 'platform=macOS' build -quiet > /tmp/cohesion-mac.log 2>&1; echo "Mac exit $?"
grep -E "error:|warning:" /tmp/cohesion-ios.log /tmp/cohesion-mac.log | sort -u
```

- Both must exit 0. Each takes about a minute when cold and seconds when warm.
- The project sets no development team, so the Mac build signs to run
  locally. To sign with a team, add `DEVELOPMENT_TEAM=<team ID>` to the
  command rather than setting it in the project. Don't add
  `CODE_SIGNING_ALLOWED=NO` unless signing itself fails, and say so in the
  report if you did.
- `-quiet` prints only warnings and errors. The scheme list also shows
  `CohesionWebKit` (the local package), which you don't need to build
  separately for the app.
- The line `IDERunDestination: Supported platforms … is empty` is noise and
  doesn't mean the build failed.

If you changed CohesionWebKit (`../CohesionWebKit`), also run:

```sh
(cd ../CohesionWebKit && swift build)
```

and still run both app builds, because the app is what uses the package's
public API.

## Failures that aren't yours

The maintainer often has uncommitted work in progress in this repo and in
CohesionWebKit, and the app builds against whatever is in the package
checkout. If a build fails:

1. Check whether the errors are in files you touched (`git status`,
   `git diff --stat` in both repos).
2. Errors only in files you didn't touch are pre-existing. Don't fix, revert
   or stash someone else's work to get a green build. Report the failure
   with the first error line and the file, and say your change couldn't be
   verified past it.
3. Fix errors in your own files before reporting. A change that doesn't build
   isn't done.

## Beyond building

To see the change running, use the `run-the-app` skill. Most visual checks past
the pairing screen need a paired daemon, so list them under "what to check by
hand" instead.
