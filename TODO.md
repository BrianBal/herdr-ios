# TODO

Most valuable first.

## Quick but important

- [x] **Git repo**: in git and on GitHub at [BrianBal/herdr-ios](https://github.com/BrianBal/herdr-ios).
- [ ] **Test the untried push paths on the phone**:
  - [ ] Notification buttons: **Choose 1/2/3** on a blocked agent, **Reply** on a finished one.
  - [ ] Live Activity started by the gateway (push-to-start) while the app is closed.
  - [ ] Agents widget refreshed by widget push (check the gateway log for a rejected topic).

## Reading on the phone

- [x] **Reflow agent prose**: agents hard-wrap replies at the Mac's pane width, and the phone wraps them again, so long answers look ragged. Rejoin wrapped paragraphs for display, the way the message copy button already does (`TerminalSegmenter.messageText`). Done: `TerminalSegmenter.reflowed`.
  - [ ] Follow-up: hanging indents, so a wrapped list item lines up under its text instead of column 0.
- [x] **Scrollback**: "Load earlier output" (or pull down at the top) loads history above a Live divider; "Load more" doubles it, up to 16k lines. Shells get colored scrollback (`pane.read`); agents get their transcript as plain text (`agent.read`).
  - [ ] Claude Code panes return only the screen (herdr can't recover its history); consider a fallback, e.g. reading Claude's session transcript file.

## Doing more from the phone

- [x] **Start an agent**: New Workspace has an Agent picker (installed agents, via `gw.agent_kinds`) and an optional first prompt, sent once the agent is ready; shell panes get a ✨ "Start in this pane" menu.
  - [ ] New tab / split from the phone (`tab.create`, `pane.split`).
- [ ] **Quick prompts**: saved prompts and agent commands (`/compact`, "continue", "run the tests") as one-tap chips above the composer.

## Reliability

- [ ] **Keep the Mac awake while agents work**: the gateway holds a `caffeinate` assertion only while something is working or blocked.
- [ ] **TestFlight build**: no dependence on Xcode development signing or the cable; production APNs environment.
