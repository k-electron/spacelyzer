<!--
Sync Impact Report
==================
Version change: 2.0.0 -> 2.1.0
Rationale: MINOR. Principle I's prohibition on networking is unchanged; what is removed is the
requirement to prove it with an automated check on the built binary. Nothing that complied before
stops complying, so this is not a backward-incompatible redefinition — the commitment is simply
upheld by design and review rather than enforced by tooling.

Modified principles:
- I. Local-First and Private by Default: drops the mandated build-time verification and the
  framework-linking clause, which was a poor proxy in any case since Foundation carries networking
  regardless. The prohibition on writing networking code stands.

Added sections: none

Removed sections: none

Downstream follow-up (outside this document):
- The plan carried a gate item requiring the automated check to be built. It is withdrawn.

Prior history:
- 2.0.0 (2026-08-08): dropped the App Sandbox and closed TODO(DISTRIBUTION_CHANNEL) in favour of
  Developer ID direct download, foreclosing the Mac App Store. Amended Principle I's enforcement
  mechanism, since an undeclared entitlement means nothing outside a sandbox, and Principle II to
  record that the removal guards are now the only barrier against data loss. Hardened Runtime,
  Developer ID signing, and notarization remain required.
- 1.4.1 (2026-08-08): refined Principle III's activity indication to appear after roughly 150
  milliseconds rather than immediately, avoiding indicator flicker on fast operations.
- 1.4.0 (2026-08-08): broadened Principle III from scanning to every operation that loads,
  computes, or waits, and required background activity to be visible and never to disable
  unrelated controls or block its own cancellation.
- 1.3.0 (2026-08-08): added Principle VIII on repository hygiene and committed secrets. The two
  violations it recorded, a missing root .gitignore and tracked xcuserdata, were remediated in
  commit d7699ba.
- 1.2.0 (2026-08-08): added Principle VII requiring documentation, spec artifacts, and this
  document to be updated in the same change as the behavior they describe.
- 1.1.0 (2026-08-08): added Principle VI requiring open-source, well-maintained dependencies
  pinned to their latest stable release; narrowed Principle V to defer to it.
- 1.0.0 (2026-08-08): initial ratification; all template placeholders replaced with concrete
  governance for Spacelyzer, a native macOS disk-space analyzer.
-->

# Spacelyzer Constitution

Spacelyzer is a native macOS application that scans the local filesystem and shows a person what
is consuming their disk space. It reads across a user's home directory and can remove files on
their behalf, which means it runs with a level of trust that most applications never ask for.
The principles below exist to keep that trust intact.

## Core Principles

### I. Local-First and Private by Default (NON-NEGOTIABLE)

Spacelyzer MUST function completely without network access; no feature may depend on a network
round trip. Scan results, file paths, filenames, and usage data MUST NOT leave the device by any
means: no analytics, no crash-reporting SDK, no remote configuration, no cloud sync. The app MUST
NOT contain code that opens a network connection or issues a network request. Diagnostic logging
MUST go through OSLog with paths and user content marked private so they are redacted from captured
logs.

Rationale: A completed scan is a map of everything a person keeps on their Mac, and it is the most
sensitive artifact this app produces. Spacelyzer ships without the App Sandbox, so the operating
system no longer prevents that map from leaving. What keeps it here is that no such feature will be
built — a design commitment upheld in review, not a boundary policed by tooling. The app has no
reason to reach the network, so the simplest way to guarantee it never does is to never write the
code.

### II. Destructive Actions Are Guarded (NON-NEGOTIABLE)

Deletion MUST be initiated by an explicit user action against a specific named selection, never
as a side effect of scanning, sorting, filtering, or navigating. Removal MUST move items to the
Trash rather than unlinking them, unless the user explicitly chooses permanent deletion within
that same interaction. Before any removal the interface MUST show what will be removed: item
count, total size, and the affected paths in a reviewable form. Protected locations, including
system directories, SIP-protected paths, and the app's own container, MUST be excluded from
removal targets. Bulk operations MUST be cancellable and MUST surface per-item failures rather
than failing silently or partially.

