# Build Another Window Management

Clone the project and activate its commit-message hook.

```sh
git clone https://github.com/mihaliak/awm.git
cd awm
git config --local core.hooksPath .githooks
```

## Build and run

Install Xcode 26 or later to compile the native app icon. The app runs on macOS 13 or later. For daily use, build Release and install it in your Applications folder. The install command copies the app when the destination is free. Open the installed copy on subsequent launches.

```sh
xcodebuild -project AWM.xcodeproj -scheme AWM -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build build
mkdir -p ~/Applications
test ! -e "$HOME/Applications/Another Window Management.app" && \
  ditto "build/Build/Products/Release/Another Window Management.app" "$HOME/Applications/Another Window Management.app"
open "$HOME/Applications/Another Window Management.app"
```

The menu bar icon opens the popover. Run the **AWM** scheme on **My Mac** in Xcode for development. The Debug build and hosted tests use a separate app identity.

The Xcode project is included. Run `xcodegen generate` after changing `project.yml` or adding source files.

## Verify

```sh
xcodebuild -project AWM.xcodeproj -scheme AWM \
  -destination 'platform=macOS' -derivedDataPath build test
"build/Build/Products/Debug/Another Window Management.app/Contents/MacOS/Another Window Management" \
  --verify-menu-bar
```

The hosted tests exercise first-run setup and open the popover through the menu bar icon with normal and reduced motion. They check capture and update, display associations, sizing preferences, shortcuts, keyboard focus, dismissal, and rapid reopening. The standalone menu check runs the popover interactions on their own. Both use temporary workspace data and simulate the handoff to System Settings and Finder. Set `AWM_VERIFY_REDUCE_MOTION=1` to run the standalone check with reduced motion.

To print the installed copy’s window-control permission and exit, run `"$HOME/Applications/Another Window Management.app/Contents/MacOS/Another Window Management" --accessibility-status`.

## Refresh the README badges

Run the complete test suite with coverage and use the result bundle to regenerate the badges. Sign in to `gh` with access to the repository so it can read the latest stable release.

```sh
mkdir -p build
coverage_run=$(mktemp -d "$PWD/build/coverage.XXXXXX")
xcodebuild -project AWM.xcodeproj -scheme AWM -destination 'platform=macOS' \
  -derivedDataPath build -enableCodeCoverage YES \
  -resultBundlePath "$coverage_run/Tests.xcresult" test && \
  python3 docs/update-badges.py "$coverage_run/Tests.xcresult"
```

The coverage badge uses the `xccov` report for the `AWM` app sources, including Debug verification code. The release badge refreshes through GitHub Actions when releases change. Both badges are checked into the repository so they render on a private repository without an external service.

## Build the website

Use Node.js 24, the version used by GitHub Actions. From the repository root, run the following commands. The preview is available at `http://localhost:4173/`.

```sh
cd website
npm test
npm run build
npm run preview
```
