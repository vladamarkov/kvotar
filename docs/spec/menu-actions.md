---
summary: The right-click menu — its two doors, the order and exact copy of every item, when each item shows, hides or is greyed, its one key equivalent, the caption row, the About panel, the Open at Login item and its failure path, and the Notify me permission hints — with which page owns the behaviour behind each item.
read_when: Adding, renaming, reordering, hiding or greying an item in MenuBarController.contextMenu() or changing one of its @objc actions or the closures AppDelegate injects for them; changing NotificationPermissionHint; changing the app window's ⋯ button (QuotaWindowController addMenuButton, showMenu, buildMenu); changing ProductIdentity.tagline, descriptionSentence or supportEmail, MenuBarDisplayMode.label or NotificationGroup.label; changing AppDelegate.toggleLaunchAtLogin or setLaunchAtLogin.
---

# Menu actions

## Questions for owner

None.

## About this page

This page is the specification for Kvotar's right-click menu. It replaces the private UI Spec
Part 3 §1a (right-click menu inventory), the menu paragraph of the private UI Spec Part 3 §7 (the
app window's `⋯` door) and the right-click part of the private Implementation Baseline §14.1
(menu-bar display modes). Change this page in the same commit as the code it describes. The copy
below is the shipped copy; a change to it is a change to this page.

**Settings available today live in this menu:** every setting a user can change in the app after
the first run is an item here. For a separate Settings window, see
[product scope, Decided 1](product-scope.md#decided).

What this page owns: the menu itself, both ways to open it, its order, separators and copy, when
each item shows or is greyed, the key equivalent, the caption row, the About panel, **Quit** as an
item, the **Open at Login** item, and the copy of the Notify me permission hints. What it links:

| Behind the item | Page |
|---|---|
| What each menu-bar display mode draws, and where the choice is stored | `menu-bar.md` (pending) |
| The four notification switches: their events, defaults and settings keys | [First-run window, screen 4](first-run-window.md#screen-4--when-should-kvotar-interrupt-you-onboardingnotificationsscreen) |
| When notifications fire, and the permission request itself | `notifications.md` (pending) |
| The first-run window that **Welcome to Kvotar…** reopens | [First-run window](first-run-window.md#when-it-opens) |
| The app window, which surface opens, and what quitting tears down | [App lifecycle](app-lifecycle.md) |
| The History window | `history.md` (pending) |
| **Save Diagnostics…** and extended diagnostics | [Diagnostics](diagnostics.md) |
| What an update check does, and the automatic-check schedule | [Updates and releases](updates-and-releases.md) |
| The per-tool setup card (`FirstRunCardView`) that **Set up …** opens | `popover.md` (pending) |

Every string in the menu follows [the copy rule](display-semantics.md#the-copy-rule-no-polling-words):
no polling words.

## Two doors, one menu

- **Right-click on the status item.** A right click, a two-finger tap or a Control-click opens the
  menu; a plain left click toggles the popover. An open popover closes first.
  (`App/MenuBarController.swift`: `statusItemClicked`, `showContextMenu`)
- **The `⋯` button in the app window's titlebar** (accessibility label *More options*) opens the
  same menu below the button. The window stays open while the menu is up.
  (`App/QuotaWindowController.swift`: `addMenuButton`, `showMenu`)
- **One builder.** Both doors call `MenuBarController.contextMenu()` (the window through its
  `buildMenu` closure, wired in `App/AppDelegate.swift`). Reason: the order and copy cannot drift
  between the two doors, because there is only one menu.
- **Built fresh on every open.** Every checkmark, title and shown or hidden item is read at the
  moment the menu opens, so a change made elsewhere (a tool detected, capture expired, a login
  item changed in System Settings) shows on the next open. Each build first asks for a fresh read
  of the notification permission (`onContextMenuWillOpen`); see
  [Notify me](#notify-me-and-its-permission-hints) for when that read lands.
- **Why a second door exists:** macOS can hide the status item when the menu bar is full, and this
  menu is the only place to change a setting. When and how the app window
  opens is [app lifecycle](app-lifecycle.md).

## The menu, top to bottom

Separators are where the table shows them. "Greyed" means shown but not clickable.

| # | Item (exact copy) | Shown | Greyed | Calls | Behaviour owned by |
|---|---|---|---|---|---|
| 1 | *Claude Code and Codex capacity intelligence* | Always | Always (a caption) | Nothing | This page |
| | — separator — | | | | |
| 2 | **Menu bar display** ▸ **Both (stacked)** · **Claude only** · **Codex only** | Always | Never | `onSelectMode` | `menu-bar.md` (pending) |
| | — separator — | | | | |
| 3 | **Open at Login** | Always | Never | `onToggleLaunchAtLogin` | This page |
| 4 | **Notify me** ▸ (or **Notify me — off in System Settings** ▸) | Always | See [below](#notify-me-and-its-permission-hints) | `onToggleNotificationGroup`, `onOpenNotificationSettings` | [First-run window](first-run-window.md#screen-4--when-should-kvotar-interrupt-you-onboardingnotificationsscreen); `notifications.md` (pending) |
| | — separator — | | | | |
| 5 | **Set up Claude Code…** / **Set up Codex…** | Only while that tool is not detected | Never | `onPresent(.setup(tool))` | `popover.md` (pending), [app lifecycle](app-lifecycle.md) |
| | — separator — (only when item 5 is shown) | | | | |
| 6 | **Welcome to Kvotar…** | Always | Never | `onOpenWelcome` | [First-run window](first-run-window.md#when-it-opens) |
| | — separator — | | | | |
| 7 | **Open in Window** | Always | Never | `onOpenQuotaWindow` | [App lifecycle](app-lifecycle.md) |
| 8 | **History…** | Always | Never | `onOpenHistory` | `history.md` (pending) |
| 9 | **Save Diagnostics…** | Always, in every build channel | Never | `onSaveDiagnostics` | [Diagnostics](diagnostics.md#save-diagnostics) |
| 10 | **Enable Extended Diagnostics for 24 Hours…** / **Turn Off Extended Diagnostics…** | Always | Never | `onConfigureExtendedDiagnostics` | [Diagnostics](diagnostics.md#turning-it-on-and-off) |
| | — separator — | | | | |
| 11 | **Check for Updates…** | Always | While a check is already running | `onCheckForUpdates` | [Updates and releases](updates-and-releases.md) |
| 12 | **Check for updates automatically** | Always | Never | `onToggleAutomaticUpdateChecks` | [Updates and releases](updates-and-releases.md) |
| 13 | **About Kvotar** | Always | Never | `showAbout` (in the controller) | This page |
| 14 | **Quit Kvotar** ⌘Q | Always | Never | `NSApp.terminate` | This page; teardown is [app lifecycle](app-lifecycle.md) |

(`MenuBarController.contextMenu()`; the closures are set in `App/AppDelegate.swift`)

Rules behind the table:

- **Settings first, then surfaces, then app chrome.** The groups are: what Kvotar is; how the menu
  bar looks; when Kvotar may start and interrupt; getting a tool set up and learning to read the
  bar; the windows and diagnostics; updates, About and Quit. **Check for Updates…** sits beside
  **About**, where macOS apps put it.
- **The controller holds no setting and calls no service.** Every action is a closure the app
  delegate injects; the controller touches no store, no ServiceManagement and no Sparkle. Two
  reads are direct: the display mode from the view model, and the extended-diagnostics title from
  `DiagnosticsCapture.isEnabled`. Reason: the composition root owns the services, and the menu
  only asks. A new item follows the same shape: a
  closure on `MenuBarController`, set in `AppDelegate`.
- **The menu names a destination, not a surface,** with one exception. **Set up …** asks for a
  tool's setup card and lets the presenter pick the popover or the app window
  (`QuotaSurfacePresenter.present`). **Open in Window** is the one item that names a surface,
  because naming it is its purpose. It calls `QuotaSurfacePresenter.presentWindow`, not `present`,
  because the presenter's own choice would hand back the popover the user is standing in.
- **Checkmarks read their owner live.** Display mode from the view model; **Open at Login** from
  `SMAppService.mainApp.status`; **Notify me** rows from the app's cached switches (absent means
  the group's default); **Check for updates automatically** from Sparkle's own preference. No
  item keeps a copy of a state another system owns.

### Item details

- **The caption row** is `ProductIdentity.tagline`. It has no action, so the menu's automatic
  enabling greys it and it reads as a label. It is in sentence case on purpose: every other row is
  a title-cased command, and the caption must not read like one. Reason for having it: it answers
  "what is this?" for someone poking around the menu, without lengthening the app's name in the
  menu bar, Finder, banners or Login Items.
- **Menu bar display** has three items from `MenuBarDisplayMode.label`, with a checkmark on the
  active mode. A click hands the mode to the app delegate, which applies and stores it at once;
  every mode leaves a status item to right-click, so none asks for confirmation.
- **Set up Claude Code… / Set up Codex…** appear in tool order (Claude first), one per tool that is
  not detected ([the two tools](product-scope.md#the-two-tools)). A machine with both tools
  detected sees neither, and no separator for them. Because the menu is rebuilt on every open, an
  item disappears on the first open after its tool is detected. Reason: it is the way in for
  someone who installed a tool that Kvotar does not see; an undetected tool has no tab.
- **Welcome to Kvotar…** is always present. It reopens the first-run window
  (`OnboardingWindowController.show`); see [first-run window](first-run-window.md#when-it-opens).
- **Open in Window** has no ellipsis: it opens the surface and asks nothing further. It is **never
  greyed**, including from the app window's own `⋯`, where it brings the window forward. Reason: a
  rule that greys it there would be one more thing to explain than the no-op it prevents.
- **History…** opens the History window in its ordinary opening (`HistoryWindowController.show`
  with no destination). The ellipsis follows the macOS convention for an item that opens something.
- **Save Diagnostics…** ships in every build channel: it is the support path, not an extra for test builds.
  The ellipsis says the click does not finish the job (it ends in Finder).
- **The extended-diagnostics title** reads **Turn Off Extended Diagnostics…** while capture is on
  and unexpired (`DiagnosticsCapture.isEnabled`), and **Enable Extended Diagnostics for 24
  Hours…** otherwise. What each does is [diagnostics](diagnostics.md#turning-it-on-and-off).
- **Check for Updates…** is built with no action while Sparkle reports a check in flight
  (`UpdaterService.canCheckForUpdates` is false), so automatic enabling greys it, the same way as
  the caption. **Check for updates automatically** carries a checkmark bound to
  `UpdaterService.automaticallyChecksForUpdates`; a click flips it.

## Open at Login

- **The checkmark is the system's registration.** It is on exactly when
  `SMAppService.mainApp.status` is `.enabled`; any other status shows it off. There is no settings
  row to keep in sync. (`AppDelegate`: `isLaunchAtLoginEnabled`)
- **A click flips it:** register when not enabled, unregister when enabled
  (`AppDelegate.toggleLaunchAtLogin` → `setLaunchAtLogin`). Asking for the state it is already in
  does nothing.
- **The same registration as the first-run window's checkbox.** Screen 5's **Start Kvotar when I
  log in** uses `setLaunchAtLogin` too, so the menu and the window never disagree about the
  system's state ([first-run window, screen 5](first-run-window.md#screen-5--what-kvotar-never-sees-onboardingprivacyscreen)).
- **Failure path.** If registering or unregistering throws, the error is logged
  (`Launch-at-login toggle failed`, with the error) and nothing is shown to the user. Because the
  checkmark is read from the system at the next open, it shows the real state, so a failed click
  looks like a click that did nothing. A build run from outside an installed app bundle is
  expected to fail this way. See *Known gaps*.
- How an app launched at login behaves (it stays silent) is [app lifecycle](app-lifecycle.md).

## Notify me and its permission hints

The submenu holds the four notification switches, **At risk**, **Fast burn**, **Over quota** and
**Window reset** (`NotificationGroup.label`, the same labels as the first-run window's screen 4),
each with a checkmark when on. A click flips that group's switch and stores it. What each group
covers, its default and its key are on
[the first-run window page](first-run-window.md#screen-4--when-should-kvotar-interrupt-you-onboardingnotificationsscreen).
The switches name groups only, never an engine event, cap or cooldown.

What macOS will do with a warning decides one optional row above the four. The app reads the
permission and the alert style together into one of three cases (`NotificationPermissionHint.reading`):

| Case | When | Parent title | Row above the four (then a separator) | The four rows |
|---|---|---|---|---|
| Off | Permission denied, **or** allowed with the alert style set to None | **Notify me — off in System Settings** | **Off in System Settings — Open…** | Greyed, checkmarks kept |
| Banners | Allowed, style Banners | **Notify me** | **Warnings hide after a few seconds — Keep them on screen…** | Enabled |
| Fine | Allowed with Alerts, not yet asked, provisional, or anything else (ephemeral, an unknown style, or before the first read) | **Notify me** | None | Enabled |

- **Both hint rows open System Settings › Notifications** (`NotificationPermissionHint.settingsURL`,
  through `NSWorkspace`). Only the user can change the permission or the style.
- **"Off" names the system's switch, not Kvotar's.** The four checkmarks keep their state while
  greyed, because they still decide what fires once the user allows notifications again.
- **The parent title says "off" before the submenu opens,** so the state is readable at a glance.
  The Banners case keeps the plain title: a nudge, not an alarm.
- **No row asks for permission.** The app never re-prompts; macOS asks once. When the request is
  made is the first-run window's and `notifications.md`'s (pending).
- **The submenu sets each row's enabled state itself** (`autoenablesItems = false`), so the hint
  row stays clickable while the four are greyed.
- **When the case updates.** Each menu build asks for a fresh read
  (`AppDelegate.refreshNotificationAuthorization`). The read lands after the menu is built, so a
  change made in System Settings shows one open later. See *Known gaps*. The other moments the
  permission is read are `notifications.md`'s (pending).

Why the hints exist: a tester had notifications denied by macOS while every checkmark was on, so
"on" in the menu read as "will show", and nothing did. Allowed with the style set to None looks the
same to the user, and a banner leaves the screen after a few seconds, often before the warning is
read.

## About Kvotar

The standard macOS About panel (`NSApp.orderFrontStandardAboutPanel`), then the app activates so
the panel comes to the front. (`MenuBarController.showAbout`)

- **From the bundle:** the name and `Version x.y.z (n)`.
- **The icon** is passed explicitly from the bundled `AppIcon.icns` when it loads. Reason: the
  panel's own lookup left the icon blank in a locally rebuilt menu-bar-only app.
- **The description block**, small secondary text, centred, three parts:
  1. `ProductIdentity.tagline` (the caption row's text)
  2. `ProductIdentity.descriptionSentence`: *Tracks how much you have left, how fast you're using
     it, and when it resets.*
  3. After a blank line, `Feedback:` and `ProductIdentity.supportEmail`, the same address every
     diagnostics bundle's `WHAT_LOOKED_WRONG.txt` names.
- **No third-party notices link.** The bundled notices file stays in the app for the licences it
  carries; nothing in the panel links it.

## Quit and the key equivalent

- **Quit Kvotar** calls `NSApp.terminate`. What shutting down does is [app lifecycle](app-lifecycle.md).
- **⌘Q is the menu's only key equivalent,** shown beside **Quit Kvotar**. Kvotar is a menu-bar-only
  app with no app menu, and a menu shown only on click handles no shortcut while it is closed. The
  app window therefore handles ⌘Q and ⌘W itself (`QuotaWindowController.installKeyMonitor`;
  [app lifecycle](app-lifecycle.md)).

## Rejected alternatives

- **A popover footer** with a Settings gear, a pause switch and a Quit button. Never built; pausing
  was cut, and Quit stayed in this menu. For the Settings window it would have opened, see
  [product scope, Decided 1](product-scope.md#decided).
- **The notification switches in a Settings window, or only in the first-run window.** See the
  [first-run window's rejected list](first-run-window.md#why-it-exists).
- **Other names for Save Diagnostics….** *Report a Problem…* would be clicked at the moment
  something looks wrong, while the logs still hold it, but the maintainer chose the name that says
  exactly what the click does. *Telemetry*, in any form, implies the app transmits, which it does
  not. *Share Logs* anchors the reader on logs when the bundle is mostly database.
- **For Open in Window:** greying it in the app window's own `⋯` menu, an ellipsis, and putting it
  first in the menu (the menu's shape is settings first, surfaces later).
- **An update reminder as a menu row only.** A row that appears only on right-click is easy never to
  see; an update shows Sparkle's own window instead ([updates and releases](updates-and-releases.md)).
- **A third-party notices link in the About panel.** Shipped once, then removed by the maintainer.

## Known gaps

| Gap | Today | Proposed |
|---|---|---|
| Nothing tests the menu's build | `contextMenu()` has no test. `NotificationPermissionHintTests` pins the hint copy and `NotificationPermissionHint.reading`, but not the order, separators, titles, shown or greyed rules, or what each item calls. `MenuBarController.init` creates a real status item, which makes the builder awkward to call from a test | An App-level test (`KvotarTests`) that builds the menu with stubbed closures and checks: the titles and separators in order; the caption greyed; zero, one or two **Set up** items by detected tools; the three Notify me readings (parent title, hint row, rows greyed or not); **Check for Updates…** greyed while a check runs; both extended-diagnostics titles. If the status item gets in the way, move the builder into a function that takes the menu's inputs |
| A failed Open at Login click is silent | The error is logged only; the checkmark simply stays as it was. A registration that succeeds but waits for the user's approval in System Settings (`.requiresApproval`) also shows off with no hint, and the next click registers again | Show a short alert that names System Settings › General › Login Items, with a test of the failure path |
| The permission hint lags one open | The read made when the menu is built lands after it, so a change in System Settings shows on the following open | Fill the Notify me submenu when it opens (an `NSMenuDelegate` on the submenu), by which time the read has landed |
| `showsHint(for:)` is unused | Nothing in the app calls `NotificationPermissionHint.showsHint`; the menu uses `reading`. Two tests (`testDeniedShowsTheHint`, `testEveryOtherStatusStaysSilent`) still pin it | Delete it and its two tests, or point the tests at `reading` |
| Stale comments | `MenuBarController.onToggleLaunchAtLogin`'s comment says it returns the new state (it returns nothing); `AppDelegate.toggleLaunchAtLogin`'s comment sits above the notification-group functions, away from its function; `NotificationPermissionHint`'s header says only `.denied` shows a row (allowed with style None does too, and Banners has its own row); comments in both controllers call the app window the "quota window". The "Step 30" comments are on [product scope](product-scope.md#known-gaps) | Fix with the next change to each file |

## Code and test pointers

- `App/MenuBarController.swift`: `contextMenu()`, `statusItemClicked`, `showContextMenu`, the
  `@objc` actions, `showAbout`, `quit`, and the injected closures.
- `App/QuotaWindowController.swift`: `addMenuButton`, `showMenu`, `buildMenu`,
  `installKeyMonitor`.
- `App/AppDelegate.swift`: the closures set on `menuBarController`; `toggleLaunchAtLogin`,
  `setLaunchAtLogin`, `refreshNotificationAuthorization`, `setNotificationGroup`.
- `App/NotificationPermissionHint.swift`: the hint copy, `reading`, `settingsURL`.
- `App/QuotaSurfacePresenter.swift`: `present`, `presentWindow`.
- `App/UpdaterService.swift`: `checkForUpdates`, `canCheckForUpdates`,
  `automaticallyChecksForUpdates`.
- `Packages/KvotarCore/Sources/KvotarCore/ProductIdentity.swift`: `tagline`,
  `descriptionSentence`, `supportEmail`.
- `Packages/KvotarCore/Sources/KvotarCore/Notifications/NotificationTypes.swift`:
  `NotificationGroup.label`, `defaultEnabled`.
- `Packages/KvotarUI/Sources/KvotarUI/Model/MenuBarDisplay.swift`: `MenuBarDisplayMode.label`.
- Tests: `AppTests/NotificationPermissionHintTests.swift`; `QuotaSurfacePresenterTests` (the
  presenter the menu calls). Nothing tests `contextMenu()` itself (see *Known gaps*).

Checked against the code at 595b1b9 + STEP_266
