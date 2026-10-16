defmodule Rail.Pipeline.Schemas.FixPlanTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FixPlan
  alias Rail.Pipeline.Schemas.Task

  @plan String.trim("""
        Two small changes inside Send and the tray.

        ### What changes

        #### `send-drops-screen-comments`

        `SendReviewRound.run/2` reads screen comments too.

        #### `tray-count-skips-finding-comments`

        The tray counts finding comments.

        #### Comment 1

        A sent comment stays under its line.

        ### File-level changes

        - `lib/rail/send.ex`: reads screen comments. For `send-drops-screen-comments`.
        - `lib/rail_web/tray.ex`: counts finding comments. For `tray-count-skips-finding-comments`.
        - `lib/rail_web/diff_comment.ex`: draws a sent comment. For comment 1.
        - `lib/rail/send_test.exs`: one Send lists all three. For `send-drops-screen-comments`.

        ### Verification

        `mix test lib/rail/send_test.exs`.
        """)

  setup do
    fix_plan = %FixPlan{
      round: 1,
      findings: [
        %FixPlan.Finding{key: "send-drops-screen-comments", title: "Send leaves screen comments out"},
        %FixPlan.Finding{key: "tray-count-skips-finding-comments", title: "Tray count leaves out finding comments"}
      ],
      comments: [%FixPlan.Comment{number: 1, kind: :diff, place: "diff_comment.ex:58", text: "Keep it under its line."}]
    }

    findings = [
      %Finding{key: "send-drops-screen-comments", title: "Send leaves screen comments out", decision: :fix},
      %Finding{key: "tray-count-skips-finding-comments", title: "Tray count leaves out finding comments", decision: :fix},
      %Finding{key: "composer-focus", title: "Composer keeps focus", decision: :skip}
    ]

    %{fix_plan: fix_plan, findings: findings, task: %Task{stage: :review}}
  end

  describe "save_changeset/2" do
    test "a plan naming every key and comment, each file naming an item, is the next version covering the round", %{
      fix_plan: fix_plan
    } do
      assert {:ok,
              %FixPlan{
                version: 1,
                covered_keys: ["send-drops-screen-comments", "tray-count-skips-finding-comments"],
                covered_comments: 1,
                saved_at: %DateTime{}
              }} = fix_plan |> FixPlan.save_changeset(%{"plan" => @plan}) |> apply_action(:update)
    end

    test "a plan with only What changes is taken, since nothing may change", %{fix_plan: fix_plan} do
      plan =
        "Nothing changes.\n\n### What changes\n\n#### `send-drops-screen-comments`\n\nNo.\n\n" <>
          "#### `tray-count-skips-finding-comments`\n\nNo.\n\n#### Comment 1\n\nAnswered."

      assert {:ok, %FixPlan{version: 1}} = fix_plan |> FixPlan.save_changeset(%{"plan" => plan}) |> apply_action(:update)
    end

    test "a plan missing a key or a comment is refused naming it", %{fix_plan: fix_plan} do
      plan = String.replace(@plan, "#### Comment 1\n\nA sent comment stays under its line.\n\n", "")
      plan = String.replace(plan, "#### `tray-count-skips-finding-comments`\n\n", "")

      assert %{plan: errors} = fix_plan |> FixPlan.save_changeset(%{"plan" => plan}) |> errors_on()
      assert Enum.any?(errors, &(&1 =~ "leaves out `tray-count-skips-finding-comments`"))
      assert Enum.any?(errors, &(&1 =~ "leaves out comment 1"))
    end

    test "a plan naming an item the round did not send, or one twice, is refused naming it", %{fix_plan: fix_plan} do
      plan =
        String.replace(
          @plan,
          "### File-level changes",
          "#### Comment 2\n\nMore.\n\n#### Comment 1\n\nAgain.\n\n#### Changes to the plan\n\nA dot.\n\n" <>
            "#### Changes to the plan\n\nAnd a dash.\n\n### File-level changes"
        )

      assert %{plan: errors} = fix_plan |> FixPlan.save_changeset(%{"plan" => plan}) |> errors_on()
      assert Enum.any?(errors, &(&1 =~ "names comment 2 under `### What changes`, which this round did not send"))
      assert Enum.any?(errors, &(&1 =~ "names comment 1 under `### What changes` more than once"))
      assert Enum.any?(errors, &(&1 =~ "names the changes to the plan under `### What changes` more than once"))
    end

    test "a file naming no item is refused naming its path", %{fix_plan: fix_plan} do
      plan = String.replace(@plan, "draws a sent comment. For comment 1.", "draws a sent comment.")

      assert %{plan: [error]} = fix_plan |> FixPlan.save_changeset(%{"plan" => plan}) |> errors_on()
      assert error =~ "`lib/rail_web/diff_comment.ex` under `### File-level changes` naming no item"
    end

    test "File-level changes are held to the Plan tab's rules", %{fix_plan: fix_plan} do
      plan = String.replace(@plan, "- `lib/rail/send.ex`:", "- lib/rail/send.ex:")

      assert %{plan: [error]} = fix_plan |> FixPlan.save_changeset(%{"plan" => plan}) |> errors_on()
      assert error =~ "not a bullet starting with a file path in backticks"
    end

    test "a plan without What changes, with an unknown section or a stray heading is refused", %{fix_plan: fix_plan} do
      assert %{plan: [missing]} = fix_plan |> FixPlan.save_changeset(%{"plan" => "Just prose."}) |> errors_on()
      assert missing =~ "is missing its `### What changes` section"

      plan = @plan <> "\n\n### Risks\n\nNone."
      assert %{plan: [unknown]} = fix_plan |> FixPlan.save_changeset(%{"plan" => plan}) |> errors_on()
      assert unknown =~ "has a `### Risks` section"

      plan = @plan <> "\n\n### Verification\n\nAgain."
      assert %{plan: [twice]} = fix_plan |> FixPlan.save_changeset(%{"plan" => plan}) |> errors_on()
      assert twice =~ "has `### Verification` more than once"

      plan = String.replace(@plan, "### What changes\n", "### What changes\n\nFirst this.\n\n#### Finding one\n")
      assert %{plan: errors} = fix_plan |> FixPlan.save_changeset(%{"plan" => plan}) |> errors_on()
      assert Enum.any?(errors, &(&1 =~ "before its first `####` item"))
      assert Enum.any?(errors, &(&1 =~ "has `#### Finding one` under `### What changes`"))
    end

    # A person can ask for a change no finding or comment carries, as with nothing outstanding at Finalize.
    test "a change only a person asked for goes under its own item, and a file for it names it", %{fix_plan: fix_plan} do
      plan =
        "### Changes to the plan\n\n- Criterion 1: a dot, not parentheses.\n\n### What changes\n\n" <>
          "#### Changes to the plan\n\nThe heading takes a dot.\n\n" <>
          "### File-level changes\n\n- `lib/heading.ex`: the dot. For the changes to the plan."

      fix_plan = %{fix_plan | findings: [], comments: []}

      assert {:ok, %FixPlan{covered_keys: [], covered_comments: 0}} =
               fix_plan |> FixPlan.save_changeset(%{"plan" => plan}) |> apply_action(:update)

      unnamed = String.replace(plan, " For the changes to the plan.", "")
      assert %{plan: [error]} = fix_plan |> FixPlan.save_changeset(%{"plan" => unnamed}) |> errors_on()
      assert error =~ "`lib/heading.ex` under `### File-level changes` naming no item"
      assert error =~ "`changes to the plan`"
    end

    test "an empty plan is refused", %{fix_plan: fix_plan} do
      assert %{plan: ["can't be blank"]} = fix_plan |> FixPlan.save_changeset(%{"plan" => " "}) |> errors_on()
    end
  end

  describe "state/3" do
    setup %{fix_plan: fix_plan} do
      {:ok, saved} = fix_plan |> FixPlan.save_changeset(%{"plan" => @plan}) |> apply_action(:update)
      %{saved: saved}
    end

    test "waiting while the plan covers what was sent and it matches the Fix rulings", %{
      saved: saved,
      task: task,
      findings: findings
    } do
      assert FixPlan.state(saved, task, findings) == :waiting
    end

    test "writing before a plan is saved, approved once approved", %{fix_plan: fix_plan, saved: saved, task: task} do
      assert FixPlan.state(fix_plan, task, []) == :writing
      assert FixPlan.state(%{saved | approved_at: DateTime.utc_now()}, task, []) == :approved
    end

    test "out of date when a ruling changes either way, and waiting again once it is changed back", %{
      saved: saved,
      task: task,
      findings: [send, tray, focus]
    } do
      assert FixPlan.state(saved, task, [send, %{tray | decision: :skip}, focus]) == :outdated
      assert FixPlan.state(saved, task, [send, tray, %{focus | decision: :fix}]) == :outdated
      assert FixPlan.state(saved, task, [send, tray, focus]) == :waiting
    end

    test "revising while what was sent has keys or comments the plan does not cover", %{
      saved: saved,
      task: task,
      findings: [send, tray, focus]
    } do
      more = %{saved | comments: [%FixPlan.Comment{number: 2, kind: :diff, text: "And this."} | saved.comments]}
      assert FixPlan.state(more, task, [send, tray, focus]) == :revising

      fewer = %{saved | findings: [hd(saved.findings)]}
      assert FixPlan.state(fewer, task, [send, %{tray | decision: :skip}, focus]) == :revising
    end

    test "past Review no ruling counts against what was sent", %{saved: saved, findings: [send, tray, focus]} do
      assert FixPlan.state(saved, %Task{stage: :finalize}, [send, %{tray | decision: :skip}, focus]) == :waiting
    end
  end

  describe "calculate_ruling_changes/3" do
    test "names each changed key with its old and new ruling, unsent and since the plan", %{
      fix_plan: fix_plan,
      task: task,
      findings: [send, tray, focus]
    } do
      {:ok, saved} = fix_plan |> FixPlan.save_changeset(%{"plan" => @plan}) |> apply_action(:update)
      findings = [send, %{tray | decision: :skip}, %{focus | decision: :fix}]

      assert %{
               unsent: [
                 %{
                   key: "tray-count-skips-finding-comments",
                   title: "Tray count leaves out finding comments",
                   was: :fix,
                   now: :skip
                 },
                 %{key: "composer-focus", was: :skip, now: :fix}
               ],
               since_plan: [%{key: "tray-count-skips-finding-comments"}, %{key: "composer-focus"}]
             } = FixPlan.calculate_ruling_changes(saved, task, findings)

      # Sent on, the snapshot matches, but the plan still covers the old rulings.
      sent = %{
        saved
        | findings: [hd(saved.findings), %FixPlan.Finding{key: "composer-focus", title: "Composer keeps focus"}]
      }

      assert %{unsent: [], since_plan: [%{key: "tray-count-skips-finding-comments"}, %{key: "composer-focus"}]} =
               FixPlan.calculate_ruling_changes(sent, task, findings)
    end

    test "nothing changes before a plan is saved against what was sent, once approved, or past Review", %{
      fix_plan: fix_plan,
      task: task,
      findings: findings
    } do
      assert %{unsent: [], since_plan: []} = FixPlan.calculate_ruling_changes(fix_plan, task, findings)

      assert %{unsent: [], since_plan: []} =
               FixPlan.calculate_ruling_changes(%{fix_plan | approved_at: DateTime.utc_now()}, task, [])

      skipped = Enum.map(findings, &%{&1 | decision: :skip})
      assert %{unsent: [], since_plan: []} = FixPlan.calculate_ruling_changes(fix_plan, %Task{stage: :merged}, skipped)
    end
  end

  describe "build_sheet/1" do
    test "links each item to the files that name it and counts findings, comments and files", %{fix_plan: fix_plan} do
      {:ok, saved} = fix_plan |> FixPlan.save_changeset(%{"plan" => "## Fix plan\n\n" <> @plan}) |> apply_action(:update)

      assert %{
               summary: "Two small changes inside Send and the tray.",
               items: [
                 %{
                   kind: :finding,
                   key: "send-drops-screen-comments",
                   files: [1, 4],
                   body: "`SendReviewRound.run/2` reads screen comments too."
                 },
                 %{kind: :finding, key: "tray-count-skips-finding-comments", files: [2]},
                 %{kind: :comment, number: 1, comment_kind: :diff, place: "diff_comment.ex:58", files: [3]}
               ],
               files: [%{number: 1, path: "lib/rail/send.ex"} | _rest],
               verification: "`mix test lib/rail/send_test.exs`.",
               counts: %{findings: 2, comments: 1, files: 4}
             } = FixPlan.build_sheet(saved)
    end

    # A Send while the plan waits replaces the snapshot, but the file on screen still says what it was written for.
    test "a plan being revised lays out what it covers, titles kept, and says it no longer covers the round", %{
      fix_plan: fix_plan
    } do
      {:ok, saved} = fix_plan |> FixPlan.save_changeset(%{"plan" => @plan}) |> apply_action(:update)

      revising = %{
        saved
        | findings: [
            %FixPlan.Finding{key: "tray-count-skips-finding-comments", title: "Tray count leaves out finding comments"}
          ],
          comments: [hd(saved.comments), %FixPlan.Comment{number: 2, kind: :diff, text: "And this."}]
      }

      assert %{
               items: [
                 %{key: "send-drops-screen-comments", title: "Send leaves screen comments out", files: [1, 4]},
                 %{key: "tray-count-skips-finding-comments"},
                 %{kind: :comment, number: 1}
               ],
               counts: %{findings: 2, comments: 1},
               covers_round: false
             } = FixPlan.build_sheet(revising)

      assert %{covers_round: true} = FixPlan.build_sheet(saved)
    end

    test "a plan with nothing to change has no files, and none is laid out before one is saved", %{fix_plan: fix_plan} do
      plan = "### What changes\n\n#### Comment 1\n\nAnswered."
      fix_plan = %{fix_plan | findings: []}
      {:ok, saved} = fix_plan |> FixPlan.save_changeset(%{"plan" => plan}) |> apply_action(:update)

      assert %{summary: "", files: [], verification: nil, changes: nil, counts: %{files: 0}} =
               FixPlan.build_sheet(saved)

      assert FixPlan.build_sheet(fix_plan) == nil
    end

    test "the changes a person asked for read as one, the section first and then its item", %{fix_plan: fix_plan} do
      plan =
        "### Changes to the plan\n\n- Criterion 1: a dot.\n\n### What changes\n\n" <>
          "#### Changes to the plan\n\nThe heading takes a dot.\n\n### File-level changes\n\n" <>
          "- `lib/heading.ex`: the dot. For the changes to the plan."

      {:ok, saved} =
        %{fix_plan | findings: [], comments: []} |> FixPlan.save_changeset(%{"plan" => plan}) |> apply_action(:update)

      assert %{changes: "- Criterion 1: a dot.\n\nThe heading takes a dot.", items: [], counts: %{files: 1}} =
               FixPlan.build_sheet(saved)
    end
  end

  describe "parse_note/1" do
    test "reads a Send back into its counts, finding titles and numbered comments" do
      note = """
      Sent 1 finding and 4 comments.

      Start fix round 1.

      <finding key="nil-crash" severity="major" kind="code">
      Nil crashes the page

      Rule: Every caller handles nil.
      </finding>

      1. On the diff:
      <diff_comment>
      lib/a.ex, line 3
      >   + handle(nil)
          + more()
      Keep it under its line.
      </diff_comment>

      9. On the diff:
      <diff_comment>
      lib/a.ex, line 9
      </diff_comment>

      2. On a screen:
      <screen_comment>
      File list (file-list), commented on abc1234
      Picture: /scratch/qa/file-list.png
      Name the commit.
      </screen_comment>

      3. On a finding:
      <finding_comment key="nil-crash" ruling="Fix">
      Nil crashes the page
      Fix, as it read:
      > Guard it.
      Guard it higher up.
      </finding_comment>
      """

      assert %{
               summary: "1 finding and 4 comments",
               findings: ["Nil crashes the page"],
               rulings: [],
               comments: [
                 %{number: 1, text: "Keep it under its line."},
                 %{number: 9, text: ""},
                 %{number: 2, text: "Name the commit."},
                 %{number: 3, text: "Guard it higher up."}
               ]
             } = FixPlan.parse_note(note)
    end

    test "reads changed rulings, leaving out of the findings one that is also a changed ruling" do
      note = """
      Sent 2 changed rulings and 1 comment.

      <ruling_change key="tray-count" was="Fix" now="Don't fix">
      Tray count leaves out finding comments
      </ruling_change>

      <ruling_change key="focus" was="Don't fix" now="Fix">
      Composer keeps focus
      </ruling_change>

      <finding key="focus" severity="nit" kind="screen">
      Composer keeps focus
      </finding>

      4. On the diff:
      <diff_comment>
      lib/a.ex, line 3
      + handle(nil)
      Also this.
      </diff_comment>
      """

      assert %{
               summary: "2 changed rulings and 1 comment",
               findings: [],
               rulings: [
                 %{key: "tray-count", title: "Tray count leaves out finding comments", was: "Fix", now: "Don't fix"},
                 %{key: "focus", was: "Don't fix", now: "Fix"}
               ],
               comments: [%{number: 4, text: "Also this."}]
             } = FixPlan.parse_note(note)
    end

    test "a diff comment's code with blank lines, as the transcript keeps them, is left out of its text" do
      note = """
      Sent 1 comment.

      1. On the diff:
      <diff_comment>
      .rail/prompts/demo.md, line 84

          The captions are what turn a screen recording into a demo.

        - - **One sentence of about twelve words**.
      > + - **One sentence, said aloud.**
      Move this to the brief.
      </diff_comment>
      """

      assert %{comments: [%{number: 1, text: "Move this to the brief."}]} = FixPlan.parse_note(note)
    end

    test "any other message is no Send" do
      assert FixPlan.parse_note("Sent the email. Can you check?") == nil
      assert FixPlan.parse_note(nil) == nil
    end
  end
end