Spacelyzer ships without the App Sandbox, so the operating system places no limit on what it is
able to delete. These guards are therefore the only barrier between a defect in the removal path
and the permanent loss of someone's data. They MUST be enforced in the model layer, where no
interface change or new entry point can route around them, and every guard MUST carry automated
coverage proving that protected locations are refused.

Rationale: A cleanup tool that removes the wrong thing destroys data the user cannot get back.
Recoverability and informed consent are far cheaper than any recovery attempt or apology. Running
unsandboxed removes the backstop that would otherwise contain the damage, which raises the standard
these guards must meet rather than lowering it.

### III. Never Block, Always Show Progress

No operation may block the main actor, which is reserved for rendering and handling input. This
covers everything that loads, computes, or waits, not scanning alone: filesystem traversal, size
computation, aggregation, content hashing, duplicate comparison, filtering, layout, preview
generation, removal, and restoration MUST all run elsewhere.

An operation still running after roughly 150 milliseconds MUST make its activity visible in the
interface and MUST keep that indication until it finishes. Operations that finish sooner SHOULD
show nothing: an indicator that appears and vanishes on every keystroke tells the user less than
no indicator at all. What matters is that nobody is left facing an unchanged interface wondering
whether the app is working or has stopped; the form the indication takes is a judgment call best
made where it appears.

Any operation that can exceed two seconds MUST report incremental progress describing what is
being worked on and how far it has advanced, rather than an indeterminate spinner.

The interface MUST remain interactive while background work runs. Background work MUST NOT disable
parts of the interface unrelated to it, and MUST NOT prevent the user from cancelling it. Every
operation for which cancellation is meaningful MUST be cancellable, and cancellation MUST take
effect within one second.

Unreadable entries such as permission-denied directories and dangling symlinks MUST be skipped and
reported in a summary instead of aborting the operation. Symlinks and hardlinks MUST NOT be
traversed in a way that double-counts bytes or creates traversal cycles.

Rationale: Real home directories hold millions of files, and nearly everything this app does waits
on disk. A correct answer that arrives after a frozen window is indistinguishable from a crash, and
an app working silently is indistinguishable from one that has given up. Both cost the user the
same thing, which is any reason to believe the tool is still doing what they asked.

### IV. Verified Before Merge

Every change MUST land with the SpacelyzerTests and SpacelyzerUITests suites passing and MUST NOT
introduce new compiler warnings. Traversal, sizing, aggregation, and exclusion logic MUST be
unit-testable against temporary fixture directories, never against the developer's real home
directory or hardcoded machine-specific paths. Every bug fix MUST include a regression test that
fails without the fix. Deletion paths MUST carry automated coverage proving that protected
locations are refused. Tests may be written before or after the implementation they cover; what
is enforced is coverage at merge time, not authoring order.

Rationale: The riskiest parts of this app, traversal math and deletion, are precisely the parts
that are cheap to test and ruinously expensive to get wrong on a user's machine.

### V. Native and Minimal

The interface MUST be built in SwiftUI and MUST follow the macOS Human Interface Guidelines,
including full keyboard navigation, VoiceOver labels on interactive controls, Dynamic Type, and
both light and dark appearances. Persistence MUST use SwiftData unless a recorded measurement
shows it cannot meet a stated requirement. Third-party dependencies MUST be justified in the
feature plan with what the dependency does and why the platform SDK is insufficient; the default
answer is no, and anything clearing that bar MUST also satisfy Principle VI. Features MUST be
built for the requirement at hand rather than an anticipated one.

Rationale: Every dependency and speculative abstraction is code the team did not write but must
still ship, audit, sandbox, and maintain across OS releases.

### VI. Dependencies Are Open, Proven, and Current

