defmodule Rail.Pipeline.Utils.BriefsTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.Briefs

  describe "plan_write_brief/1" do
    test "names the plan file and the heading Rail parses" do
      brief = plan_write_brief(identifier: "30")

      assert brief =~ "$RAIL_SCRATCH/plans/30.md"
      assert brief =~ "The ticket itself is not yours to write"
      assert brief =~ "mkdir -p $RAIL_SCRATCH/plans"
      assert brief =~ "cat > $RAIL_SCRATCH/plans/30.md <<'PLAN'"
      assert brief =~ "## Implementation plan"
      refute brief =~ "Linear"
    end

    test "matches exact golden heredoc formatting for plan write brief" do
      expected =
        String.trim("""
        The plan is the file $RAIL_SCRATCH/plans/RAIL-200.md. Rail captures it when your run completes cleanly. The ticket itself is not yours to write.

        Write it from your worktree with a heredoc, the body and its closing PLAN line at column zero:

        mkdir -p $RAIL_SCRATCH/plans
        cat > $RAIL_SCRATCH/plans/RAIL-200.md <<'PLAN'
        ## Implementation plan

        <the implementation plan>
        PLAN

        - A heredoc into $RAIL_SCRATCH/plans/RAIL-200.md, never an inline string.
        - Keep the `## Implementation plan` heading on the first line.
        - A ticket you split out is its own file, $RAIL_SCRATCH/tickets/split-<n>.md, with `---` front matter carrying its `title`. Rail opens each one as a new ticket.
        """)

      assert plan_write_brief(identifier: "RAIL-200") == expected
      assert plan_write_brief(%{issue_number: "RAIL-200"}) == expected
    end
  end

  describe "architect_brief/1" do
    test "uses plan_write_brief and points at plan file" do
      brief = architect_brief(identifier: "30")

      assert brief =~ "$RAIL_SCRATCH/plans/30.md"
      assert brief =~ "cat > $RAIL_SCRATCH/plans/30.md <<'PLAN'"
      assert brief =~ "Review comments come back as further turns of this same conversation."
      refute brief =~ "acceptance criteria"
      refute brief =~ "Linear"
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

      assert brief =~ "The approved design direction for this ticket:"
      assert brief =~ "- Title: Direction One"
      assert brief =~ "- Notes: Clean minimal layout"
      assert brief =~ "- Canvas URL: https://claude.ai/canvas/123"
      assert brief =~ "- Still screenshot: $RAIL_SCRATCH/design/dir-1.png"
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
        The approved design direction for this ticket:
        - Title: Option B
        - Notes: Notes B
        - Canvas URL: https://example.com/canvas/abc
        - Still screenshot: $RAIL_SCRATCH/design/b.png
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

      assert brief =~ "Rail reads your design directions from $RAIL_SCRATCH/design/."
      assert brief =~ "Write the manifest to $RAIL_SCRATCH/design/manifest.json"
      assert brief =~ ~s("stillPath": "$RAIL_SCRATCH/design/<still>.png")
      assert brief =~ ~s("pickedKey": null)
      refute brief =~ "design` skill"
      refute brief =~ "headless"
      refute brief =~ ".rail/design"
    end

    test "matches exact golden output" do
      expected =
        String.trim("""
        Rail reads your design directions from $RAIL_SCRATCH/design/. Save a still screenshot of each direction there, and never edit application code on this stage.

        Write the manifest to $RAIL_SCRATCH/design/manifest.json with this shape:
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
        """)

      assert design_brief() == expected
    end
  end

  describe "design_pick_brief/2" do
    test "contains expected instructions and updated scratch paths" do
      brief = design_pick_brief("dir-1", title: "Direction One")

      assert brief =~ ~s{The human picked direction "Direction One" (key: "dir-1").}
      assert brief =~ "Re-shoot its still under $RAIL_SCRATCH/design/ with a new versioned filename"
      assert brief =~ "(e.g. dir-1-v2.png)"
      assert brief =~ "rewrite $RAIL_SCRATCH/design/manifest.json with an incremented `version`"
      assert brief =~ "`pickedKey` set to \"dir-1\""
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

      assert brief =~
               "Re-shoot the still under $RAIL_SCRATCH/design/ with a new versioned filename (e.g. <key>-v<version>.png)"

      assert brief =~ "rewrite $RAIL_SCRATCH/design/manifest.json with an incremented `version`"
      refute brief =~ ".rail/design"
    end
  end

  describe "engineer_brief/1" do
    test "matches exact golden output" do
      expected =
        String.trim("""
        Never commit anything under $RAIL_SCRATCH into the pull request.

        Review comments, reviewer findings and QA findings come back as further turns of this same conversation, so keep your worktree as you left it.
        """)

      assert engineer_brief() == expected
      assert engineer_brief([]) == expected
    end
  end

  describe "review_brief/1" do
    test "carries only the verdict contract" do
      brief = review_brief([])

      assert brief =~ "`VERDICT: APPROVED` or `VERDICT: CHANGES REQUESTED`"
      assert brief =~ "CHANGES REQUESTED sends your findings back to the engineer"
      assert brief =~ "APPROVED hands it to QA"
      refute brief =~ "read-only"
      refute brief =~ "blocker"
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

      assert brief =~ "Write your evidence to $RAIL_SCRATCH/qa/ with a manifest.json"
      assert brief =~ "leave the app running with its VM service URL recorded there"
      assert brief =~ "`VERDICT: PASS` or `VERDICT: FAIL`"
      assert brief =~ "FAIL sends your findings back to the engineer"
      assert brief =~ "PASS hands your evidence to the QA Lead"
      refute brief =~ "blocker"
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

      assert brief =~ "The QA engineer's report is above and its evidence is in $RAIL_SCRATCH/qa/"
      assert brief =~ "`VERDICT: PASS` or `VERDICT: FAIL`"
      assert brief =~ "FAIL sends your findings and QA's back to the engineer"
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

      assert brief =~ "Never edit application code, create a branch or open a pull request on this stage."
      assert brief =~ "No criteria found in ticket. Capture evidence demonstrating the change."
      assert brief =~ "Rail reads the recording from $RAIL_SCRATCH/demo/."
      assert brief =~ ~s("path": "$RAIL_SCRATCH/demo/<frame>.png")
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
      assert brief =~ "Re-record the demo."
      assert brief =~ "Rail reads the recording from $RAIL_SCRATCH/demo/."
      assert brief =~ "\"version\": 2"
      refute brief =~ ".rail/demo"
    end

    test "matches golden output without comment" do
      brief = demo_rerecord_brief(version: 3)

      refute brief =~ "The human requested that the demo be re-recorded:"
      assert brief =~ "Re-record the demo."
      assert brief =~ "\"version\": 3"
    end
  end

  describe "rebase_brief/1" do
    test "formats default rebase brief" do
      brief = rebase_brief([])

      assert brief =~ "The pull request for this task's branch no longer merges into main"
      assert brief =~ "git fetch origin main"
      assert brief =~ "git rebase origin/main"
      assert brief =~ "git push --force-with-lease origin this task's branch"
      assert brief =~ "This run is a rebase and nothing else"
      assert brief =~ "put `[QUESTION: ...]` on its own line"
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
      assert stage_brief(:product, identifier: "RAIL-1") == ""
      assert stage_brief(:design) =~ "$RAIL_SCRATCH/design/manifest.json"
      assert stage_brief(:architect, identifier: "RAIL-1") =~ "$RAIL_SCRATCH/plans/RAIL-1.md"
      assert stage_brief(:engineer) =~ "Never commit anything under $RAIL_SCRATCH"
      assert stage_brief(:review) =~ "`VERDICT: APPROVED` or `VERDICT: CHANGES REQUESTED`"
      assert stage_brief(:qa) =~ "$RAIL_SCRATCH/qa/"
      assert stage_brief(:qa_lead) =~ "The QA engineer's report is above"
      assert stage_brief(:demo) =~ "$RAIL_SCRATCH/demo/manifest.json"
    end

    test "dispatches based on stage string" do
      assert stage_brief("product", identifier: "RAIL-2") == ""
      assert stage_brief("design") =~ "$RAIL_SCRATCH/design/manifest.json"
      assert stage_brief("architect", identifier: "RAIL-2") =~ "$RAIL_SCRATCH/plans/RAIL-2.md"
      assert stage_brief("engineer") =~ "Never commit anything under $RAIL_SCRATCH"
      assert stage_brief("review") =~ "`VERDICT: APPROVED` or `VERDICT: CHANGES REQUESTED`"
      assert stage_brief("qa") =~ "$RAIL_SCRATCH/qa/"
      assert stage_brief("qa_lead") =~ "The QA engineer's report is above"
      assert stage_brief("demo") =~ "$RAIL_SCRATCH/demo/manifest.json"
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

      assert stage_brief(task) =~ "Never commit anything under $RAIL_SCRATCH"
    end

    test "dispatches to rebase_brief when is_rebasing is true" do
      task = %{
        stage: :review,
        is_rebasing: true,
        worktree_name: "branch-rebase"
      }

      brief = stage_brief(task)
      assert brief =~ "no longer merges into main. Rebase the branch"
      refute brief =~ "VERDICT: APPROVED"

      opts_brief = stage_brief(:engineer, is_rebasing: true, branch: "hotfix")
      assert opts_brief =~ "no longer merges into main"
      refute opts_brief =~ "Never commit anything under $RAIL_SCRATCH"
    end

    test "handles edge cases and non-map/struct parameters cleanly" do
      assert demo_rerecord_brief() =~ "Re-record the demo."

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
