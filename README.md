# PRDEBar

Start and stop your local PRDE connection from the macOS menu bar. PRDEBar does not provision, deploy, or shut down cloud resources.

## Install and update the app

1. Download the universal ZIP from the [latest release](https://github.com/rselbach/PRDEBar/releases/latest).
2. Extract `PRDEBar.app` and move it into `/Applications` before opening it. Releases support Apple Silicon and Intel Macs running macOS 13 or later.
3. Install `hcloud` and Doormat. Log in with your usual hcloud and Doormat session in Terminal before starting a connection.

PRDEBar checks for updates automatically and downloads them in the background. Downloaded updates install when you quit. Choose **Check for Updates…** beside **Quit** to check manually or install an update now. An update restart uses the same connection cleanup as Quit, and the app starts stopped afterward.

Updates come from the latest GitHub Release. Sparkle verifies both the update feed and archive with the embedded public key before installing anything.

## Build and open the app

Use macOS 13 or later with Swift 6 command-line tools. Tests use the toolchain's Swift Testing framework and require macOS 14 or later. Install `just` and `shellcheck` to run the development tasks. Sparkle 2.10.0 is the only external package dependency.

1. Install `hcloud` and Doormat. Log in with your usual hcloud and Doormat session in Terminal before using the app.
2. Build the app.

   ```sh
   just build
   ```

3. Open `.build/PRDEBar.app`, or run `just run`.
4. Click **PRDE** in the menu bar to open PRDEBar. The label is green only while the connection is **Running** and red in all other states. The app starts stopped and has no Dock icon.

The build creates an ad-hoc signed local app with bundle ID `dev.rselbach.PRDEBar`. It does not install anything into `/Applications`.

## Connect to PRDE

1. If you already run PRDE proxy commands in Terminal, stop those commands yourself before starting PRDEBar. The app never adopts or stops an existing connection.
2. Set **Postgres port** while the app is stopped. The default is `5433`. Port `5432` stays reserved for local PostgreSQL, and `4646` belongs to Nomad. A valid port is saved when you choose **Start PRDE**.
3. Choose **Start PRDE**. The app runs these foreground commands in order, with your chosen port in the second command.

   ```sh
   hcloud prde proxy --exclude postgres
   hcloud prde connect 5433:postgres.postgres:postgres
   ```

4. Wait for **Running**. The app first checks the owned Nomad listener at `http://127.0.0.1:4646/v1/status/leader`, then checks the owned PostgreSQL listener with a PostgreSQL SSLRequest. Each step has a 45-second readiness deadline. A live PID or open TCP port alone is not enough.
5. Connect your database client to `localhost` at the selected port.
6. Choose **Stop PRDE** to close the local connection. You can also stop while startup is in progress. Change the port after the app returns to **Stopped**.

**Quit** waits for the same cleanup. If either command exits unexpectedly, PRDEBar stops the other command and reports the failure. If cleanup fails, choose **Stop PRDE** again. The app stays open rather than quitting with known owned processes still present.

PRDEBar launches hcloud directly, without a shell. It searches `PATH`, `/opt/homebrew/bin`, and `/usr/local/bin`, with standard system directories available to child commands. Each command gets a separate process group. Stop sends SIGTERM to both owned groups, waits up to two seconds, then sends SIGKILL if needed and waits up to two more seconds. Foreground hcloud, Doormat, and SSH descendants inherit those groups.

## Use service references

Open **Services** and select a service to copy its URL or database command. A message beside **Services**, such as **portal copied**, confirms the copy. The app does not open a browser or execute database commands. These references are standard hcloud-prde endpoints, not service health results, and require a running PRDE connection to use.

Database commands use public PRDE development defaults. The PostgreSQL command follows the port field immediately. If the port is invalid, the **postgres** item is disabled with a hint. Other services remain selectable. Changing the port clears PostgreSQL copy feedback when the copied command no longer matches. Start, Stop, and Quit stay outside the menu.

## Handle a connection error

Read the alert for the failed command, exit status, timeout, or occupied port. To inspect CLI diagnostics, run the displayed command in Terminal after stopping the app's connection. Refresh your hcloud and Doormat login there if needed.

The app checks Nomad port `4646` and your selected PostgreSQL port before launch. It refuses occupied ports and verifies listener ownership during readiness. Other service-port conflicts are left to hcloud to report. PRDEBar discards child stdout and stderr rather than retaining potentially sensitive CLI output or blocking on undrained pipes. Background lifecycle failures go to the macOS unified log without CLI output.

## Publish a release

1. Push the release commit to GitHub. The tagged commit must contain `.github/workflows/release.yml`.
2. Create and push a tag in `vMAJOR.MINOR.PATCH` format. For example:

   ```sh
   git tag -a v0.1.0 -m "PRDEBar 0.1.0"
   git push origin v0.1.0
   ```

3. Check the **Release** workflow in GitHub Actions. It runs `just lint` and `just test`, then builds an optimized app for both Apple Silicon and Intel Macs. It signs the app with Developer ID, notarizes it with Apple, and staples the notarization ticket before publishing.
4. Download `PRDEBar-v0.1.0-universal.zip` from the GitHub Release. The app version comes from the tag, and its build number comes from the workflow run number. A rerun replaces the release assets.

The workflow signs Sparkle's nested helpers before signing the app. After notarization and stapling, it generates a signed `appcast.xml` with Sparkle's bundled tools. It uploads the ZIP and feed before publishing the release. Installed apps read the feed at `https://github.com/rselbach/PRDEBar/releases/latest/download/appcast.xml`, so no separate update server or GitHub Pages setup is required.

The workflow requires the repository secrets `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`, `APPLE_SIGNING_IDENTITY`, `MACOS_CERTIFICATE_P12_BASE64`, `MACOS_CERTIFICATE_PASSWORD`, and `SPARKLE_EDDSA_PRIVATE_KEY`. It imports the signing certificate into a temporary keychain and removes the keychain after the run. Local builds from `just build` remain ad-hoc signed.

## Check changes

```sh
just format
just lint
just test
just build
```

The tests compile a temporary local fake hcloud with the installed C compiler. They use ephemeral ports, exercise real child processes and descendants, and remove the helper afterward. They do not invoke hcloud or use your running PRDE connection. The test wrapper loads the bundled Swift Testing macro plugin when present because Swift 6.4 command-line builds omit it from discovery.

After changing the menu UI or process lifecycle, also exercise **Start PRDE**, **Stop PRDE**, and **Quit** in the app with a logged-in hcloud session. Check Nomad and PostgreSQL through their local ports, and confirm that Stop and Quit remove the owned SSH listeners.

In **Services**, check mouse and keyboard selection, exact clipboard contents, and copy feedback. Confirm that selecting a service does not open a browser or run a command. Edit the port to a valid nondefault value and copy **postgres**. Check that the command uses that port. Change the port again and confirm that the previous copy feedback disappears. Enter an invalid port and confirm that **postgres** is disabled with a hint while other services remain selectable. Check that the panel stays compact with no scrollbar and does not change height after copying.

After changing release packaging or Sparkle integration, verify the universal binary and framework, nested code signatures, notarization, and stapled ticket. Exercise an update from an older build with a locally generated signed feed. Confirm that a modified feed or archive is rejected without replacing the app. Also check **Check for Updates…** in the menu panel. Confirm that the button is disabled while a background check downloads the feed.

On the installed Swift 6.4 command-line toolchain, the linker reports missing Xcode-only search directories and a macOS 14 minimum for the test framework. These warnings do not prevent the app build or isolated tests.
