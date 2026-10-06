---
summary: What Kvotar does from launch to quit — the order of launch work and what a copy that loses the single-instance lock never reaches, opened by the user versus at login, opening Kvotar again while it runs, a second copy's hand-off, the AgentPilot conflict window, when the app window opens and closes, detecting a hidden menu-bar item and its launch-only notice, and what quit releases.
read_when: Changing AppDelegate's applicationDidFinishLaunching order, applicationShouldHandleReopen or applicationWillTerminate; LaunchSource, SecondInstanceAction, HandoffInbox or QuotaHandoff; AlreadyRunningView or the conflict window; QuotaSurfacePresenter, QuotaSurfaceLifecycle or QuotaWindowController (when the app window opens or closes); HiddenItemDetection or HiddenItemMonitor (gates, constants, triggers); UserNotificationPresenter.presentHiddenItemNotice or onOpenWindow.
---

# App lifecycle

## Questions for owner

None.

## About this page

This page is the specification for Kvotar's life as a process: launch, a second opening while it
runs, a hidden menu-bar item, and quit. It replaces the display and hand-off parts of the private
Baseline §9.2 (process guard), the launch and reopen parts of the private Baseline §14.1
amendments (the app window, silent login), the private Baseline §16 paragraph on the hidden-item
notice, and the opening rules of the private UI Spec Part 3 §7 (the app window,
under its old name). Change this page in the same commit as the code it describes.

IDs such as REV-nn or STEP_nnn in code comments are private record IDs;
[REFERENCES.md](../REFERENCES.md) explains them. The rules here stand without them.

Terms used here:

| Term | Meaning on this page |
|---|---|
| App window | The separate window that shows the same content as the popover (`QuotaWindowController`). Opened by **Open in Window**, a deliberate launch, a reopen, a hand-off and the hidden-item notice. Never called a quota window: that term means only the five-hour or weekly refill period ([quota readings](quota-readings.md)) |
| Deliberate launch | Kvotar started from Finder, Spotlight or `open` |
| Login launch | Kvotar started by macOS as a login item |
| Reopen | Kvotar opened again while this same process runs; macOS calls `applicationShouldHandleReopen` |
| Second copy | A second Kvotar process that starts while another holds the lock |
| Hidden item | macOS is not drawing Kvotar's menu-bar item, usually because the menu bar is full |

What this page does **not** own:

