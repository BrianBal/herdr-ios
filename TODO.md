# TODO

Most valuable first.

## Quick but important

- [ ] **Git repo**: put the project in git and push it to GitHub (`BrianBal/herdr-ios`).
- [ ] **Test the untried push paths on the phone**:
  - [ ] Notification buttons: **Choose 1/2/3** on a blocked agent, **Reply** on a finished one.
  - [ ] Live Activity started by the gateway (push-to-start) while the app is closed.
  - [ ] Agents widget refreshed by widget push (check the gateway log for a rejected topic).

## Reading on the phone

- [ ] **Reflow agent prose**: agents hard-wrap replies at the Mac's pane width, and the phone wraps them again, so long answers look ragged. Rejoin wrapped paragraphs for display, the way the message copy button already does (`TerminalSegmenter.messageText`).
- [ ] **Scrollback**: show more than the visible screen; pull up for earlier output (`pane.read` with `source: recent` / `lines`).

## Doing more from the phone

- [ ] **Start an agent**: "New workspace → start Claude here", plus new tab / split (`agent.start`, `tab.create`, `pane.split`).
- [ ] **Quick prompts**: saved prompts and agent commands (`/compact`, "continue", "run the tests") as one-tap chips above the composer.

## Reliability

- [ ] **Keep the Mac awake while agents work**: the gateway holds a `caffeinate` assertion only while something is working or blocked.
- [ ] **TestFlight build**: no dependence on Xcode development signing or the cable; production APNs environment.
