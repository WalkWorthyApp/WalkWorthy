# Reminder preference boundary tests

From the repository root, run:

```sh
bash tests/reminder-preferences/run.sh
```

Use a per-process `DEVELOPER_DIR` if the selected developer tools do not include
Swift Testing. The runner also requires Python 3. Pass another checkout's root
as its first argument to run the same assertions against a baseline.

The temporary Swift package compiles the production cleanup helper and extracts
the actual AppState sign-out/account-transition and Settings-loading methods.
Only access modifiers change. Firebase auth, notification scheduling, and cache
collaborators are inert stand-ins; SwiftUI rendering is not exercised. These are
focused defaults-boundary tests, supplemented by an unsigned iOS app build.
Each case owns a unique UserDefaults suite and removes it afterward. The runner
removes its temporary package, build outputs, and caches on exit.