Any dependency that clears the justification bar in Principle V MUST be free and open source
under an OSI-approved license. Proprietary, source-available, commercially licensed, and
closed-binary distributions MUST NOT be used. While the distribution channel remains undecided,
licenses whose obligations conflict with shipping a closed-source binary, notably GPL and AGPL,
MUST NOT be adopted.

A dependency MUST demonstrate a strong reputation before adoption, evidenced in the feature plan
by all of the following: active maintenance with commits or releases within the last twelve
months, meaningful real-world adoption beyond its own authors, a visible issue and
security-response history, and no unresolved advisories affecting the version being adopted.

Dependencies MUST be adopted at their latest stable release. Pre-release, beta, nightly, and
branch references MUST NOT be used. Resolved versions MUST be committed to source control, and
dependencies MUST be reviewed for available stable upgrades as routine maintenance rather than
only when a bug or advisory forces the issue.

Rationale: An open, well-maintained dependency is a liability the project can inspect, patch, or
replace; an abandoned or opaque one becomes permanent. Tracking the latest stable release keeps
Spacelyzer on the version upstream is actually fixing, instead of one nobody is watching.

### VII. Docs and Code Stay in Sync

Documentation MUST be updated in the same change as the behavior it describes; a documentation
edit MUST NOT be deferred to a follow-up change. Any change that alters user-visible behavior, a
public API, a build setting, or a supported workflow MUST carry the corresponding documentation
edit alongside it.

Feature artifacts under `specs/` are living records rather than historical ones. When an
implementation diverges from its `spec.md`, `plan.md`, or `tasks.md`, that artifact MUST be
corrected to describe what was actually built, or the divergence MUST be recorded in it together
with the reason. Task status MUST be updated as work lands, not reconstructed afterwards.

This constitution asserts concrete facts about the project, including the deployment target, the
bundle identifier, the sandbox settings, and the stack. Any change that makes one of those facts
false MUST amend this document under the Governance rules in the same change.

Documentation MUST describe shipped behavior. Planned or partial behavior MUST be labeled as
such rather than written as though it already works. Documentation referring to removed code
MUST be corrected or deleted by the change that removes it, and documentation found to be stale
MUST be treated as a defect and fixed on the same terms as a code bug.

Rationale: Documentation that has quietly drifted is worse than none at all, because a reader
who trusts it makes decisions based on software that no longer exists. The moment the change is
authored is the only point at which someone reliably knows what actually changed.

### VIII. Only Intended Files Are Committed

The repository MUST maintain a root `.gitignore`, and it MUST be extended in the same change
that introduces a new class of generated, local, or machine-specific output. At minimum it MUST
exclude macOS filesystem noise such as `.DS_Store`, Xcode build products and derived data,
per-user Xcode state under `xcuserdata`, and local environment or credential files.

Secrets MUST NOT be committed in any form, including API keys, access tokens, signing
certificates, private keys, provisioning profiles, passwords, and personal identifiers. Values
that vary by machine or carry a secret MUST be supplied at build or run time from an ignored
local file or the system keychain, never from a checked-in literal. This prohibition is absolute
and MUST NOT be waived by a plan-level justification.

Committing is a deliberate act. The staged file list MUST be reviewed before every commit, and
blanket staging MUST NOT be used unless ignore coverage has just been verified. A file that is
generated, machine-specific, or reproducible from other tracked inputs MUST NOT be tracked.

If a secret does reach the repository, the credential MUST be treated as compromised and rotated
immediately. Removing it from history is a secondary step and never a substitute for rotation.

Rationale: History is effectively permanent and, once pushed, beyond anyone's recall. An ignore
rule written before the first bad commit costs nothing, while the same rule written afterwards
leaves behind a credential to rotate and a history to rewrite.

## Platform and Technology Constraints

