# Task List: app-foundation

## Task 1: Initialize the repository and record approved artifacts

**Description:** Initialize `FennecCast/` as an independent Git repository and create the first documentation save point containing the approved capability map, module spec, plan and task list.

**Acceptance criteria:**
- [x] Git repository is initialized with `main` as the initial branch.
- [x] Approved planning artifacts are tracked without modifying `../AntennaPod/`.
- [x] Commit message is `docs: define FennecCast foundation scope`.

**Verification:**
- [x] `git status -sb` identifies the `main` branch.
- [x] `git show --stat --oneline HEAD` contains only approved planning artifacts.
- [x] `git diff --check` reports no whitespace errors.

**Dependencies:** None

**Files likely touched:**
- `CAPABILITY_MAP.md`
- `SPEC-app-foundation.md`
- `tasks/plan.md`
- `tasks/todo.md`

**Estimated scope:** Medium: 4 files

## Task 2: Add repository safeguards and licensing

**Description:** Add the GPL-3.0 license, AntennaPod attribution, developer README and ignore rules required for a clean personal iOS repository.

**Acceptance criteria:**
- [x] GPL-3.0 license text and AntennaPod GPL reference are present.
- [x] README documents prerequisites and the exact foundation build commands.
- [x] DerivedData, build output, user Xcode state and signing material are ignored.

**Verification:**
- [x] `rg -n 'GNU GENERAL PUBLIC LICENSE|AntennaPod|xcodebuild' LICENSE THIRD_PARTY_NOTICES.md README.md` finds each required element.
- [x] `git check-ignore` confirms representative generated and signing files are ignored.
- [x] `git diff --cached --check` reports no whitespace errors before commit.

**Dependencies:** Task 1

**Files likely touched:**
- `.gitignore`
- `LICENSE`
- `THIRD_PARTY_NOTICES.md`
- `README.md`

**Estimated scope:** Medium: 4 files

## Checkpoint: Repository foundation

- [x] Tasks 1-2 are committed separately.
- [x] Working tree contains no unrelated files staged by FennecCast work.
- [x] Android repository status is unchanged from the initial inventory.

## Task 3: Add the minimal SwiftUI app target

**Description:** Add a checked-in Xcode project, shared scheme and the smallest complete SwiftUI launch path using an explicitly injected `AppEnvironment`.

**Acceptance criteria:**
- [x] `FennecCast.xcodeproj` defines an iOS 17 App target using Swift 6 and Bundle Identifier `com.ron159.FennecCast`.
- [x] Shared `FennecCast` scheme builds the App target.
- [x] `FennecCastApp` creates `AppEnvironment` and injects it into `RootView`.

**Verification:**
- [x] Generic iOS Simulator build succeeds with signing disabled using the spec command.
- [x] `xcodebuild -list -project FennecCast.xcodeproj` reports target and scheme `FennecCast`.
- [x] `swift-format lint --strict --recursive Sources` succeeds.

**Dependencies:** Task 2

**Files likely touched:**
- `FennecCast.xcodeproj/project.pbxproj`
- `FennecCast.xcodeproj/xcshareddata/xcschemes/FennecCast.xcscheme`
- `Sources/App/FennecCastApp.swift`
- `Sources/App/AppEnvironment.swift`
- `Sources/App/RootView.swift`

**Estimated scope:** Medium: 5 files

## Task 4: Add localized foundation resources

**Description:** Replace provisional root text with String Catalog values in English and Simplified Chinese, and add the minimal asset catalog expected by an iOS app.

**Acceptance criteria:**
- [x] Root screen has localized title and foundation status text.
- [x] English and `zh-Hans` translations exist for each user-visible string.
- [x] Asset catalog provides a named accent color without adding placeholder artwork.

**Verification:**
- [x] Generic iOS Simulator build succeeds.
- [x] A static catalog check confirms every foundation key has English and `zh-Hans` values.
- [x] `swift-format lint --strict --recursive Sources` succeeds.

**Dependencies:** Task 3

**Files likely touched:**
- `FennecCast.xcodeproj/project.pbxproj`
- `Sources/App/RootView.swift`
- `Sources/Resources/Localizable.xcstrings`
- `Sources/Resources/Assets.xcassets/Contents.json`
- `Sources/Resources/Assets.xcassets/AccentColor.colorset/Contents.json`

**Estimated scope:** Medium: 5 files

## Checkpoint: Runnable app

- [x] Tasks 3-4 are committed separately.
- [x] App target builds without signing.
- [x] No business feature or third-party dependency was added.

## Task 5: Add the XCTest target

**Description:** Add the FennecCastTests target to the existing project and scheme, with behavior-focused tests for the default app environment and localization resources.

**Acceptance criteria:**
- [x] XCTest target links against the App target through `@testable import FennecCast`.
- [x] Tests verify the default app name and the presence of both supported localizations.
- [x] Shared scheme includes the XCTest target in its Test action.

**Verification:**
- [x] Generic iOS Simulator `build-for-testing` succeeds with signing disabled.
- [x] `xcodebuild -list -project FennecCast.xcodeproj` reports `FennecCastTests`.
- [x] `swift-format lint --strict --recursive Sources Tests` succeeds.

**Dependencies:** Task 4

**Files likely touched:**
- `FennecCast.xcodeproj/project.pbxproj`
- `FennecCast.xcodeproj/xcshareddata/xcschemes/FennecCast.xcscheme`
- `Tests/AppFoundationTests.swift`

**Estimated scope:** Medium: 3 files

## Task 6: Verify and close app-foundation

**Description:** Run every currently executable spec gate, audit the resulting files and Git history, and update task evidence without broadening scope.

**Acceptance criteria:**
- [x] All executable success criteria in `SPEC-app-foundation.md` have fresh passing evidence.
- [x] Simulator runtime limitation is documented accurately and is not represented as a passing runtime test.
- [x] Working tree is clean after the final atomic commit.

**Verification:**
- [x] Generic Simulator `build` succeeds.
- [x] Generic Simulator `build-for-testing` succeeds.
- [x] Full Swift format lint succeeds.
- [x] `git diff --cached --check`, focused secret scan and `git status -sb` are clean.

**Dependencies:** Task 5

**Files likely touched:**
- `tasks/todo.md`

**Estimated scope:** Small: 1 file

## Checkpoint: app-foundation complete

- [x] Review `SPEC-app-foundation.md` success criteria against current evidence.
- [x] Review commit history for scope and rollback safety.
- [ ] Obtain human review before starting `core-contracts`.