| Topic | Page |
|---|---|
| How the lock is taken, the AgentPilot lock, a stale lock file, and the two lock rulings (a lock-file failure and a missing support folder are lock errors) | [Storage — The single-instance lock](storage.md#the-single-instance-lock) and [Storage — Decided](storage.md#decided) |
| The first poll after launch, and the poll on wake | [Polling — Launch, sleep and wake](polling.md#launch-sleep-and-wake) |
| The polling word in the "already running" copy | [Polling — Known gaps](polling.md#known-gaps) |
| When the first-run window opens, and its launch-at-login checkbox | [First-run window](first-run-window.md#when-it-opens) |
| The **Open at Login** and **Open in Window** menu items, and the `⋯` menu | [menu actions](menu-actions.md) |
| What the popover and the app window show | [popover](popover.md) |
| The quota notifications and their **Open Kvotar** action | [notifications](notifications.md) |
| The `launch`, `quit`, `sleep` and `wake` rows | [Diagnostics](diagnostics.md#where-it-is-stored-and-for-how-long) (`app_lifecycle_events`) |
| Running without storage when the database cannot open | [Storage](storage.md#one-store-one-connection-pool) |

## Launch order

`AppDelegate.applicationDidFinishLaunching` runs the launch work in this order. Only the copy that
holds the lock gets past step 3.

1. **Read the launch source, once.** The launch Apple event is read and decided (see *Opened by the
   user or at login*). Both the lock step and the last step use this one answer. Reason: two reads
   that disagree could make a login-launched second copy post a hand-off. (`resolveLaunchSource`)
2. **Listen for a hand-off.** The observer for a second copy's request is registered **before**
   the lock. Reason: any copy that can see the lock posted its request after this one was already
   listening, so no request falls into the gap. (`registerHandoffObserver`)
3. **Take the lock.** Kvotar's own lock, then the AgentPilot lock when AgentPilot's support folder
   exists (both on [storage](storage.md#the-single-instance-lock)). A refusal goes to the
   second-copy decision below and the launch method returns at once.
4. **Everything else, only for the lock holder:** register the app icon; start the updater; build
   the popover, the menu-bar item (which starts hidden-item detection), the app window and the one
   presenter between the popover and the app window; attach the hand-off inbox, which answers any
   request that arrived since step 2; the AgentPilot import and the database; the notification
   presenter; settings reads and the `launch` row; the right-click menu wiring; the first-run
   window; the providers and the poll coordinator; History; wake, sleep and clock observers; the
   debug and capture observers; then the poll coordinator starts.
5. **Apply the launch source.** A deliberate launch opens the app window, one run-loop turn
   later. Reason: a window ordered front from inside `applicationDidFinishLaunching` in a menu-bar
   app is created and then lost. (`applyLaunchSource`)

**A copy that loses the lock never reaches step 4.** It starts no updater, draws no menu-bar item,
opens no database, writes no `launch` or `quit` row, starts no poll loop and no `codex app-server`,
and runs no hidden-item detection. Reason: two copies polling share one provider budget
([polling](polling.md)), and one database must have one writer.

## What the user sees on each lock outcome

The lock rules are [storage](storage.md#the-single-instance-lock)'s. Today the user sees:

| Lock outcome | Deliberate launch | Login launch |
|---|---|---|
| Lock taken | Kvotar runs and the app window opens | Kvotar runs; the app window does not open |
| Another Kvotar holds Kvotar's lock | Nothing from this copy: it hands off and quits, and the running copy opens its app window | Nothing: this copy quits without a hand-off |
| AgentPilot holds the AgentPilot lock | The conflict window | The conflict window |
| Kvotar's lock file cannot be opened or written | Handled as "another Kvotar": a hand-off and a quit. With no other copy running nobody answers, so the user sees nothing and Kvotar is not running | This copy quits silently; Kvotar is not running |
| The AgentPilot lock file cannot be opened or written | The conflict window, naming AgentPilot even if it is not running | The same |
| The support folder cannot be found or created | Kvotar runs with neither lock (an error in the log), so even a running AgentPilot is not noticed | The same |

The Kvotar lock-file row and the support-folder row are ruled to change: see
[storage Decided 1 and 2](storage.md#decided) and their [Known-gaps rows](storage.md#known-gaps).
The AgentPilot lock-file row is covered by storage's Known-gaps row for a lock-file failure, not by
a Decided entry.

## Opened by the user or at login

`LaunchSource.decide` reads three things from the launch Apple event: its class, its id and its
`'prdt'` parameter.

- **An open-application event (`aevt`/`oapp`) without `'prdt'` = `lgit`** is a deliberate launch:
  the app window opens (`.showWindow`).
- **`'prdt'` = `lgit`** ("launched as a login item", sent by macOS's login window) is a login
  launch: nothing opens (`.stayQuiet`).
- **No launch event, or any other event** (a reopen arrives as `rapp`): nothing opens. Reason:
  silence is the safe failure; a window nobody asked for is worse than one nobody got. A reopen has
  its own path below and must not be answered twice.

(`App/LaunchSource.swift`; `testLaunchAtLoginStaysQuiet`, `testDeliberateLaunchShowsTheWindow`,
`testNoLaunchEventStaysQuiet`, `testAReopenEventIsNotAColdLaunch`,
`testFourCharCodesDecodeToTheirCharacters`)

**A login launch stays silent.** It opens no app window, and a second copy started at login hands
off nothing. Reason: a window appearing by itself at every sign-in would interrupt a working app,
and this silence is what the rest of the recovery design rests on. It does not silence the rest
of the app: quota notifications still arrive, an already-onboarded install still makes its one
notification-permission request when a tool is first detected, and the updater starts as on any
launch (what it shows is [updates and releases](updates-and-releases.md)'s). Among the windows and notices this
page owns, three can still appear after a login launch, each for its own reason:

- the AgentPilot conflict window (below), because that state is unusable, not merely unread;
- the first-run window, when it is still owed ([first-run window](first-run-window.md#when-it-opens));
- the hidden-item notice, when the item is confirmed hidden early in the launch (below).

Whether Kvotar is registered as a login item is macOS's `SMAppService` state; the switches for it
are the first-run window's checkbox
([first-run window](first-run-window.md#screen-5--what-kvotar-never-sees-onboardingprivacyscreen))
and the **Open at Login** menu item ([menu actions](menu-actions.md)).

## Opening Kvotar again while it runs

Opening Kvotar while it already runs is the one thing a person does when the menu-bar item is not
where they expected it. So every way of opening it again shows the **app window**, never the
popover: the popover hangs from the menu-bar item, which may be exactly what the user cannot find.

- **Reopen.** `applicationShouldHandleReopen` opens the app window and returns `false`, so AppKit
  does nothing more. It does this **whatever `hasVisibleWindows` says**. Reason: an open History
  window makes that flag true, and an open History window is not the user having found their quota.
- **A second copy.** When the open starts a second process instead (for example a different copy
  of the app), the second copy hands off and the running copy opens its app window (next section).
  The user sees Kvotar and never learns there were two.

The running copy shows the window with nothing that names which copy it is. Reason: one install
is the case to design for; **About Kvotar** names the version, and the hand-off is in the log.

## A second copy

A copy refused by a lock does what `SecondInstanceAction.decide` says, from which lock refused and
its own launch source:

| Refused by | Deliberate launch | Login launch |
|---|---|---|
| Kvotar's lock (another Kvotar) | `handOffAndQuit` | `quitSilently` |
| The AgentPilot lock | `showConflict` | `showConflict` |

(`App/SecondInstanceAction.swift`; `testDeliberateKvotarCollisionHandsOff`,
`testLoginLaunchedKvotarCollisionPostsNothing`, `testLegacyConflictIsShownWhateverTheLaunch`,
`testNoLoginLaunchEverHandsOff`)

- **No login launch ever hands off.** That is the one pairing that must never exist.
- **A second copy draws no menu-bar item of its own.** Reason: on a full menu bar that added a
  second invisible icon and showed nothing, exactly when the user had just tried to open Kvotar.
- **A refusal by a live holder is logged** at `CRITICAL` with the PID found in the lock file
  (`PIDLock`); the hand-off and the silent quit each add an `INFO` line.

### The hand-off

- **The request is a payload-less Darwin notification**, `QuotaHandoff.darwinNotificationName`.
  It carries a request, not data. Its name differs from the debug and capture notifications, which
  only ask for a settings row to be re-read. (`Packages/KvotarCore/Sources/KvotarCore/Lifecycle/QuotaHandoff.swift`;
  `testAllThreeDarwinNamesAreDistinct`)
- **The second copy stops listening before it posts**, or it would hand off to itself. Then it
  quits one run-loop turn later, so the post is on its way first. (`postHandoff`,
  `quitSecondInstance`)
- **The running copy answers with the app window.** A request that arrives before the popover and
  the app window exist is held and answered the moment they do. Several held requests open one
  window, once; every later request opens it again. (`App/HandoffInbox.swift`;
  `testRequestBeforeWiringIsHeldAndDrainedOnAttach`, `testRequestAfterWiringIsForwardedImmediately`,
  `testHeldRequestDrainsOnce`, `testEveryLaterRequestStillOpens`)

### The AgentPilot conflict window

Kvotar used to be called AgentPilot. When AgentPilot holds its lock there is no Kvotar to hand off
to, so this copy shows a window and does nothing else. This stays (maintainer's ruling).

- **A window, not a popover**, titled `Kvotar`, centred, shown one run-loop turn after launch.
  Reason: a surface hanging off the menu-bar item is unreachable exactly when it is needed.
  (`presentConflictWindow`)
- **No close button.** Its one button, **Quit this instance**, quits. Reason: a closable window
  would leave a process that does nothing and shows nothing.
- **Today's copy** is `AlreadyRunningView.Conflict.legacyAgentPilot.message`:
  *"AgentPilot is already running. Quit it before starting Kvotar. Only one app polls at a time."*
  It names the app the user has to quit. It is plain ASCII on one line, because the release
  build's old-name check reads it back from the built app verbatim
  (`testLegacySentenceStaysReadableToTheReleaseAudit`,
  `testLegacyConflictNamesAgentPilotAndSaysToQuitIt`).
- **A Mac that never ran AgentPilot never sees its name:** the AgentPilot lock is taken only when
  AgentPilot's folder exists ([storage](storage.md#the-single-instance-lock)).
- **The other case's copy is never shown.** `Conflict.kvotarInstance.message`, *"Kvotar is already
  running. Only one instance polls at a time."*, is unreachable, because a second Kvotar hands off
  or quits silently (`testSecondKvotarNamesOnlyKvotar` pins it). The word "polls" in both strings is a
  [polling Known gap](polling.md#known-gaps); it is not repeated here.

## When the app window opens and closes

The app window shows exactly what the popover shows, from the same view and view model; its content
is [popover](popover.md)'s. This section owns when it appears.

| Trigger | Surface |
|---|---|
| Deliberate launch | App window, always |
| Reopen, or a hand-off from a second copy | App window, always |
| The hidden-item notice, clicked | App window, always |
| **Open in Window** in the right-click or `⋯` menu ([menu actions](menu-actions.md)) | App window, always |
| Left-click on the menu-bar item | Popover, toggled. The user has plainly found the item |
| A quota notification's **Open Kvotar**, the first-run window's **Open Kvotar**, **Set up …** | The app window when it is already open or the item is known hidden; the popover otherwise |
| Login launch | Nothing |

(`App/QuotaSurfacePresenter.swift`: `present`, `presentWindow`, `togglePopover`;
`testPresentTakesThePopoverWhileTheWindowIsClosed`, `testPresentTakesTheWindowWhenTheWindowIsOpen`,
`testAKnownHiddenItemRoutesToTheWindow`, `testPresentWindowAlwaysTakesTheWindow`,
`testTogglePopoverOpensThenCloses`, `testTheDestinationIsCarriedThrough`)

- **Five ways in name the app window:** a deliberate launch, a reopen, a hand-off, **Open in
  Window** and the hidden-item notice (`presentWindow`). Every other way in names a destination
  (the default tab or a setup card) and the presenter picks the surface (`present`). Reason: paths
  that opened the popover by name sent a user who could not find the item straight back to it. The
  first three answer someone who opened the app, not the item; the notice opens the window by name
  because its reader is being told the item may be gone, and the answer must not depend on a
  second reading of the same signal.
- **The popover and the app window never show together.** Opening one closes the other first,
  and the close-side cleanup runs before the other opens. Reason: a late cleanup would erase the
  "since you last looked" line the new surface had just worked out. (`QuotaSurfaceLifecycle`; `testOpeningOneSurfaceClosesTheOtherFirst`,
  `testSwitchingToTheWindowKeepsItsBoundaryLineAcrossALateClose`,
  `testReopeningOntoTheSamePopoverKeepsItsBoundaryLine`, `testAGenuineCloseStillClearsTheLine`,
  `testAUserInitiatedCloseAfterASwitchStillClearsTheLine`)
- **Both run the same open and close steps**, so an open in the window is recorded as an open,
  like the popover's, and a setup card on either records no open. (`QuotaSurfaceLifecycle.willOpen`,
  `didOpen`, `didClose`; `testASetupCardFiresNoOpenHookAndStartsNoFreshnessTimer`)
- **One window per process,** created on first open. Each open restores it from the Dock if it was
  minimised, brings Kvotar forward and makes the window key. (`QuotaWindowController.open`)
- **Chrome:** titled `Kvotar`; closable and minimisable, not resizable; the popover's 340 pt width;
  centred on first open, then its frame is remembered. Its height is capped from its own screen, so
  a tall state on a short display still fits. A `⋯` button in the title bar opens the right-click
  menu, built by the same code (`buildMenu`). (`makeWindow`, `measureHeightBudget`)
- **No Dock icon.** Kvotar stays a menu-bar app (`LSUIElement`, accessory). Reason: a Dock icon
  and app menu would appear and disappear with the window. So ⌘Q and ⌘W are attached to the
  window by hand. (`installKeyMonitor`)
- **Closing:** the close button or ⌘W closes it; the presenter closes it when it opens the
  popover; History's footer link closes it before History opens. **Esc never closes it**: Esc
  releases a pinned hover card or the verdict anatomy and otherwise does nothing. Reason: an Esc
  that closed it would fire the moment a reader dismissed a hover card. (`closeNow`,
  `windowWillClose`, `closeActiveSurface`; `testCloseActiveSurfaceClosesWhicheverIsUp`)
- **Closing the window hides a surface.** Polling continues and the menu-bar item keeps updating.

## The hidden menu-bar item

On a full menu bar macOS draws a menu-bar item under the notch or not at all. Kvotar cannot prevent
that. It detects it, so that every routed way in lands on the app window, and tells the user once,
early in the launch. It never resizes, moves or otherwise acts on the item.

### Detection

**The signal is the menu-bar item's own window reporting itself occluded.** Five gates turn that
signal into a claim. An item is *confirmed hidden* only when all of them pass, in this order. This
list is the order `verdict` checks them; the code's doc comment numbers them in the order they were
added, so its "gate 3" is the sustain below:

1. **The screen is not away.** A sleeping display, a locked session or a switched-away user makes
   the window report occluded without moving. The screen state is read at start, since a launch
   can begin with a dark or locked screen, and kept current from the sleep, wake, lock, unlock
   and session notifications. A reading taken while the screen is away never counts as placed.
2. **macOS has placed the item.** For the first second or so of every launch the window sits
   parked below the screen's bottom edge and reports occluded. Once placed, it stays placed.
3. **The item is still in the menu bar.** With the menu bar set to hide automatically, the window
   rides up off the top of the screen. **An auto-hidden menu bar is never a hidden item.**
4. **The menu bar itself is not put away.** In full screen no app's menu-bar item is on screen.
   Kvotar counts the status-item-level windows on screen, and only that number: no owner, name or
   content, and no permission needed. Zero means the bar is away; an unreadable list does not.
5. **It holds for 5 seconds** (`confirmSeconds`), timed from the first hidden reading. When the
   wait ends, the gates are checked again against the **current** reading, never the one that
   started the wait. Reason: the bar reshuffles while other apps take their slots; this filters
   that without making the notice late. It says the reading is stable, not why.

(`App/HiddenItemDetection.swift`: `verdict`, `Tracker`; `App/HiddenItemMonitor.swift`)

**When it is checked:** on the item window's occlusion change and move, a display change, a Space
change (the exit from full screen), and every screen sleep, wake, lock, unlock or user switch, plus once at
start. Occlusion changes alone are not enough: an item occluded from before placement never
changes state again, so the moment it becomes eligible would pass unseen.

**How a confirmation behaves:**

- **It is live.** It routes the presenter while it stands and clears on the first reading that is
  not hidden (on screen, an auto-hidden bar, or the screen away). A menu bar put away is the one
  exception (below). A user who frees a menu-bar slot gets the popover back.
  (`testAConfirmationClearsWhenTheItemReturns`)
- **A screen going away cancels a pending wait and clears a confirmation;** when the screen comes
  back, a still-hidden item is confirmed again. (`testAScreenThatGoesAwayDuringTheWaitConfirmsNothing`,
  `testAConfirmationClearsWhenTheScreenGoesAway`, `testAHiddenItemIsReconfirmedSilentlyWhenTheScreenComesBack`)
- **A menu bar put away cancels a pending wait, never starts one, and holds a confirmation that
  already stands.** Reason: people click notifications over a full-screen app, and a user whose
  item is really hidden must keep landing in the app window.
  (`testABarAwayReadingNeverArms`, `testAStandingConfirmationHoldsWhileTheBarIsAway`,
  `testAnItemHiddenUnderABarThatWasAwayIsConfirmedWhenTheBarReturns`)
- **A run of hidden readings does not restart the wait.** (`testRepeatedHiddenReadingsDoNotRearmTheWait`)

**Rejected signals:** the item's own `isVisible` never changes. The item's position against the
notch area never raised a false alarm but missed about one hidden reading in five, because macOS
keeps a margin at the notch. The system presentation options read nothing for a menu-bar app.

### The notice

> **Kvotar is running**
> Its menu bar item may be hidden. Open Kvotar to see your quota.

(`UserNotificationPresenter.hiddenItemNoticeTitle`, `hiddenItemNoticeBody`;
`testTheHiddenItemNoticeSaysMayBeHidden`)

- **At most once per launch** (`noticePerLaunch` = 1), counted in memory and stored nowhere.
  Reason: it is a recovery hint, not a monitor; twice is nagging about something the user may
  have chosen to live with. (`testASecondConfirmationRoutesButDoesNotNoticeAgain`)
- **Only for a confirmation that lands within 60 seconds of launch** (`noticeWindowSeconds`, wall
  clock from the start of detection, inclusive). A later confirmation still routes and is never
  announced, and it spends no budget. Reason: the notice answers "I started Kvotar and nothing
  appeared"; a user hours into a session knows the app is running, and late confirmations were
  mostly a dark screen, a full-screen app or an open popover. This stays (maintainer's ruling).
  (`testAHiddenItemAtLaunchIsAnnounced`, `testTheNoticeWindowIsInclusiveAtItsEdge`,
  `testAConfirmationLongAfterLaunchIsNeverAnnounced`, `testALateConfirmationSpendsNoBudget`,
  `testTheConstantsAreTheSpecsNumbers`)
- **"May be hidden", not "is hidden".** Detection was measured on one notched Mac with a single
  built-in display (`presentHiddenItemNotice`'s comment), and the gates infer a cause they cannot prove. The copy names a symptom the
  reader can check at a glance, and no mechanism.
- **Not an engine event.** It is posted directly, never through the notification engine: no
  arbitration, priority, cap or cooldown, and no `notification_events` row. It cannot displace a
  quota notification or be displaced by one. It has its own identifier and its own marker instead
  of a tool and event pair, so acknowledging it never touches a quota notice. It belongs to none
  of the four **Notify me** groups and has no switch, and it plays no sound. Reason: quota
  notifications are claims about quota; this is a claim about the app, and a user cannot opt out
  of being told where their app went. (`presentHiddenItemNotice`;
  `testTheHiddenItemNoticeIsNotAnEngineEvent`) [notifications](notifications.md) links here.
- **Clicking it opens the app window**, by name (`onOpenWindow`).
- **If macOS does not allow Kvotar's notifications, the user gets nothing,** and that is settled.
  A deliberate launch already opens the app window. The user who is left out arrives by a login
  launch with notifications off; opening a window at every sign-in was rejected because it breaks
  the silent login. Their way back is to open Kvotar again, which the first-run window's screen 3
  teaches.

## Quit

Quit comes from **Quit Kvotar** in the right-click or `⋯` menu ([menu actions](menu-actions.md)), ⌘Q on
the app window, or **Quit this instance** in the conflict window. All call `NSApp.terminate`.
`applicationWillTerminate` then:

1. **Writes the `quit` row** when there is a database, waiting at most 2 seconds. The write runs
   off the main thread, because waiting on the main thread for main-thread work deadlocks and
   loses the row.
2. **Removes its observers:** wake, sleep, time zone and clock, the debug and capture
   notifications, and the hand-off.
3. **Stops the poll coordinator**, which ends the poll loops and background jobs and stops the
   `codex app-server` child process so it does not outlive the app (`PollCoordinator.stop`), and
   cancels the capture expiry timer ([diagnostics](diagnostics.md)).
4. **Releases both locks.** How release works is on [storage](storage.md#the-single-instance-lock).

A copy that lost the lock runs the same method with nothing to release: no database, no
coordinator, no lock.

## Rejected alternatives

- **A second copy that shows its own "already running" popover** on a new menu-bar item. On a full
  menu bar it was a second invisible icon.
- **A window at every login launch,** including for a user with notifications off. It breaks the
  silent login the design rests on.
- **Telling the user which copy they are looking at after a hand-off** (for example a version line
  in the app window). It costs every user a line to serve someone running two builds.
- **A Dock icon while the app window is open** (switching to a regular app). A Dock icon and app
  menu would come and go with the window.
- **Esc closing the app window.** It would fire when a reader dismisses a hover card.
- **Shrinking the menu-bar item to make it fit.** It cannot promise access: on a full enough bar
  even a narrow item lands under the notch, and a naive shrink and restore flaps.
- **Detecting the hidden item from its position against the notch**, from `isVisible`, or a full
  screen from the presentation options. See *Detection*.
- **A notice later in a session, or more than one.** See *The notice*.

## Known gaps

| Gap | Today | Proposed |
|---|---|---|
| A reopen does not bring the conflict window forward | In a copy showing the AgentPilot conflict window there is no presenter, so `applicationShouldHandleReopen` logs the reopen and does nothing; the conflict window may stay behind other windows | On reopen, when `conflictWindow` exists, bring Kvotar and that window forward |
| Detection untested on other displays | Measured on one notched Mac with a single built-in display; external displays and menu bars without a notch are untested (`presentHiddenItemNotice`'s comment). The notice copy hedges for this | Re-measure if a report shows the notice with the item plainly visible |
| Stale code comments and log text | `AppDelegate`'s type comment says a second instance shows the "already running" popover; `AlreadyRunningView`'s comment calls it a popover; `UserNotificationPresenter.onOpen` says it opens the popover (it opens the routed surface); `presentHiddenItemNotice` says the once-per-launch cap lives in `AppDelegate` (it is `HiddenItemDetection.Tracker`), and `postHiddenItemNotice` names `hiddenItemNoticePerLaunch` (the constant is `noticePerLaunch`); comments in `LaunchSource`, `QuotaWindowController`, `MenuBarController`, `QuotaHandoff` and `AppDelegate`, and the reopen and hand-off `INFO` log lines in `AppDelegate`, give the app window the old name that this page reserves for the refill period | Fix with the next change to each file; the log lines say "app window" |

The lock-file and missing-folder outcomes are [storage](storage.md#known-gaps)'s rows. The polling
word in the conflict copy, and the unreachable "another Kvotar" string, are a
[polling](polling.md#known-gaps) row.

## Code and test pointers

- Launch, reopen, quit, the second-copy actions and the conflict window: `App/AppDelegate.swift`
  (`applicationDidFinishLaunching`, `resolveLaunchSource`, `applyLaunchSource`,
  `applicationShouldHandleReopen`, `applicationWillTerminate`, `actOnSecondInstance`,
  `postHandoff`, `quitSecondInstance`, `presentConflictWindow`, `registerHandoffObserver`,
  `postHiddenItemNotice`).
- Rules: `App/LaunchSource.swift`, `App/SecondInstanceAction.swift`, `App/HandoffInbox.swift`,
  `App/HiddenItemDetection.swift`;
  `Packages/KvotarCore/Sources/KvotarCore/Lifecycle/QuotaHandoff.swift`.
- Surfaces: `App/QuotaSurfacePresenter.swift`, `App/QuotaSurfaceLifecycle.swift`,
  `App/QuotaWindowController.swift`; the popover side in `App/MenuBarController.swift`, which also
  owns `HiddenItemMonitor` (`App/HiddenItemMonitor.swift`).
- Copy: `Packages/KvotarUI/Sources/KvotarUI/Views/AlreadyRunningView.swift`; the notice in
  `App/UserNotificationPresenter.swift`.
- The lock: `Packages/KvotarCore/Sources/KvotarCore/Lifecycle/PIDLock.swift`
  ([storage](storage.md#the-single-instance-lock)).
- Tests: `AppTests/LaunchSourceTests.swift`, `AppTests/SecondInstanceActionTests.swift`,
  `AppTests/HandoffInboxTests.swift`, `AppTests/HiddenItemDetectionTests.swift`,
  `AppTests/QuotaSurfacePresenterTests.swift`, the hidden-item tests in
  `AppTests/UserNotificationPresenterTests.swift`;
  `Packages/KvotarUI/Tests/KvotarUITests/AlreadyRunningViewTests.swift`;
  `testAllThreeDarwinNamesAreDistinct` in
  `Packages/KvotarCore/Tests/KvotarCoreTests/DiagnosticsCaptureFlagTests.swift`; `PIDLockTests`.