- Target platform is macOS only, building against the macOS SDK with a macOS 26.5 deployment
  target. iOS and iPadOS support is out of scope and MUST NOT drive design compromises.
- The stack is Swift with SwiftUI for interface, SwiftData for persistence, Swift Testing for
  unit tests, and XCUITest for UI tests.
- The App Sandbox is deliberately NOT enabled. A sandboxed app cannot enumerate volumes, cannot
  reach the filesystem except through locations the user selects in an open panel, and cannot see
  space held by system snapshots at all. Those limits are incompatible with the product.
- Hardened Runtime MUST remain enabled in every build configuration. Every release MUST be signed
  with a Developer ID identity and notarized.
- Distribution is Developer ID direct download. Mac App Store distribution is foreclosed by the
  absence of the sandbox and is out of scope; no work may be undertaken on the assumption that it
  will return without a MAJOR amendment to this document.
- Access to protected locations depends on the user granting Full Disk Access in System Settings.
  The app MUST NOT present itself as requiring it, MUST remain useful without it, and MUST report
  the resulting gap in coverage rather than presenting an incomplete scan as a complete one.
- Private and deprecated API MUST NOT be used. Where a capability is only reachable by invoking a
  system command-line tool, that dependency MUST be isolated behind a single interface, MUST treat
  the tool's output as untrusted and changeable, and MUST degrade to a stated approximation when
  parsing fails rather than reporting a wrong number confidently.
- Dependencies permitted under Principles V and VI MUST be integrated with Swift Package Manager
  and pinned to an exact stable version, with the resolved-version file committed so that builds
  are reproducible and the adopted version is auditable.
- The bundle identifier is co.lifehabitz.Spacelyzer.
- Logging MUST use OSLog. Calls to print MUST NOT appear in shipped code.

## Development Workflow and Quality Gates

- Feature work follows the Spec Kit flow: specify, then plan, then tasks, then implement. Any
  non-trivial feature MUST have a written spec before implementation begins.
- Every plan MUST include a Constitution Check. A detected violation is either designed out or
  documented with an explicit justification and the alternative that was rejected.
- All of the following merge gates MUST pass before a change lands:
  1. The project builds clean in Debug and Release with no new warnings.
  2. All unit and UI tests pass.
  3. Any new destructive or entitlement-affecting code carries tests and a review sign-off.
  4. No new third-party dependency appears without a recorded justification and the license,
     reputation, and version evidence required by Principle VI.
  5. Documentation affected by the change, including feature artifacts under `specs/` and this
     constitution, is updated within the same change.
  6. No generated, machine-specific, or secret-bearing file is added to version control, and
     any newly generated output class is covered by `.gitignore`.
- Changes touching deletion behavior, entitlements, or sandbox configuration MUST be reviewed as
  a self-contained change and MUST NOT be bundled into an unrelated refactor.
- Review means a second reviewer where one is available; on a solo change it means an explicit
  self-review pass recorded in the change description.
- Commits MUST be atomic and describe intent rather than mechanics.

## Governance

This constitution supersedes other practices, conventions, and habits on this project. Where a
tool default, project template, or generated scaffold conflicts with it, this document wins.

Amendments MUST be made by editing this file in a dedicated change that states the motivation,
the version bump, and the migration impact on existing code. This document is versioned
semantically: MAJOR for removing or redefining a principle in a backward-incompatible way, MINOR
for adding a principle or section or materially expanding guidance, and PATCH for clarifications,
wording, and non-semantic refinements.

Principles marked NON-NEGOTIABLE MUST NOT be waived by a plan-level justification; changing them
requires a MAJOR amendment. Compliance is verified at two points: the Constitution Check in each
feature plan, and the merge gates above. Runtime development guidance for contributors and agents
lives alongside this file under `.specify/`; where that guidance and this constitution disagree,
this constitution governs.

**Version**: 2.1.0 | **Ratified**: 2026-08-08 | **Last Amended**: 2026-08-08
