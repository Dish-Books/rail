---
name: record-demo-video
description: Record a narrated video of a feature running in the local dev app, for a PR, a Linear issue, or a stakeholder. Drives a headless Chrome over the DevTools Protocol so clicks and keystrokes are real, captures frames, and encodes an mp4 with no extra tooling installed. Use when the user asks to "record a video", "make a demo", "show this working", or wants a screen recording of a change.
---

# Record a Demo Video

Produce a short video of a feature working in the running dev app: real page, real LiveView, real
response times. Not a mockup and not a reenactment, because a demo that does not actually exercise the
code is worse than no demo.

Pipeline: **headless Chrome driven over CDP** → **one PNG per frame on a timer** → **mp4 via ffmpeg on
Linux, AVFoundation on macOS**. Everything needed is already on this machine.

## Why CDP and not the Browser pane

The in-app Browser pane (`mcp__Claude_Browser__*`) is fine for *looking* at a page, but it cannot drive
this reliably:

- Its synthetic clicks do not always fire `phx-click`. When the pane is hidden, a click can land as a
  focus with no submit, and `element.click()` / `new Event('input')` from `javascript_tool` races
  LiveView's re-render and silently no-ops.
- It has no way to write frames to disk, so there is nothing to encode.

CDP's `Input.dispatchMouseEvent` / `Input.dispatchKeyEvent` produce **trusted** events, so LiveView
reacts exactly as it does for a real user, and `Page.captureScreenshot` gives frames as files.

## What is available (checked, so do not re-litigate)

- **No** ImageMagick, chromedriver, playwright, or puppeteer. Do not install any: the pipeline below
  needs none of them, and installing tooling on the user's machine needs their say-so.
- **Node** has a global `WebSocket`, so CDP needs zero dependencies.
- **An encoder, either way.** [scripts/encode.sh](scripts/encode.sh) uses ffmpeg where it exists (the
  usual case on Linux) and falls back to Swift + AVFoundation via
  [scripts/encode.swift](scripts/encode.swift), so a stock macOS with no ffmpeg still encodes.
- **Chrome or Chromium**, found by [scripts/platform.sh](scripts/platform.sh): `google-chrome` /
  `chromium` on the `PATH`, then `/Applications/Google Chrome.app` on macOS. Set `CHROME_BIN` to
  override. Always launch it with a scratch `--user-data-dir`, never the user's real profile.

## Steps

### 0. Inline, or in a subagent?

Three or four takes, each read frame by frame, and only the final mp4 matters. **Ask the user once, in
one line**, unless they already said or the Agent tool is missing.

In an Antigravity / Gemini subagent: call `invoke_subagent` with `TypeName: "self"` and
`Role: "<TICKET_ID> Demo Video Producer"`. Give it the worktree path, the Linear issue ID, two sentences
on what to demo, the scratchpad path, and the instruction to follow this skill (the dev server must already
be up, and dev data is real). Inspect frames using `view_file`. It uploads the video to Linear via MCP,
appends the demo video section to the GitHub PR description via `gh pr edit`, marks the PR ready for
review (`gh pr ready`), stops the dev server, and pushes any receipt verification. It returns the mp4 path,
the frames directory, one line on what the video shows, the `expect`/`refute` results, and the Linear `assetUrl`.

### 1. Get the dev app running and seeded

The dev server must already be up. Each worktree has its own port block from
`scripts/setup-worktree.sh`, so read `PORT` from `.env` rather than assuming 4000 (`record.sh` does
this for you).

Seed whatever the demo needs, and **write a reset script** that puts the data back to the starting
state. Recording is iterative: expect three or four takes, and every take must start from the same
place. Prefer a direct `Repo.update_all` / `Repo.insert!` for setup so it writes no audit rows and does
not pollute what the demo is about to show.

Match the ticket's worked example if it has one. A demo whose numbers match the ticket is much easier
to review against.

### 2. Write the scenario

Copy [scripts/example-scenario.mjs](scripts/example-scenario.mjs) into the scratchpad and rewrite the
steps. It is plain JS against the session returned by
[scripts/driver.mjs](scripts/driver.mjs):

| call | what it does |
| --- | --- |
| `demo.login(url)` / `demo.goto(path)` | authenticate and navigate, before recording starts |
| `demo.startCapture()` | begin the frame timer |
| `demo.step(text, ms)` | set the caption and hold, so there is time to read it |
| `demo.click(jsExpression)` | trusted click at the element's center (`{at: 'left'}` for a date field) |
| `demo.type(text)` / `demo.typeDate(sel, digits, expected)` | real keystrokes |
| `demo.upload(sel, paths)` | hand a LiveView upload real files, asserting the entry registered |
| `demo.expect(js, desc)` / `demo.refute(js, desc)` | assert the state the narration claims |
| `demo.finish()` | stop capturing, return the frame count |

Selectors are JS evaluated in the page, so when nothing stable identifies an element, find it by text:
`[...document.querySelectorAll('button')].find(b => b.textContent.includes('Save'))`.

**Assert what you narrate.** Every claim the captions make should have an `expect` / `refute` behind
it, so a bad take fails loudly instead of producing a confident, wrong video. On the DIS-903 demo those
assertions caught two real driving bugs before the final take.

### 3. Record and encode

```bash
.claude/skills/record-demo-video/scripts/record.sh <scenario.mjs> <output.mp4> [email]
```

It launches its own Chrome, mints a magic login link, runs the scenario, encodes, and kills Chrome on
exit. `DEMO_FPS` (default 8) and `DEMO_FRAME_DIR` override the defaults.

