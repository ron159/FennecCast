# Task List: app-foundation

## Task 1: Initialize the repository and record approved artifacts

**Description:** Initialize `FennecCast/` as an independent Git repository and create the first documentation save point containing the approved capability map, module spec, plan and task list.

**Acceptance criteria:**
- [ ] Git repository is initialized with `main` as the initial branch.
- [ ] Approved planning artifacts are tracked without modifying `../AntennaPod/`.
- [ ] Commit message is `docs: define FennecCast foundation scope`.

**Verification:**
- [ ] `git status -sb` identifies the `main` branch.
- [ ] `git show --stat --oneline HEAD` contains only approved planning artifacts.
- [ ] `git diff --check` reports no whitespace errors.

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
- [ ] GPL-3.0 license text and AntennaPod GPL reference are present.
- [ ] README documents prerequisites and the exact foundation build commands.
- [ ] DerivedData, build output, user Xcode state and signing material are ignored.

**Verification:**
- [ ] `rg -n 'GNU GENERAL PUBLIC LICENSE|AntennaPod|xcodebuild' LICENSE THIRD_PARTY_NOTICES.md README.md` finds each required element.
- [ ] `git check-ignore` confirms representative generated and signing files are ignored.
- [ ] `git diff --cached --check` reports no whitespace errors before commit.

**Dependencies:** Task 1

**Files likely touched:**
- `.gitignore`
- `LICENSE`
- `THIRD_PARTY_NOTICES.md`
- `README.md`

**Estimated scope:** Medium: 4 files

## Checkpoint: Repository foundation

- [ ] Tasks 1-2 are committed separately.
- [ ] Working tree contains no unrelated files staged by FennecCast work.
- [ ] Android repository status is unchanged from the initial inventory.

## Task 3: Add the minimal SwiftUI app target

**Description:** Add a checked-in Xcode project, shared scheme and the smallest complete SwiftUI launch path using an explicitly injected `AppEnvironment`.

**Acceptance criteria:**
- [ ] `FennecCast.xcodeproj` defines an iOS 17 App target using Swift 6 and Bundle Identifier `com.ron159.FennecCast`.
- [ ] Shared `FennecCast` scheme builds the App target.
- [ ] `FennecCastApp` creates `AppEnvironment` and injects it into `RootView`.

**Verification:**
- [ ] Generic iOS Simulator build succeeds with signing disabled using the spec command.
- [ ] `xcodebuild -list -project FennecCast.xcodeproj` reports target and scheme `FennecCast`.
- [ ] `swift-format lint --strict --recursive Sources` succeeds.

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
- [ ] Root screen has localized title and foundation status text.
- [ ] English and `zh-Hans` translations exist for each user-visible string.
- [ ] Asset catalog provides a named accent color without adding placeholder artwork.

**Verification:**
- [ ] Generic iOS Simulator build succeeds.
- [ ] A static catalog check confirms every foundation key has English and `zh-Hans` values.
- [ ] `swift-format lint --strict --recursive Sources` succeeds.

**Dependencies:** Task 3

**Files likely touched:**
- `Sources/App/RootView.swift`
- `Sources/Resources/Localizable.xcstrings`
- `Sources/Resources/Assets.xcassets/Contents.json`
- `Sources/Resources/Assets.xcassets/AccentColor.colorset/Contents.json`

**Estimated scope:** Medium: 4 files

## Checkpoint: Runnable app

- [ ] Tasks 3-4 are committed separately.
- [ ] App target builds without signing.
- [ ] No business feature or third-party dependency was added.

## Task 5: Add the XCTest target

**Description:** Add the FennecCastTests target to the existing project and scheme, with behavior-focused tests for the default app environment and localization resources.

**Acceptance criteria:**
- [ ] XCTest target links against the App target through `@testable import FennecCast`.
- [ ] Tests verify the default app name and the presence of both supported localizations.
- [ ] Shared scheme includes the XCTest target in its Test action.

**Verification:**
- [ ] Generic iOS Simulator `build-for-testing` succeeds with signing disabled.
- [ ] `xcodebuild -list -project FennecCast.xcodeproj` reports `FennecCastTests`.
- [ ] `swift-format lint --strict --recursive Sources Tests` succeeds.

**Dependencies:** Task 4

**Files likely touched:**
- `FennecCast.xcodeproj/project.pbxproj`
- `FennecCast.xcodeproj/xcshareddata/xcschemes/FennecCast.xcscheme`
- `Tests/AppFoundationTests.swift`

**Estimated scope:** Medium: 3 files

## Task 6: Verify and close app-foundation

**Description:** Run every currently executable spec gate, audit the resulting files and Git history, and update task evidence without broadening scope.

**Acceptance criteria:**
- [ ] All executable success criteria in `SPEC-app-foundation.md` have fresh passing evidence.
- [ ] Simulator runtime limitation is documented accurately and is not represented as a passing runtime test.
- [ ] Working tree is clean after the final atomic commit.

**Verification:**
- [ ] Generic Simulator `build` succeeds.
- [ ] Generic Simulator `build-for-testing` succeeds.
- [ ] Full Swift format lint succeeds.
- [ ] `git diff --cached --check`, focused secret scan and `git status -sb` are clean.

**Dependencies:** Task 5

**Files likely touched:**
- `tasks/todo.md`

**Estimated scope:** Small: 1 file

## Checkpoint: app-foundation complete

- [ ] Review `SPEC-app-foundation.md` success criteria against current evidence.
- [ ] Review commit history for scope and rollback safety.
- [ ] Obtain human review before starting `core-contracts`.
