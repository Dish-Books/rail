defmodule Rail.Pipeline.Utils.Briefs do
  @moduledoc """
  Constructs stage and operational briefs prepended to CLI agent runs.
  """

  @doc """
  Top-level dispatcher for any pipeline stage brief.
  """
  def stage_brief(stage_or_task, opts \\ [])

  def stage_brief(nil, _opts), do: ""

  def stage_brief(stage_or_task, opts) do
    {stage, merged_opts} = extract_stage_and_opts(stage_or_task, opts)

    if get_opt(merged_opts, :is_rebasing) do
      rebase_brief(merged_opts)
    else
      dispatch_stage_brief(stage, merged_opts)
    end
  end

  @doc """
  Stage brief for the Product role.
  """
  def product_brief(opts \\ []) do
    ticket_section = ticket_write_brief(opts)

    String.trim("""
    Turn this backlog idea into a ticket the Architect can plan from.

    Verify what it claims against the code before you write anything, and cover what comparable products do in this area where the call is a product one. Write the ticket, then put it on the issue with the commands below. Leave `## Implementation plan` to the Architect.

    #{ticket_section}
    Findings, competitor comparisons and assumptions are your report to the human, and stay in this conversation - never in the issue body.

    A human reviews your ticket before anything is planned, and may send it back to you with comments on this same conversation. When that happens, edit the issue again. Stop once the ticket is written.

    The raw ask follows; quote it verbatim as the ticket's source, never reword it.
    """)
  end

  @doc """
  How a role that owns the ticket puts its work where Axis will find it.
  """
  def ticket_write_brief(opts \\ []) do
    identifier =
      get_opt(opts, :identifier) ||
        get_opt(opts, :issue_identifier) ||
        get_opt(opts, :issue_number)

    if is_nil(identifier) or identifier == "" do
      "This task has no Linear issue, so there is nowhere to write the ticket. Report that and stop: a target repository has to be set in Axis Settings before this stage can produce anything.\n"
    else
      file = "$AXIS_SCRATCH/tickets/#{identifier}.md"

      String.trim_trailing("""
      The ticket is Linear issue #{identifier}, and its body IS the ticket. Nothing you write in this reply reaches it - Axis captures it from #{file} and updates the issue when your run completes cleanly.

      From your worktree, with the heredoc body and its closing TICKET line at column zero:

      mkdir -p $AXIS_SCRATCH/tickets
      cat > #{file} <<'TICKET'
      # <the ticket title>

      <the whole ticket body, starting at the problem paragraph>
      TICKET

      Rules for that write:
      - A heredoc into #{file}, never an inline string. A ticket is markdown full of quotes, backticks and blank lines, and only a file carries it cleanly.
      - The file replaces the ticket body: `# <the ticket title>` must be on the very first line, followed by the complete body with every section the finished ticket should have.
      - Axis reads #{file} and updates Linear when your run completes cleanly. Do not run `gh issue edit` or any issue editing commands yourself.
      - An ask you split out is a new issue of its own, never a second ticket inside this one:

      mkdir -p $AXIS_SCRATCH/tickets
      cat > $AXIS_SCRATCH/tickets/split-1.md <<'TICKET'
      # <title>

      <the split ticket body>
      TICKET

      Name any issue you opened in your report.
      """) <> "\n"
    end
  end

  @doc """
  Stage brief for the Design role.
  """
  def design_brief(_opts \\ []) do
    String.trim("""
    Explore and produce design directions for the ticket below.

    Invoke the `design` skill by name to explore and generate design directions. Produce exactly three distinct design directions on a single published canvas.

    You are designing the user interface, not implementing it: do NOT edit or touch any application code under lib/, test/, or anywhere in the repository.

    Take a still screenshot of each direction and save them under `$AXIS_SCRATCH/design/`. Use headless Chrome:
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless --disable-gpu --screenshot=$AXIS_SCRATCH/design/<still>.png --window-size=1280,800 <url>
    or wkhtmltoimage as fallback:
    wkhtmltoimage --width 1280 <url> $AXIS_SCRATCH/design/<still>.png

    Write the manifest to `$AXIS_SCRATCH/design/manifest.json` with this shape:
    {
      "canvasUrl": "<absolute https URL to the published canvas>",
      "version": 1,
      "directions": [
        {
          "key": "<unique-key>",
          "title": "<title of direction>",
          "notes": "<notes on what it does differently>",
          "stillPath": "$AXIS_SCRATCH/design/<still>.png"
        }
      ],
      "pickedKey": null
    }

    A human reviews the design directions and picks one before anything is planned. Stop once the design is published, the stills are captured, and the manifest is written.
    """)
  end

  @doc """
  Stage brief for the Architect role.
  """
  def architect_brief(opts \\ []) do
    design_section = architect_design_brief(opts)
    design_prefix = if design_section == "", do: "", else: "#{design_section}\n\n"
    plan_section = plan_write_brief(opts)

    String.trim("""
    Plan the implementation of the ticket below.

    #{design_prefix}Write the implementation plan to the plan file below, keeping the ticket's acceptance criteria as your contract. Stop at the plan - you do not write the code.

    #{plan_section}
    A human reviews your plan before any code is written, and may send it back to you with comments on this same conversation. When that happens, write the plan file again.
    """)
  end

  @doc """
  How the Architect writes its implementation plan into scratch.
  """
  def plan_write_brief(opts \\ []) do
    identifier =
      get_opt(opts, :identifier) ||
        get_opt(opts, :issue_identifier) ||
        get_opt(opts, :issue_number)

    if is_nil(identifier) or identifier == "" do
      "This task has no Linear issue, so there is nowhere to write the plan. Report that and stop: a target repository has to be set in Axis Settings before this stage can produce anything.\n"
    else
      file = "$AXIS_SCRATCH/plans/#{identifier}.md"

      String.trim_trailing("""
      The plan is Axis's local working document, stored beside the task rather than on Linear. The issue body is the ticket and is not yours to edit.

      From your worktree, with the heredoc body and its closing PLAN line at column zero:

      mkdir -p $AXIS_SCRATCH/plans
      cat > #{file} <<'PLAN'
      ## Implementation plan

      <the implementation plan: Approach, File-level changes, Slices, Risks, Decisions for review>
      PLAN

      Rules for that write:
      - The issue body is the ticket and is not yours to edit.
      - A heredoc into #{file}, never an inline string. The plan is markdown full of quotes, backticks and blank lines, and Axis captures it from this file when your run completes cleanly.
      - Keep the `## Implementation plan` heading at the top of the plan.
      - An ask you split out is a new issue of its own, never a second ticket inside this one:

      mkdir -p $AXIS_SCRATCH/tickets
      cat > $AXIS_SCRATCH/tickets/split-1.md <<'TICKET'
      # <title>

      <the split ticket body>
      TICKET

      Name any issue you opened in your report.
      """) <> "\n"
    end
  end

  @doc """
  Summarizes the approved design direction for the Architect.
  """
  def architect_design_brief(nil), do: ""
  def architect_design_brief([]), do: ""

  def architect_design_brief(design_or_opts) do
    design = extract_design(design_or_opts)

    case find_picked_direction(design) do
      {direction, canvas_url} ->
        title = get_field(direction, :title) || ""
        notes = get_field(direction, :notes) || ""
        still_path = get_field(direction, :still_path) || ""

        String.trim("""
        An approved design direction has been published for this ticket:
        - Title: #{title}
        - Notes: #{notes}
        - Canvas URL: #{canvas_url}
        - Still screenshot: #{still_path}
        Plan the implementation to match this design.
        """)

      nil ->
        ""
    end
  end

  @doc """
  Brief handed to the Designer when the human picks a direction.
  """
  def design_pick_brief(key_or_opts, opts \\ [])

  def design_pick_brief(key, opts) when is_binary(key) do
    title = get_opt(opts, :title) || resolve_direction_title(opts, key) || key

    String.trim("""
    The human picked direction "#{title}" (key: "#{key}").

    Narrow the published canvas to this single direction so the other directions no longer appear. Re-shoot the still for this direction under $AXIS_SCRATCH/design/ using a versioned filename reflecting this update (e.g. #{key}-v2.png). Update $AXIS_SCRATCH/design/manifest.json with an incremented version, the same canvasUrl, and this picked direction as the only direction in `directions`, with `pickedKey` set to "#{key}", and record the updated stillPath and notes.
    """)
  end

  def design_pick_brief(design_or_task, key) when is_binary(key) do
    design_pick_brief(key, design: design_or_task)
  end

  def design_pick_brief(opts, []) when is_list(opts) do
    key = get_opt(opts, :key) || "picked-direction"
    design_pick_brief(key, opts)
  end

  @doc """
  Brief handed to the Designer when revisions are requested on the picked design.
  """
  def design_revise_brief(comment) when is_binary(comment) do
    String.trim("""
    The human requested revisions to the picked design:

    #{comment}

    Revise the design on the canvas to incorporate this feedback. Re-shoot the still under $AXIS_SCRATCH/design/ using a versioned filename reflecting this update (e.g. <key>-v<version>.png). Update $AXIS_SCRATCH/design/manifest.json with an incremented version, keeping the same canvasUrl, and record the updated stillPath and notes for this direction.
    """)
  end

  @doc """
  Stage brief for the Engineer role.
  """
  def engineer_brief(_opts \\ []) do
    String.trim("""
    Implement the ticket and plan below, then open a draft pull request.

    Do not commit scratch files under $AXIS_SCRATCH/plans/ (or any scratch dir) into the pull request.

    Review comments, reviewer findings and QA findings on that pull request come back to you as further turns of this same conversation, so keep your worktree as you left it.
    """)
  end

  @doc """
  Stage brief for the Review role.
  """
  def review_brief(opts \\ []) do
    branch = get_opt(opts, :branch) || get_opt(opts, :worktree_name) || get_opt(opts, :branch_name)
    base = get_opt(opts, :base_branch) || "main"

    branch_line =
      if branch && branch != "" do
        "The change is on branch #{branch}; read it with `git diff #{base}...HEAD` from your worktree.\n"
      else
        ""
      end

    String.trim("""
    Review the implementation of the ticket below.

    #{branch_line}You are read-only: report what you find, do not fix it.

    Your last line is your verdict, exactly `VERDICT: APPROVED` or `VERDICT: CHANGES REQUESTED`, and it is read by the pipeline rather than by a human: CHANGES REQUESTED sends your findings straight back to the engineer and the change comes back to you when they are addressed, APPROVED hands it to QA. Do not approve a change with a blocker or high finding on it just to keep it moving; do not request changes over nits alone.
    """)
  end

  @doc """
  Stage brief for the QA role.
  """
  def qa_brief(opts \\ []) do
    branch = get_opt(opts, :branch) || get_opt(opts, :worktree_name) || get_opt(opts, :branch_name)

    branch_line =
      if branch && branch != "" do
        "The change is on branch #{branch}.\n"
      else
        ""
      end

    String.trim("""
    QA the implementation of the ticket below by driving the running app.

    #{branch_line}Exercise what the ticket asked for and report what a user would actually see.

    Leave every check provable: write your evidence to $AXIS_SCRATCH/qa/ with a manifest.json the QA Lead reads, and leave the app running with its VM service URL recorded there so the lead can attach rather than start over.

    Your last line is your verdict, exactly `VERDICT: PASS` or `VERDICT: FAIL`, and it is read by the pipeline rather than by a human: FAIL sends your findings straight back to the engineer, PASS hands your evidence to the QA Lead, who grades it and can still fail the change. Fail it for any blocker or major finding this change caused; nits and pre-existing problems are reported, not failed on.
    """)
  end

  @doc """
  Stage brief for the QA Lead role.
  """
  def qa_lead_brief(opts \\ []) do
    branch = get_opt(opts, :branch) || get_opt(opts, :worktree_name) || get_opt(opts, :branch_name)

    branch_line =
      if branch && branch != "" do
        "The change is on branch #{branch}.\n"
      else
        ""
      end

    String.trim("""
    Grade the QA pass on the ticket below.

    #{branch_line}The QA engineer's report is above and its evidence is in $AXIS_SCRATCH/qa/. You are not re-running its checklist: you are asking what it missed, which green rows its artifacts do not actually support, and whether the riskiest ground got covered at all - and you have the running app to settle any of that yourself.

    Your last line is your verdict, exactly `VERDICT: PASS` or `VERDICT: FAIL`, and it is read by the pipeline rather than by a human: FAIL sends your findings and QA's straight back to the engineer, PASS leaves the change ready to merge.
    """)
  end

  @doc """
  Stage brief for the Demo role.
  """
  def demo_brief(opts \\ []) do
    criteria = resolve_criteria(opts)

    criteria_section =
      if criteria == [] do
        "No criteria found in ticket. Capture evidence demonstrating the change."
      else
        criteria
        |> Enum.with_index(1)
        |> Enum.map_join("\n", fn {criterion, index} -> "#{index}. #{criterion}" end)
      end

    String.trim("""
    Record a demo of the ticket below working by driving the app on camera.

    You are recording evidence, not making changes: do NOT edit application code, never create branches, and never open PRs.

    Drive the running app according to your role instructions and capture still frames.

    Each part of the recording corresponds to an acceptance criterion from the ticket, in order:
    #{criteria_section}

    Write your frames into $AXIS_SCRATCH/demo/ and the manifest to $AXIS_SCRATCH/demo/manifest.json with this shape:
    {
      "version": 1,
      "outcome": "recorded",
      "segments": [
        {
          "criterionIndex": 1,
          "criterion": "<exact text from criterion 1>",
          "outcome": "recorded",
          "frames": [
            {
              "path": "$AXIS_SCRATCH/demo/<frame>.png",
              "holdMs": 1000,
              "caption": "<written caption explaining what is shown>"
            }
          ]
        }
      ]
    }

    For any criterion with no visible behavior, set outcome to "notFilmable" with a note explaining why rather than filming nothing. If recording fails for technical reasons, set outcome to "failed" with an explanatory note.

    Stop once the frames and manifest are written.
    """)
  end

  @doc """
  Brief handed to the Demo role when a demo re-record is requested.
  """
  def demo_rerecord_brief(comment_or_opts \\ [])

  def demo_rerecord_brief(comment) when is_binary(comment) do
    demo_rerecord_brief(comment: comment)
  end

  def demo_rerecord_brief(opts) do
    comment = get_opt(opts, :comment) || get_opt(opts, :reason)
    version = get_opt(opts, :version) || 2
    criteria = resolve_criteria(opts)

    criteria_section =
      if criteria == [] do
        "No criteria found in ticket. Capture evidence demonstrating the change."
      else
        criteria
        |> Enum.with_index(1)
        |> Enum.map_join("\n", fn {criterion, index} -> "#{index}. #{criterion}" end)
      end

    intro =
      if comment && comment != "" do
        String.trim("""
        The human requested that the demo be re-recorded:

        #{comment}

        Re-record the demo of the ticket below working by driving the app on camera.
        """)
      else
        "Re-record the demo of the ticket below working by driving the app on camera."
      end

    String.trim("""
    #{intro}

    You are recording evidence, not making changes: do NOT edit application code, never create branches, and never open PRs.

    Drive the running app according to your role instructions and capture still frames.

    Each part of the recording corresponds to an acceptance criterion from the ticket, in order:
    #{criteria_section}

    Write your frames into $AXIS_SCRATCH/demo/ and the manifest to $AXIS_SCRATCH/demo/manifest.json with this shape:
    {
      "version": #{version},
      "outcome": "recorded",
      "segments": [
        {
          "criterionIndex": 1,
          "criterion": "<exact text from criterion 1>",
          "outcome": "recorded",
          "frames": [
            {
              "path": "$AXIS_SCRATCH/demo/<frame>.png",
              "holdMs": 1000,
              "caption": "<written caption explaining what is shown>"
            }
          ]
        }
      ]
    }

    For any criterion with no visible behavior, set outcome to "notFilmable" with a note explaining why rather than filming nothing. If recording fails for technical reasons, set outcome to "failed" with an explanatory note.

    Stop once the frames and manifest are written.
    """)
  end

  @doc """
  What the Engineer is asked to do about conflicts during a rebase.
  """
  def rebase_brief(opts \\ []) do
    branch = get_opt(opts, :branch) || get_opt(opts, :worktree_name) || "this task's branch"
    base = get_opt(opts, :base_branch) || "main"
    pr_number = get_opt(opts, :pr_number)

    pr = if pr_number, do: "PR ##{pr_number}", else: "The pull request"

    String.trim("""
    #{pr} for #{branch} no longer merges into #{base}: the base branch has moved and your change now conflicts with it.

    Rebase the branch, in the worktree you already have, on the branch you already have checked out:
      git fetch origin #{base}
      git rebase origin/#{base}
    Resolve each conflict as it comes, `git add` the resolved files and `git rebase --continue`. Keep both sides' intent: never drop someone else's change to make the rebase go through, and never quietly revert your own. Where the two sides genuinely cannot both hold without a product decision, stop and ask with [QUESTION: ...] rather than guessing.

    Then run the project's checks from the top - the conflict is exactly where a silent breakage hides - and update the existing pull request:
      git push --force-with-lease origin #{branch}

    This is a rebase and nothing else. Do not implement anything new, do not address review findings, do not merge #{base} into the branch instead of rebasing, and do not open a second pull request. If the rebase cannot be finished, `git rebase --abort` so the branch is left as it was, and report why.

    Finish by saying what conflicted and how you resolved each one.
    """)
  end

  @doc """
  Brief describing the task worktree and Git branches.
  """
  def workspace_brief(opts \\ []) do
    worktree_path = get_opt(opts, :worktree_path)
    branch = get_opt(opts, :branch) || get_opt(opts, :worktree_name)

    if is_nil(worktree_path) or worktree_path == "" or is_nil(branch) or branch == "" do
      ""
    else
      base = get_opt(opts, :base_branch) || "main"
      identifier = get_opt(opts, :identifier) || get_opt(opts, :issue_identifier)
      role = get_opt(opts, :role) || get_opt(opts, :role_id)
      is_rebasing = get_opt(opts, :is_rebasing) || false
      title = get_opt(opts, :title) || ""

      ticket_line = if identifier && identifier != "", do: "- Ticket: #{identifier}\n", else: ""
      handover_section = workspace_handover(role, is_rebasing, branch, base, identifier, title)

      String.trim_trailing("""
      Workspace for this task:
      - Worktree: #{worktree_path} (your working directory; every path you touch is under it)
      - Branch: #{branch}, already checked out. It is named for this ticket - do NOT create a branch of your own, and do not rename this one.
      - Base branch: #{base} on remote `origin`
      #{ticket_line}- Other agents share this repository. Never switch branches, never work in the main checkout, and never touch another worktree.#{handover_section}
      """) <> "\n"
    end
  end

  defp dispatch_stage_brief(:product, opts), do: product_brief(opts)
  defp dispatch_stage_brief(:design, opts), do: design_brief(opts)
  defp dispatch_stage_brief(:architect, opts), do: architect_brief(opts)
  defp dispatch_stage_brief(:engineer, opts), do: engineer_brief(opts)
  defp dispatch_stage_brief(:review, opts), do: review_brief(opts)
  defp dispatch_stage_brief(:qa, opts), do: qa_brief(opts)
  defp dispatch_stage_brief(:qa_lead, opts), do: qa_lead_brief(opts)
  defp dispatch_stage_brief(:demo, opts), do: demo_brief(opts)
  defp dispatch_stage_brief(:ready_to_merge, _opts), do: ""
  defp dispatch_stage_brief(:merged, _opts), do: ""
  defp dispatch_stage_brief(_unknown, _opts), do: ""

  defp extract_design(opts) when is_list(opts), do: Keyword.get(opts, :design)
  defp extract_design(%{design: design}), do: design
  defp extract_design(%{"design" => design}), do: design
  defp extract_design(design), do: design

  defp find_picked_direction(design) when is_map(design) do
    canvas_url = get_field(design, :canvas_url) || ""
    picked_key = get_field(design, :picked_key)
    directions = get_field(design, :directions) || []

    direction =
      cond do
        picked_key != nil and picked_key != "" ->
          Enum.find(directions, fn d -> get_field(d, :key) == picked_key end)

        length(directions) == 1 ->
          hd(directions)

        true ->
          nil
      end

    if direction, do: {direction, canvas_url}
  end

  defp find_picked_direction(_other), do: nil

  defp workspace_handover(role, false, branch, base, identifier, title) when role in [:engineer, "engineer"] do
    sanitized_title = String.replace(title, "\"", "'")
    closes = if identifier && identifier != "", do: "Closes #{identifier}. ", else: ""

    """

    Hand the work over when every slice is done and the checks are green:
      git push -u origin #{branch}
      gh pr create --draft --base #{base} --head #{branch} --title "#{sanitized_title}" --body "#{closes}<what you built, the slices and their tests, check results, what you left out>"

    Push the branch above by name - `-u origin #{branch}` from inside your worktree - so the PR opens against the ticket's branch rather than a new one. This task is NOT done until `gh pr create` has returned a pull request URL. Committing is not handing over. If the push or the PR fails, report the exact command and its error rather than reporting success. Quote the PR URL in your final report. If a pull request for this branch already exists, push to it and say so instead of opening a second one.
    """
  end

  defp workspace_handover(_role, _is_rebasing, _branch, _base, _identifier, _title), do: ""

  defp resolve_direction_title(opts, key) do
    design = extract_design(opts)

    if is_map(design) do
      directions = get_field(design, :directions) || []

      case Enum.find(directions, fn d -> get_field(d, :key) == key end) do
        dir when is_map(dir) -> get_field(dir, :title)
        _nil -> nil
      end
    end
  end

  defp resolve_criteria(opts) do
    cond do
      criteria = get_opt(opts, :criteria) ->
        if is_list(criteria), do: criteria, else: []

      ticket = get_opt(opts, :ticket) || get_opt(opts, :description) ->
        if is_binary(ticket), do: Rail.Domain.TicketBody.acceptance_criteria(ticket), else: []

      true ->
        []
    end
  end

  defp extract_stage_and_opts(stage, opts) when is_atom(stage) do
    {stage, opts}
  end

  defp extract_stage_and_opts(stage_str, opts) when is_binary(stage_str) do
    stage =
      case stage_str do
        "product" -> :product
        "design" -> :design
        "architect" -> :architect
        "engineer" -> :engineer
        "review" -> :review
        "qa" -> :qa
        "qa_lead" -> :qa_lead
        "demo" -> :demo
        "ready_to_merge" -> :ready_to_merge
        "merged" -> :merged
        _other -> nil
      end

    {stage, opts}
  end

  defp extract_stage_and_opts(task, opts) when is_map(task) do
    stage_raw = get_field(task, :stage)
    {stage, _unused_opts} = extract_stage_and_opts(stage_raw, [])

    task_opts = [
      identifier: get_field(task, :identifier) || get_field(task, :issue_identifier),
      branch: get_field(task, :worktree_name) || get_field(task, :branch_name),
      is_rebasing: get_field(task, :is_rebasing),
      design: get_field(task, :design),
      ticket: get_field(task, :ticket) || get_field(task, :description),
      pr_number: get_field(task, :pr_number),
      title: get_field(task, :title)
    ]

    merged =
      task_opts
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Keyword.merge(opts)

    {stage, merged}
  end

  defp extract_stage_and_opts(_other, opts), do: {nil, opts}

  defp get_opt(opts, key) when is_list(opts) do
    Keyword.get(opts, key)
  end

  defp get_opt(opts, key) when is_map(opts) do
    get_field(opts, key)
  end

  defp get_opt(_other, _key), do: nil

  defp get_field(%_struct_mod{} = struct, field), do: Map.get(struct, field)

  defp get_field(map, field) when is_map(map) do
    case Map.fetch(map, field) do
      {:ok, val} ->
        val

      :error ->
        case Map.fetch(map, to_string(field)) do
          {:ok, val} -> val
          :error -> nil
        end
    end
  end
end