Pass the output as a **bare filename** and it lands in the video directory: `qa_videos` beside the
worktrees (`DEMO_VIDEO_DIR` overrides it, in the environment or in `.env`). That keeps videos out of
every worktree, so they survive [post-merge-cleanup](../post-merge-cleanup/SKILL.md) and cannot be
committed by accident. A path with a slash in it is used exactly as given.

The frames survive the run (`FRAMES_KEPT` names the directory), so if only the encode failed, re-run
`scripts/encode.sh <frame-dir> <out.mp4> <fps>` instead of recording another take.

The frame timer runs at ~120ms, which lands near **8fps**, so encoding at 8 plays back at real speed.
If you change `frameIntervalMs`, change the fps to match or the video will run fast or slow.

### 4. Check the frames before believing the video

Read a few frames with the Read tool: the opening state, each moment a caption makes a claim, and the
final state. They are PNGs, so you can see them directly. This is also how you catch styling bugs the
tests cannot: the DIS-903 recording is what surfaced a form error rendering white and indented instead
of red and flush left, because the shared input component was using class names that did not exist.

Then confirm the side effects landed in the database (the row changed, the audit entry was written).
The video shows the UI; only a query proves the write.

### 5. Deliver it

The mp4 is already somewhere durable if it went to the video directory above; tell the user the path.
`SendUserFile` with `display: "render"` where that is available.

**Do not commit the mp4** and do not add it to the repo. Keep the frames and the scenario in the
scratchpad.

## Publishing the video

**GitHub cannot attach video through the API.** There is no REST endpoint for issue or PR attachments,
and `gh` cannot upload media. The `github.com/user-attachments/assets/...` URLs that render as an inline
player are minted only by the web upload. Say that plainly instead of trying to work around it.

Do **not** work around it by committing the mp4 to the repo, pushing it to an orphan branch, or
uploading it to the app's R2 attachments bucket. The first two bloat the git object store permanently,
and R2 is customer attachment storage, not a place for build artifacts.

### Default: attach to the Linear issue, link from the PR

This is API-native, adds nothing to the repo, and the PR already links the Linear issue through the
branch name, so a reviewer is one click away.

1. `prepare_attachment_upload` with the issue id, filename, `video/mp4`, and the **exact** byte size.
2. `PUT` the raw bytes to `uploadRequest.url`. Send every header in `uploadRequest.headers` verbatim,
   casing included, or it returns 403. The signed URL expires in 60 seconds, so do not prepare the
   upload until the file is ready to send.
3. `create_attachment_from_upload` with the returned `assetUrl` to create the attachment row.
4. **Add the demo link to the GitHub PR description via CLI**:
   Fetch the existing PR body and append the `## Demo Video` section:
   ```bash
   body=$(gh pr view <pr_number> --json body -q .body)
   gh pr edit <pr_number> --body "$body

   ## Demo Video
   [Watch the demo](<assetUrl>) - <one-line description of the feature working>. Also attached to [<TICKET_ID>](https://linear.app/dishbooks/issue/<TICKET_ID>)."
   gh pr ready <pr_number>
   ```

Use `curl --data-binary @file.mp4`. Never base64 the file or pass it through model-visible text.

**A link works; an embed does not.** Clicking a markdown link navigates the reviewer's browser straight
to the asset with their Linear session cookies attached, so the whole team can watch it. Do not try
`![](assetUrl)` or a `<video src>` tag: GitHub proxies images through camo, which is unauthenticated and
will 403 on a Linear asset, and it ignores `<video>` from arbitrary sources. The result is a broken
image where a working link would have been.

Say in the PR that the link needs Linear access, since it is auth-gated to the workspace and will not
open for anyone outside it.

### Optional: inline in the PR, by hand

If the user wants the video playing inline in the PR description, that requires them to drag the file
into the GitHub web editor. **Offer it, do not assume it** — it is manual work for them, and the Linear
attachment is usually enough. If they want it, hand them the absolute file path, keep the PR in draft
until they have done it, and let them paste the resulting `user-attachments` URL back if you need to
reference it.

## Gotchas that cost real time

- **Never type a password.** Authenticate with a magic link
  ([scripts/login_link.exs](scripts/login_link.exs)); `record.sh` handles it. The confirmation screen
  ("Keep me logged in on this device") needs a click, but the Chrome profile persists between runs, so
  that step must be conditional or the second run fails on a missing button.
- **`DOM.setFileInputFiles` does not drive a LiveView upload.** It puts the files on the input, but
  LiveView only learns about files through its own `track-uploads` window event, so no entry ref is
  allocated and the upload silently does not exist - indistinguishable from a broken feature. Use
  `upload`, which dispatches that event with real `File` objects and fails loudly if no ref appears.
  It works on the `class="hidden"` inputs the app styles its upload buttons with.
- **Date inputs keep segment focus.** Typing a second date into the same field continues in whichever
  segment was last edited, so the digits pile into the year and overflow it (`07/31/275760`). Walk back
  with three `ArrowLeft` presses first. `typeDate` does this and asserts the resulting value.
- **A caption is not app UI.** Style narration as an obvious overlay bar. Never let it be mistaken for
  something the app renders.
- **Screenshots can land mid-navigation.** The capture loop swallows those; do not make it fatal.
- **Kill Chrome when done**, and stop any dev server you started that the user did not ask for.
- Dev data you mutate while recording is real. Tell the user what state you left behind.
