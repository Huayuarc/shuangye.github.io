# Welcome onboarding port

The welcome uses the original Irisin and Xrash UIKit implementations. It does
not use the earlier rebuilt `WelcomePage` stack; that implementation was
removed after review showed that its icon size, spacing, title and action bar
differed from Irisin.

## Source mapping

| Apelin file | Copied source |
| --- | --- |
| `WelcomeController.swift` | `Irisin/Interface/Onboarding/WelcomeController.swift` |
| `WelcomeFeatureRow.swift` | `Irisin/Interface/Onboarding/WelcomeFeatureRow.swift` |
| `WelcomeStyle.swift` | `Irisin/Interface/DesignTokens/WelcomeStyle.swift` and the original accent token |
| `WelcomeActionBar.swift` | `Irisin/Interface/Onboarding/WelcomeActionBar.swift` |
| `WelcomeListPage.swift` | The table and action-bar hierarchy/constraints in `Irisin/Interface/Onboarding/WelcomeRepositoriesController.swift` |
| `WelcomeSectionHeader.swift` | `Irisin/Interface/Components/RepositoryAddController/RepositoryAddSectionHeaderView.swift` |
| `WelcomeCautionController.swift` | `Irisin/Interface/Onboarding/WelcomeCautionController.swift` |
| `WelcomeNotificationsPage.swift` | `Xrash/Interface/Onboarding/WelcomeNotificationsController.swift`, including `WelcomeNoticePreview` |

The source is Irisin's own repository; Xrash's is its sibling under
`owngoal-dev`. The copied files retain their source
headers and the MIT notice is kept beside them. Irisin's reference capture is
`Documentation/Manual/assets/shots/en/installing-welcome-light.png`.

## Kept from the source

The first page keeps its 520 × 620 form sheet, 64 pt icon, 64 pt space above
and below the icon, 28/24/28/24 content insets, 18 pt stack spacing, 32 pt bold
two-line title, 0.75 pt separator, 10 pt spacing between feature rows, and the
original row fade timing. Reduce Motion makes those rows immediately visible.

The action bar keeps the 0.5 pt rule, regular blur, 12 pt gap below the rule,
24 pt horizontal margins, 48 pt button, and 28 pt bottom safe-area inset.
No loading state replaces its Next button with a disabled Checking button.
The recommendation request keeps exactly two 65 pt rows in the same inset
grouped table. Resolving uses a text shimmer (static with Reduce Motion), then
updates the existing cells. Failure and install progress update the same
labels. There are no row/section reloads, inserts or removals for these states.
Left icons are omitted as requested; installed checkmarks stay on the right.
Next remains available to skip.

The notification page retains Xrash's 92 pt heading start, 24 pt side margins,
18 pt stack and 8 pt heading gap, separate Not Now action above the original
bar, and its 38 pt icon/14 pt content inset/22 pt corner notification preview.
Only the displayed example and permission callback belong to Apelin.

## Apelin behavior

The six steps are product introduction, a resolved SDK/toolchain pair,
provider sign-in, first project creation, notification permission, and the
agent-mistakes reminder. Provider rows are Claude Code, Codex and GitHub Copilot,
each opening its existing login or account-management page using a standard
disclosure indicator. Login completion stays on the provider step; Next is
explicit.

The selected pair follows the backend's host support and reviewed SDK
compatibility. Installation starts only from Install, SDK first, then the
specific toolchain. First Project embeds the same `NewProjectController` table used
by the sidebar, rather than maintaining a second creation form or opening a
second sheet. Its primary action creates and becomes Next after success; Not Now allows a skip
without creating or selecting a project. Names start
as an unused fruit suggestion; any user edit opts out of automatic naming.
The project is created before it is handed back to the root. Existing provider
and environment settings are not reset.

Only the final Get Started marks the welcome completed. Settings → About →
Open Onboarding closes Settings before presenting the same flow again. Replay
does not clear the completion marker or create/install anything by itself.

## Validation

`Scripts/test-onboarding.sh` checks compatible pairing, reviewed-version
preference, already-installed health, valid fruit suggestions, collision
avoidance, and user naming precedence. Device evidence for the complete
ported flow is recorded in `Device-Validation.md` after the final build is
installed; the earlier build 110 capture is not evidence of the final layout.
