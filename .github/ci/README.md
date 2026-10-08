# CI tooling

Firebase CLI dependencies are isolated from the deployed Functions package.
The backend checks and deploy workflows install this lockfile with `npm ci --ignore-scripts`
and invokes `node_modules/.bin/firebase` directly. A missing installation fails
instead of downloading a replacement through `npx` or using a global CLI.

To deliberately update Firebase CLI, run from this directory:

```sh
npm install --package-lock-only --ignore-scripts --save-dev --save-exact firebase-tools@<version>
npm ci --ignore-scripts --no-audit --no-fund
node_modules/.bin/firebase --version
```

Review both package files together and run the existing Firestore emulator
`test:ci` suite before accepting an update. Keep changes to the Functions
dependency lockfile separate.

All workflows pin actions by full upstream commit SHA, with release
comments for maintenance. Verify both the release and its resolved commit when
updating a pin; annotated tag objects are not commit SHAs.

The review workflow fetches the plugin repository at `PLUGIN_COMMIT`, verifies
the checked-out commit, and passes `plugins/code-review` to Claude's documented
`--plugin-dir` option. It does not install from the moving marketplace. Review
the plugin contents and validate its manifest when updating this commit.

These pins do not freeze the hosted runner, Node/Java release selection, or all
downloads performed inside third-party actions. In particular, the pinned
Claude action still downloads its installer and runtime dependencies. Firebase
also downloads the emulator binary separately from this npm lockfile.
