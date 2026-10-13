# TODO

Most valuable first.

## Quick but important

- [x] **Git repo**: in git and on GitHub at [BrianBal/herdr-ios](https://github.com/BrianBal/herdr-ios).
- [ ] **Test the untried push paths on the phone**:
  - [ ] Notification buttons: **Choose 1/2/3** on a blocked agent, **Reply** on a finished one.
  - [x] Live Activity started by the gateway (push-to-start): the log shows a push start at 03:30 on 10/12, after which the phone registered the new activity's token on its own.
  - [x] Agents widget refreshed by widget push: the phone registered a widget token and Apple hasn't rejected any widget push (failures are logged).

## Reading on the phone

- [x] **Reflow agent prose**: agents hard-wrap replies at the Mac's pane width, and the phone wraps them again, so long answers look ragged. Rejoin wrapped paragraphs for display, the way the message copy button already does (`TerminalSegmenter.messageText`). Done: `TerminalSegmenter.reflowed`.
  - [x] Hanging indents: agent prose is laid out a line at a time with its indent/marker beside it, so wrapped list items line up under their text. (Text selection now works within a line rather than across a whole message; the copy buttons still copy everything.)
- [x] **Scrollback**: "Load earlier output" (or pull down at the top) loads history above a Live divider; "Load more" doubles it, up to 16k lines. Shells get colored scrollback (`pane.read`); agents get their transcript as plain text (`agent.read`).
  - [x] Claude Code panes: earlier output comes from Claude's session transcript (`gw.claude_transcript`: found by the pane's folder and title, rendered like Claude's screen with Markdown styled).

## Doing more from the phone

- [x] **Start an agent**: New Workspace has an Agent picker (installed agents, via `gw.agent_kinds`) and an optional first prompt, sent once the agent is ready; shell panes get a ✨ "Start in this pane" menu.
  - [x] New tab / split / close from the phone: the ⊞ pane menu in a workspace (also holds "Start in this pane").
- [x] **Quick prompts**: one-tap chips above the composer (separate lists for agents and shells); "+ Save" turns the typed text into a chip; long-press to edit or remove; Settings → Quick prompts to reorder or reset.

- [x] **More than one gateway**: Settings → Gateways lists them (add, rename, change URL/token, remove); the home title switches between them. One is connected at a time; all of them notify, and a notification opens on the gateway that sent it (`gateway_id` in the push).
  - [ ] Install the gateway on the Linux agent box and pair it.

- [x] **Shell completion**: shell panes show tab completions for the word being typed as the first chips (`gw.complete`); the field no longer autocorrects or turns "--" into "—" and quotes into curly ones.
- [x] **Photos for agents**: the photo button in an agent's composer attaches up to 4 photos (library or camera). The gateway saves each on its machine (`gw.upload`, private, deleted after a day) and the prompt carries the paths; Claude Code attaches them as images.

## Reliability

- [x] **Keep the Mac awake while agents work**: the gateway holds `caffeinate -is` while any agent is working or blocked, released 2 minutes after they're all quiet (`keep_awake` in config.toml). A lid closed on battery still sleeps.
- [ ] **TestFlight build**: no dependence on Xcode development signing or the cable; production APNs environment.
  - [x] Ready to ship: privacy manifests (app + widget), opaque app icon, shared build number, Release archive verified, `scripts/testflight.sh` (archive + upload) and `App/ExportOptions.plist`.
  - [ ] **You:** create the app record in App Store Connect (bundle ID `dev.bal.herdr.app`), then run `scripts/testflight.sh`. The first run creates the distribution certificate and profiles.
