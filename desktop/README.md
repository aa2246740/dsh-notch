# Desktop helper ownership

`notch-lifecycle.mjs` is a small Node/Electron integration for desktop shells that launch the native helper. It owns both a helper it spawns and an existing helper adopted from a PID file. It verifies the executable and process start time, retries if the adopted helper exits during startup, and closes the owned helper on application quit.

```js
import { superviseNotch } from './notch-lifecycle.mjs'

let notch
app.on('before-quit', () => notch?.stop())
// After the authenticated Host has finished starting:
notch = superviseNotch({ bin: absoluteHelperPath, pidPath: helperPIDPath, log })
```

Register quit cleanup before awaiting Host startup. If the app quits while startup is pending, cancel/terminate its own starting Host and do not start Notch afterwards. Do not terminate an unrelated Host to manage Notch.

An external native updater should create `${pidPath}.updating` before stopping the old helper, replace the binary/resources, start and verify the new helper, publish its PID, then remove the marker in a `finally` block. The marker expires after 60 seconds if an updater crashes. This prevents the shell's recovery from racing the updater.

The native helper also watches its Host independently. Actual process exit closes it without a deliberate grace delay; HTTP timeouts do not. A process that has already committed to exiting is replaced by the desktop supervisor rather than treated as a usable helper forever.

Validation:

```sh
npm test
swift build --package-path macos -c release
python3 macos/Tests/helper-lifetime.py
node desktop/restart-probe.mjs
```

The native probes use disposable local owner processes and isolated runtime files. They never start DSH or invoke a model.
