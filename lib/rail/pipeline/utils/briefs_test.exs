defmodule Rail.Pipeline.Utils.BriefsTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.Briefs

  describe "ticket_write_brief/1" do
    test "returns stopped message when task has no issue identifier" do
      assert ticket_write_brief([]) ==
               "This task has no Linear issue, so there is nowhere to write the ticket. Report that and stop: a target repository has to be set in Rail Settings before this stage can produce anything.\n"

      assert ticket_write_brief(identifier: nil) =~ "nowhere to write the ticket"
      assert ticket_write_brief(identifier: "") =~ "no Linear issue"
      assert ticket_write_brief(%{}) =~ "nowhere to write the ticket"
    end

    test "names the issue and the command that writes it without gh issue edit" do
      brief = ticket_write_brief(identifier: "RAIL-42")

      assert brief =~ "Linear issue RAIL-42"
      assert brief =~ "cat > $RAIL_SCRATCH/tickets/RAIL-42.md <<'TICKET'"
      assert brief =~ "# <the ticket title>"
      assert brief =~ "mkdir -p $RAIL_SCRATCH/tickets"
      assert brief =~ "cat > $RAIL_SCRATCH/tickets/split-1.md <<'TICKET'"
      assert brief =~ "Do not run `gh issue edit`"
      refute brief =~ "gh issue edit RAIL-42"
    end

    test "matches exact golden heredoc formatting for ticket write brief" do
      expected = """
      The ticket is Linear issue RAIL-101, and its body IS the ticket. Nothing you write in this reply reaches it - Rail captures it from $RAIL_SCRATCH/tickets/RAIL-101.md and updates the issue when your run completes cleanly.

      From your worktree, with the heredoc body and its closing TICKET line at column zero:

      mkdir -p $RAIL_SCRATCH/tickets
      cat > $RAIL_SCRATCH/tickets/RAIL-101.md <<'TICKET'
      # <the ticket title>

      <the whole ticket body, starting at the problem paragraph>
      TICKET

      Rules for that write:
      - A heredoc into $RAIL_SCRATCH/tickets/RAIL-101.md, never an inline string. A ticket is markdown full of quotes, backticks and blank lines, and only a file carries it cleanly.
      - The file replaces the ticket body: `# <the ticket title>` must be on the very first line, followed by the complete body with every section the finished ticket should have.
      - Rail reads $RAIL_SCRATCH/tickets/RAIL-101.md and updates Linear when your run completes cleanly. Do not run `gh issue edit` or any issue editing commands yourself.
      - An ask you split out is a new issue of its own, never a second ticket inside this one:

      mkdir -p $RAIL_SCRATCH/tickets
      cat > $RAIL_SCRATCH/tickets/split-1.md <<'TICKET'
      # <title>

      <the split ticket body>
      TICKET

      Name any issue you opened in your report.
      """

      assert ticket_write_brief(identifier: "RAIL-101") == expected
      assert ticket_write_brief(%{issue_identifier: "RAIL-101"}) == expected
      assert ticket_write_brief(%{"identifier" => "RAIL-101"}) == expected
    end
  end

  describe "plan_write_brief/1" do
    test "returns stopped message when task has no issue identifier" do
      assert plan_write_brief([]) ==
               "This task has no Linear issue, so there is nowhere to write the plan. Report that and stop: a target repository has to be set in Rail Settings before this stage can produce anything.\n"

      assert plan_write_brief(identifier: nil) =~ "nowhere to write the plan"
      assert plan_write_brief(identifier: "") =~ "no Linear issue"
    end

    test "names the file and does not tell the Architect to edit the issue" do
      brief = plan_write_brief(identifier: "30")

      assert brief =~ "$RAIL_SCRATCH/plans/30.md"
      assert brief =~ "The issue body is the ticket and is not yours to edit"
      assert brief =~ "mkdir -p $RAIL_SCRATCH/plans"
      assert brief =~ "cat > $RAIL_SCRATCH/plans/30.md <<'PLAN'"
      assert brief =~ "## Implementation plan"
      refute brief =~ "gh issue edit"
      refute brief =~ ".rail/knowledge/ticket-style.md"
    end

    test "matches exact golden heredoc formatting for plan write brief" do
      expected = """
      The plan is Rail's local working document, stored beside the task rather than on Linear. The issue body is the ticket and is not yours to edit.

      From your worktree, with the heredoc body and its closing PLAN line at column zero:

      mkdir -p $RAIL_SCRATCH/plans
      cat > $RAIL_SCRATCH/plans/RAIL-200.md <<'PLAN'
      ## Implementation plan

      <the implementation plan: Approach, File-level changes, Slices, Risks, Decisions for review>
      PLAN

      Rules for that write:
      - The issue body is the ticket and is not yours to edit.
      - A heredoc into $RAIL_SCRATCH/plans/RAIL-200.md, never an inline string. The plan is markdown full of quotes, backticks and blank lines, and Rail captures it from this file when your run completes cleanly.
      - Keep the `## Implementation plan` heading at the top of the plan.
      - An ask you split out is a new issue of its own, never a second ticket inside this one:

      mkdir -p $RAIL_SCRATCH/tickets
      cat > $RAIL_SCRATCH/tickets/split-1.md <<'TICKET'
      # <title>

      <the split ticket body>
      TICKET

      Name any issue you opened in your report.
      """

      assert plan_write_brief(identifier: "RAIL-200") == expected
      assert plan_write_brief(%{issue_number: "RAIL-200"}) == expected
    end
  end

  describe "product_brief/1" do
    test "matches golden product brief with ticket write brief embedded" do
      brief = product_brief(identifier: "RAIL-10")

      assert brief =~ "Turn this backlog idea into a ticket the Architect can plan from."
      assert brief =~ "Leave `## Implementation plan` to the Architect."
      assert brief =~ "cat > $RAIL_SCRATCH/tickets/RAIL-10.md <<'TICKET'"
      assert brief =~ "Findings, competitor comparisons and assumptions are your report to the human"
      assert brief =~ "A human reviews your ticket before anything is planned"
      assert brief =~ "The raw ask follows; quote it verbatim as the ticket's source, never reword it."
      refute brief =~ ".rail/knowledge"
    end

    test "matches golden product brief with no identifier" do
      brief = product_brief([])
      assert brief =~ "nowhere to write the ticket"
    end
  end

  describe "architect_brief/1" do
    test "uses plan_write_brief and points at plan file" do
      brief = architect_brief(identifier: "30")

      assert brief =~ "$RAIL_SCRATCH/plans/30.md"
      assert brief =~ "Plan the implementation of the ticket below."
      assert brief =~ "keeping the ticket's acceptance criteria as your contract."
      assert brief =~ "Stop at the plan - you do not write the code."
      refute brief =~ "gh issue edit"
      refute brief =~ "Write the ticket back unchanged"
    end

    test "includes design direction section when design is present" do
      design = %{
        canvas_url: "https://claude.ai/canvas/123",
        picked_key: "dir-1",
        directions: [
          %{
            key: "dir-1",
            title: "Direction One",
            notes: "Clean minimal layout",
            still_path: "$RAIL_SCRATCH/design/dir-1.png"
          }
        ]
      }

      brief = architect_brief(identifier: "RAIL-50", design: design)

      assert brief =~ "An approved design direction has been published for this ticket:"
      assert brief =~ "- Title: Direction One"
      assert brief =~ "- Notes: Clean minimal layout"
      assert brief =~ "- Canvas URL: https://claude.ai/canvas/123"
      assert brief =~ "- Still screenshot: $RAIL_SCRATCH/design/dir-1.png"
      assert brief =~ "Plan the implementation to match this design."
      assert brief =~ "$RAIL_SCRATCH/plans/RAIL-50.md"
    end
  end

  describe "architect_design_brief/1" do
    test "returns empty string when design is nil or empty" do
      assert architect_design_brief(nil) == ""
      assert architect_design_brief([]) == ""
      assert architect_design_brief(%{}) == ""
      assert architect_design_brief(design: nil) == ""
      assert architect_design_brief(%{"design" => nil}) == ""
    end

    test "returns formatted brief for picked direction matching picked_key" do
      design = %{
        canvas_url: "https://example.com/canvas/abc",
        picked_key: "key-b",
        directions: [
          %{key: "key-a", title: "Option A", notes: "Notes A", still_path: "$RAIL_SCRATCH/design/a.png"},
          %{key: "key-b", title: "Option B", notes: "Notes B", still_path: "$RAIL_SCRATCH/design/b.png"}
        ]
      }

      expected =
        String.trim("""
        An approved design direction has been published for this ticket:
        - Title: Option B
        - Notes: Notes B
        - Canvas URL: https://example.com/canvas/abc
        - Still screenshot: $RAIL_SCRATCH/design/b.png
        Plan the implementation to match this design.
        """)

      assert architect_design_brief(design) == expected
      assert architect_design_brief(design: design) == expected
    end

    test "falls back to single direction when picked_key is nil" do
      design = %{
        canvas_url: "https://example.com/canvas/single",
        picked_key: nil,
        directions: [
          %{key: "solo", title: "Solo Direction", notes: "Only choice", still_path: "$RAIL_SCRATCH/design/solo.png"}
        ]
      }

      brief = architect_design_brief(design)
      assert brief =~ "- Title: Solo Direction"
      assert brief =~ "- Notes: Only choice"
    end

    test "returns empty string when multiple directions exist but none is picked" do
      design = %{
        canvas_url: "https://example.com/canvas/multiple",
        picked_key: nil,
        directions: [
          %{key: "a", title: "A", notes: "A", still_path: "a.png"},
          %{key: "b", title: "B", notes: "B", still_path: "b.png"}
        ]
      }

      assert architect_design_brief(design) == ""
    end
  end

  describe "design_brief/1" do
    test "contains expected instructions and updated scratch paths" do
      brief = design_brief([])

      assert brief =~ "Invoke the `design` skill by name"
      assert brief =~ "Produce exactly three distinct design directions on a single published canvas."

      assert brief =~
               "You are designing the user interface, not implementing it: do NOT edit or touch any application code"

      assert brief =~ "save them under `$RAIL_SCRATCH/design/`"
      assert brief =~ "--headless"
      assert brief =~ "--screenshot=$RAIL_SCRATCH/design/<still>.png"
      assert brief =~ "wkhtmltoimage --width 1280 <url> $RAIL_SCRATCH/design/<still>.png"
      assert brief =~ "Write the manifest to `$RAIL_SCRATCH/design/manifest.json`"
      assert brief =~ ~s("stillPath": "$RAIL_SCRATCH/design/<still>.png")
      assert brief =~ "Stop once the design is published, the stills are captured, and the manifest is written."
      refute brief =~ ".rail/design"
    end

    test "matches exact golden output" do
      expected =
        String.trim("""
        Explore and produce design directions for the ticket below.

        Invoke the `design` skill by name to explore and generate design directions. Produce exactly three distinct design directions on a single published canvas.

        You are designing the user interface, not implementing it: do NOT edit or touch any application code under lib/, test/, or anywhere in the repository.

        Take a still screenshot of each direction and save them under `$RAIL_SCRATCH/design/`. Use headless Chrome:
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless --disable-gpu --screenshot=$RAIL_SCRATCH/design/<still>.png --window-size=1280,800 <url>
        or wkhtmltoimage as fallback:
        wkhtmltoimage --width 1280 <url> $RAIL_SCRATCH/design/<still>.png

        Write the manifest to `$RAIL_SCRATCH/design/manifest.json` with this shape:
        {
          "canvasUrl": "<absolute https URL to the published canvas>",
          "version": 1,
          "directions": [
            {
              "key": "<unique-key>",
              "title": "<title of direction>",
              "notes": "<notes on what it does differently>",
              "stillPath": "$RAIL_SCRATCH/design/<still>.png"
            }
          ],
          "pickedKey": null
        }

        A human reviews the design directions and picks one before anything is planned. Stop once the design is published, the stills are captured, and the manifest is written.
        """)

      assert design_brief() == expected
    end
  end

  describe "design_pick_brief/2" do
    test "contains expected instructions and updated scratch paths" do
      brief = design_pick_brief("dir-1", title: "Direction One")

      assert brief =~ ~s{The human picked direction "Direction One" (key: "dir-1").}
      assert brief =~ "Narrow the published canvas to this single direction so the other directions no longer appear."
      assert brief =~ "Re-shoot the still for this direction under $RAIL_SCRATCH/design/ using a versioned filename"
      assert brief =~ "(e.g. dir-1-v2.png)"
      assert brief =~ "Update $RAIL_SCRATCH/design/manifest.json with an incremented version"
      assert brief =~ "with `pickedKey` set to \"dir-1\""
      refute brief =~ ".rail/design"
    end

    test "resolves title from design directions when design struct provided" do
      design = %{
        directions: [
          %{key: "dir-a", title: "Modern Dark"}
        ]
      }

      brief = design_pick_brief(design, "dir-a")
      assert brief =~ ~s{The human picked direction "Modern Dark" (key: "dir-a").}
    end

    test "falls back to key when title is unavailable" do
      brief = design_pick_brief("dir-xyz")
      assert brief =~ ~s{The human picked direction "dir-xyz" (key: "dir-xyz").}

      opts_brief = design_pick_brief(key: "custom-key", title: "Custom Title")
      assert opts_brief =~ ~s{The human picked direction "Custom Title" (key: "custom-key").}
    end
  end

  describe "design_revise_brief/1" do
    test "contains comment, expected instructions, and updated scratch paths" do
      brief = design_revise_brief("Make buttons rounded and use primary blue for headers")

      assert brief =~ "The human requested revisions to the picked design:"
      assert brief =~ "Make buttons rounded and use primary blue for headers"
      assert brief =~ "Revise the design on the canvas to incorporate this feedback."

      assert brief =~
               "Re-shoot the still under $RAIL_SCRATCH/design/ using a versioned filename reflecting this update (e.g. <key>-v<version>.png)."

      assert brief =~ "Update $RAIL_SCRATCH/design/manifest.json with an incremented version"
      refute brief =~ ".rail/design"
    end
  end

  describe "engineer_brief/1" do
    test "instructs engineer not to commit scratch plan files" do
      brief = engineer_brief()

      assert brief =~ "$RAIL_SCRATCH/plans/"
      assert brief =~ "Implement the ticket and plan below, then open a draft pull request."
      assert brief =~ "Do not commit scratch files under $RAIL_SCRATCH/plans/ (or any scratch dir) into the pull request."

      assert brief =~
               "Review comments, reviewer findings and QA findings on that pull request come back to you as further turns of this same conversation"

      refute brief =~ ".rail/plans"
    end

    test "matches exact golden output" do
      expected =
        String.trim("""
        Implement the ticket and plan below, then open a draft pull request.

        Do not commit scratch files under $RAIL_SCRATCH/plans/ (or any scratch dir) into the pull request.

        Review comments, reviewer findings and QA findings on that pull request come back to you as further turns of this same conversation, so keep your worktree as you left it.
        """)

      assert engineer_brief([]) == expected
    end
  end

  describe "review_brief/1" do
    test "includes read-only instruction and exact verdict lines" do
      brief = review_brief([])

      assert brief =~ "Review the implementation of the ticket below."
      assert brief =~ "You are read-only: report what you find, do not fix it."
      assert brief =~ "`VERDICT: APPROVED` or `VERDICT: CHANGES REQUESTED`"
      assert brief =~ "CHANGES REQUESTED sends your findings straight back to the engineer"
      assert brief =~ "APPROVED hands it to QA"
      refute brief =~ "The change is on branch"
    end

    test "includes branch and git diff when branch is provided" do
      brief = review_brief(branch: "feature/login")

      assert brief =~ "The change is on branch feature/login; read it with `git diff main...HEAD` from your worktree."

      custom_base = review_brief(worktree_name: "feature/pay", base_branch: "develop")

      assert custom_base =~
               "The change is on branch feature/pay; read it with `git diff develop...HEAD` from your worktree."
    end
  end

  describe "qa_brief/1" do
    test "instructs driving the running app and writing evidence to scratch" do
      brief = qa_brief([])

      assert brief =~ "QA the implementation of the ticket below by driving the running app."
      assert brief =~ "Exercise what the ticket asked for and report what a user would actually see."
      assert brief =~ "write your evidence to $RAIL_SCRATCH/qa/ with a manifest.json the QA Lead reads"
      assert brief =~ "leave the app running with its VM service URL recorded there so the lead can attach"
      assert brief =~ "`VERDICT: PASS` or `VERDICT: FAIL`"
      assert brief =~ "FAIL sends your findings straight back to the engineer"
      assert brief =~ "PASS hands your evidence to the QA Lead"
      refute brief =~ ".rail/qa"
      refute brief =~ "The change is on branch"
    end

    test "includes branch line when branch is provided" do
      brief = qa_brief(branch_name: "feature/checkout")

      assert brief =~ "The change is on branch feature/checkout."
    end
  end

  describe "qa_lead_brief/1" do
    test "instructs grading the QA pass with evidence in scratch" do
      brief = qa_lead_brief([])

      assert brief =~ "Grade the QA pass on the ticket below."
      assert brief =~ "The QA engineer's report is above and its evidence is in $RAIL_SCRATCH/qa/."
      assert brief =~ "You are not re-running its checklist"
      assert brief =~ "and you have the running app to settle any of that yourself."
      assert brief =~ "`VERDICT: PASS` or `VERDICT: FAIL`"
      assert brief =~ "FAIL sends your findings and QA's straight back to the engineer"
      assert brief =~ "PASS leaves the change ready to merge."
      refute brief =~ ".rail/qa"
      refute brief =~ "The change is on branch"
    end

    test "includes branch line when branch is provided" do
      brief = qa_lead_brief(branch: "fix/nav")

      assert brief =~ "The change is on branch fix/nav."
    end
  end

  describe "demo_brief/1" do
    test "includes fallback when no criteria are found" do
      brief = demo_brief([])

      assert brief =~ "Record a demo of the ticket below working by driving the app on camera."
      assert brief =~ "do NOT edit application code, never create branches, and never open PRs."
      assert brief =~ "No criteria found in ticket. Capture evidence demonstrating the change."
      assert brief =~ "Write your frames into $RAIL_SCRATCH/demo/ and the manifest to $RAIL_SCRATCH/demo/manifest.json"
      assert brief =~ ~s("path": "$RAIL_SCRATCH/demo/<frame>.png")
      assert brief =~ "Stop once the frames and manifest are written."
      refute brief =~ ".rail/demo"
    end

    test "formats criteria list numbered in order" do
      brief = demo_brief(criteria: ["User clicks login", "Error toast appears on invalid email"])

      assert brief =~ "1. User clicks login\n2. Error toast appears on invalid email"
      assert brief =~ "Each part of the recording corresponds to an acceptance criterion from the ticket, in order:"
    end

    test "extracts acceptance criteria from ticket description markdown" do
      ticket = """
      # Fix checkout button

      Some problem description.

      ## Acceptance criteria
      - Button is enabled when cart has items
      - Clicking button navigates to /checkout
      """

      brief = demo_brief(ticket: ticket)

      assert brief =~ "1. Button is enabled when cart has items\n2. Clicking button navigates to /checkout"
    end
  end

  describe "demo_rerecord_brief/1" do
    test "matches golden output when comment is provided" do
      brief = demo_rerecord_brief("First attempt missed the validation modal")

      assert brief =~ "The human requested that the demo be re-recorded:"
      assert brief =~ "First attempt missed the validation modal"
      assert brief =~ "Re-record the demo of the ticket below working by driving the app on camera."
      assert brief =~ "Write your frames into $RAIL_SCRATCH/demo/ and the manifest to $RAIL_SCRATCH/demo/manifest.json"
      assert brief =~ "\"version\": 2"
      refute brief =~ ".rail/demo"
    end

    test "matches golden output without comment" do
      brief = demo_rerecord_brief(version: 3)

      refute brief =~ "The human requested that the demo be re-recorded:"
      assert brief =~ "Re-record the demo of the ticket below working by driving the app on camera."
      assert brief =~ "\"version\": 3"
    end
  end

  describe "rebase_brief/1" do
    test "formats default rebase brief" do
      brief = rebase_brief([])

      assert brief =~ "The pull request for this task's branch no longer merges into main"
      assert brief =~ "git fetch origin main"
      assert brief =~ "git rebase origin/main"
      assert brief =~ "Resolve each conflict as it comes, `git add` the resolved files and `git rebase --continue`"
      assert brief =~ "stop and ask with [QUESTION: ...] rather than guessing."
      assert brief =~ "git push --force-with-lease origin this task's branch"
      assert brief =~ "This is a rebase and nothing else."
      assert brief =~ "Finish by saying what conflicted and how you resolved each one."
    end

    test "formats rebase brief with custom branch, base, and pr number" do
      brief = rebase_brief(branch: "fix-auth", base_branch: "develop", pr_number: 142)

      assert brief =~ "PR #142 for fix-auth no longer merges into develop"
      assert brief =~ "git fetch origin develop"
      assert brief =~ "git push --force-with-lease origin fix-auth"
    end
  end

  describe "workspace_brief/1" do
    test "returns empty string when worktree_path or branch is missing" do
      assert workspace_brief([]) == ""
      assert workspace_brief(worktree_path: "/tmp/wt") == ""
      assert workspace_brief(branch: "branch-a") == ""
    end

    test "formats workspace brief for non-engineer role" do
      brief =
        workspace_brief(
          worktree_path: "/workspace/proj/wt-1",
          branch: "task-1-feat",
          base_branch: "main",
          identifier: "RAIL-77",
          role: "architect"
        )

      assert brief =~ "Workspace for this task:"
      assert brief =~ "- Worktree: /workspace/proj/wt-1 (your working directory; every path you touch is under it)"
      assert brief =~ "- Branch: task-1-feat, already checked out."
      assert brief =~ "- Base branch: main on remote `origin`"
      assert brief =~ "- Ticket: RAIL-77"
      assert brief =~ "- Other agents share this repository."
      refute brief =~ "Hand the work over when every slice is done"
    end

    test "includes handover instructions for engineer role when not rebasing" do
      brief =
        workspace_brief(
          worktree_path: "/workspace/proj/wt-1",
          branch: "task-1-feat",
          base_branch: "main",
          identifier: "RAIL-77",
          role: :engineer,
          title: "Add \"quick\" search"
        )

      assert brief =~ "Hand the work over when every slice is done and the checks are green:"
      assert brief =~ "git push -u origin task-1-feat"

      assert brief =~
               "gh pr create --draft --base main --head task-1-feat --title \"Add 'quick' search\" --body \"Closes RAIL-77."

      assert brief =~ "This task is NOT done until `gh pr create` has returned a pull request URL."
    end

    test "omits handover instructions for engineer when rebasing" do
      brief =
        workspace_brief(
          worktree_path: "/workspace/proj/wt-1",
          branch: "task-1-feat",
          role: "engineer",
          is_rebasing: true
        )

      refute brief =~ "Hand the work over when every slice is done"
    end
  end

  describe "stage_brief/2 top-level dispatcher" do
    test "returns empty string for terminal stages, unknown stages, or nil" do
      assert stage_brief(nil) == ""
      assert stage_brief(:ready_to_merge) == ""
      assert stage_brief(:merged) == ""
      assert stage_brief(:unknown_stage) == ""
      assert stage_brief(%{stage: :ready_to_merge}) == ""
      assert stage_brief(%{stage: :merged}) == ""
    end

    test "dispatches based on stage atom" do
      assert stage_brief(:product, identifier: "RAIL-1") =~ "Turn this backlog idea into a ticket"
      assert stage_brief(:design) =~ "Invoke the `design` skill by name"
      assert stage_brief(:architect, identifier: "RAIL-1") =~ "Plan the implementation of the ticket below."
      assert stage_brief(:engineer) =~ "Implement the ticket and plan below"
      assert stage_brief(:review) =~ "Review the implementation of the ticket below."
      assert stage_brief(:qa) =~ "QA the implementation of the ticket below"
      assert stage_brief(:qa_lead) =~ "Grade the QA pass on the ticket below."
      assert stage_brief(:demo) =~ "Record a demo of the ticket below"
    end

    test "dispatches based on stage string" do
      assert stage_brief("product", identifier: "RAIL-2") =~ "Turn this backlog idea into a ticket"
      assert stage_brief("design") =~ "Invoke the `design` skill by name"
      assert stage_brief("architect", identifier: "RAIL-2") =~ "Plan the implementation of the ticket below."
      assert stage_brief("engineer") =~ "Implement the ticket and plan below"
      assert stage_brief("review") =~ "Review the implementation of the ticket below."
      assert stage_brief("qa") =~ "QA the implementation of the ticket below"
      assert stage_brief("qa_lead") =~ "Grade the QA pass on the ticket below."
      assert stage_brief("demo") =~ "Record a demo of the ticket below"
      assert stage_brief("ready_to_merge") == ""
      assert stage_brief("merged") == ""
      assert stage_brief("other") == ""
    end

    test "dispatches based on task map or struct" do
      task = %{
        stage: :engineer,
        worktree_name: "branch-task",
        identifier: "RAIL-99"
      }

      assert stage_brief(task) =~ "Implement the ticket and plan below"
    end

    test "dispatches to rebase_brief when is_rebasing is true" do
      task = %{
        stage: :review,
        is_rebasing: true,
        worktree_name: "branch-rebase"
      }

      brief = stage_brief(task)
      assert brief =~ "no longer merges into main: the base branch has moved"
      refute brief =~ "Review the implementation of the ticket below."

      opts_brief = stage_brief(:engineer, is_rebasing: true, branch: "hotfix")
      assert opts_brief =~ "no longer merges into main"
      refute opts_brief =~ "Implement the ticket and plan below"
    end

    test "handles edge cases and non-map/struct parameters cleanly" do
      assert demo_rerecord_brief() =~ "Re-record the demo of the ticket below"

      brief_criteria = demo_rerecord_brief(criteria: ["Step 1", "Step 2"])
      assert brief_criteria =~ "1. Step 1\n2. Step 2"

      # opts as map with design where key is not found
      map_opts_miss = design_pick_brief("dir-miss", %{design: %{directions: [%{key: "other", title: "Other"}]}})
      assert map_opts_miss =~ ~s{The human picked direction "dir-miss" (key: "dir-miss").}

      # opts as map without design key
      map_opts_no_design = design_pick_brief("dir-none", %{})
      assert map_opts_no_design =~ ~s{The human picked direction "dir-none" (key: "dir-none").}

      # non-map stage
      assert stage_brief(12_345) == ""

      # non-list/map opts to rebase_brief
      assert rebase_brief(12_345) =~ "The pull request for this task's branch no longer merges into main"

      # struct input to stage_brief
      struct_task = %Rail.Domain.TicketBody{title: "Test Task", description: "Body"}
      assert stage_brief(struct_task) == ""

      # non-map design inside architect_design_brief
      assert architect_design_brief(%{design: "invalid_design_type"}) == ""
    end
  end
end
