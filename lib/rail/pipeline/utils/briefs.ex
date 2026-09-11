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
  Stage brief for the Design role.
  """
  def design_brief(_opts \\ []) do
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
  end

  @doc """
  Stage brief for the Architect role.
  """
  def architect_brief(opts \\ []) do
    design_section = architect_design_brief(opts)
    design_prefix = if design_section == "", do: "", else: "#{design_section}\n\n"
    plan_section = plan_write_brief(opts)

    String.trim("""
    #{design_prefix}#{plan_section}
    Review comments come back as further turns of this same conversation. When that happens, write the plan file again.
    """)
  end

  @doc """
  How the Architect writes its implementation plan into scratch.
  """
  def plan_write_brief(opts \\ []) do
    file = "$RAIL_SCRATCH/plans/#{resolve_identifier(opts)}.md"

    String.trim("""
    The plan is the file #{file}. Rail captures it when your run completes cleanly. The ticket itself is not yours to write.

    Write it from your worktree with a heredoc, the body and its closing PLAN line at column zero:

    mkdir -p $RAIL_SCRATCH/plans
    cat > #{file} <<'PLAN'
    ## Implementation plan

    <the implementation plan>
    PLAN

    - A heredoc into #{file}, never an inline string.
    - Keep the `## Implementation plan` heading on the first line.
    - A ticket you split out is its own file, $RAIL_SCRATCH/tickets/split-<n>.md, with `---` front matter carrying its `title`. Rail opens each one as a new ticket.
    """)
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
        The approved design direction for this ticket:
        - Title: #{title}
        - Notes: #{notes}
        - Canvas URL: #{canvas_url}
        - Still screenshot: #{still_path}
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

    Re-shoot its still under $RAIL_SCRATCH/design/ with a new versioned filename (e.g. #{key}-v2.png), and rewrite $RAIL_SCRATCH/design/manifest.json with an incremented `version`, the same `canvasUrl`, `pickedKey` set to "#{key}", and this direction as the only entry in `directions`, carrying the updated `stillPath` and `notes`.
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

    Re-shoot the still under $RAIL_SCRATCH/design/ with a new versioned filename (e.g. <key>-v<version>.png), and rewrite $RAIL_SCRATCH/design/manifest.json with an incremented `version`, the same `canvasUrl`, and the updated `stillPath` and `notes` for this direction.
    """)
  end

  @doc """
  Stage brief for the Engineer role.
  """
  def engineer_brief(_opts \\ []) do
    String.trim("""
    Never commit anything under $RAIL_SCRATCH into the pull request.

    Review comments, reviewer findings and QA findings come back as further turns of this same conversation, so keep your worktree as you left it.
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
    #{branch_line}Rail reads your last line as your verdict, exactly `VERDICT: APPROVED` or `VERDICT: CHANGES REQUESTED`. CHANGES REQUESTED sends your findings back to the engineer and returns the change to you once they are addressed; APPROVED hands it to QA.
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
    #{branch_line}Write your evidence to $RAIL_SCRATCH/qa/ with a manifest.json, and leave the app running with its VM service URL recorded there so the QA Lead can attach to it.

    Rail reads your last line as your verdict, exactly `VERDICT: PASS` or `VERDICT: FAIL`. FAIL sends your findings back to the engineer; PASS hands your evidence to the QA Lead.
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
    #{branch_line}The QA engineer's report is above and its evidence is in $RAIL_SCRATCH/qa/, with the running app reachable at the VM service URL recorded there.

    Rail reads your last line as your verdict, exactly `VERDICT: PASS` or `VERDICT: FAIL`. FAIL sends your findings and QA's back to the engineer; PASS leaves the change ready to merge.
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
    Never edit application code, create a branch or open a pull request on this stage.

    Each part of the recording corresponds to an acceptance criterion from the ticket, in order:
    #{criteria_section}

    Rail reads the recording from $RAIL_SCRATCH/demo/. Write your frames there and the manifest to $RAIL_SCRATCH/demo/manifest.json with this shape:
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
              "path": "$RAIL_SCRATCH/demo/<frame>.png",
              "holdMs": 1000,
              "caption": "<written caption explaining what is shown>"
            }
          ]
        }
      ]
    }

    For any criterion with no visible behavior, set outcome to "notFilmable" with a note saying why. If recording fails, set outcome to "failed" with a note.
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

        Re-record the demo.
        """)
      else
        "Re-record the demo."
      end

    String.trim("""
    #{intro}

    Never edit application code, create a branch or open a pull request on this stage.

    Each part of the recording corresponds to an acceptance criterion from the ticket, in order:
    #{criteria_section}

    Rail reads the recording from $RAIL_SCRATCH/demo/. Write your frames there and the manifest to $RAIL_SCRATCH/demo/manifest.json with this shape:
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
              "path": "$RAIL_SCRATCH/demo/<frame>.png",
              "holdMs": 1000,
              "caption": "<written caption explaining what is shown>"
            }
          ]
        }
      ]
    }

    For any criterion with no visible behavior, set outcome to "notFilmable" with a note saying why. If recording fails, set outcome to "failed" with a note.
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
    #{pr} for #{branch} no longer merges into #{base}. Rebase the branch in the worktree you already have:
      git fetch origin #{base}
      git rebase origin/#{base}

    Update the existing pull request rather than opening a second one:
      git push --force-with-lease origin #{branch}

    This run is a rebase and nothing else: implement nothing new, address no review findings, and do not merge #{base} into the branch instead of rebasing. If the rebase cannot be finished, `git rebase --abort` so the branch is left as it was, and report why. To ask the human a question rather than guess, put `[QUESTION: ...]` on its own line, optionally followed by `[OPTIONS: a, b]`.
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

  defp resolve_identifier(opts) do
    get_opt(opts, :identifier) || get_opt(opts, :issue_identifier) || get_opt(opts, :issue_number)
  end

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
