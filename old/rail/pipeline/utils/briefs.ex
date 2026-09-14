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
  Stage brief for the Architect role.
  """
  def architect_brief(opts \\ []) do
    plan_section = plan_write_brief(opts)

    String.trim("""
    #{plan_section}
    Review comments come back as further turns of this same conversation. When that happens, write the plan file again.
    """)
  end

  @doc """
  How the Architect writes its implementation plan into scratch.
  """
  def plan_write_brief(opts \\ []) do
    file = "#{scratch(opts)}/plans/#{resolve_identifier(opts)}.md"

    String.trim("""
    The plan is the file #{file}. Rail captures it when your run completes cleanly. The ticket itself is not yours to write.

    Write it from your worktree with a heredoc, the body and its closing PLAN line at column zero:

    mkdir -p #{scratch(opts)}/plans
    cat > #{file} <<'PLAN'
    ## Implementation plan

    <the implementation plan>
    PLAN

    - A heredoc into #{file}, never an inline string.
    - Keep the `## Implementation plan` heading on the first line.
    """)
  end

  @doc """
  Stage brief for the Engineer role.
  """
  def engineer_brief(opts \\ []) do
    String.trim("""
    Never put anything under #{scratch(opts)} into the change itself - it is your workspace, not part of the deliverable.

    Leave your work in the worktree as files. Do not commit, push, or open a pull request - Rail takes the worktree from here.

    Review comments, reviewer findings and QA findings come back as further turns of this same conversation, so keep your worktree as you left it.

    Rail reads your last line as your verdict, exactly `VERDICT: DONE`, and only once you say it does the change go to review. Say it when the work is actually finished and not before: if you stop part way, for a question or anything else, leave the verdict off and the task waits for you rather than moving on without you.
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
    #{branch_line}Write your evidence to #{scratch(opts)}/qa/ with a manifest.json, and leave the app running with its VM service URL recorded there so the QA Lead can attach to it.

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
    #{branch_line}The QA engineer's report is above and its evidence is in #{scratch(opts)}/qa/, with the running app reachable at the VM service URL recorded there.

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

    Rail reads the recording from #{scratch(opts)}/demo/. Write your frames there and the manifest to #{scratch(opts)}/demo/manifest.json with this shape:
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
              "path": "#{scratch(opts)}/demo/<frame>.png",
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
  def demo_rerecord_brief(comment_or_opts, opts \\ [])

  def demo_rerecord_brief(comment, opts) when is_binary(comment) do
    demo_rerecord_brief(Keyword.put(opts, :comment, comment), [])
  end

  def demo_rerecord_brief(opts, _extra) do
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

    Rail reads the recording from #{scratch(opts)}/demo/. Write your frames there and the manifest to #{scratch(opts)}/demo/manifest.json with this shape:
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
              "path": "#{scratch(opts)}/demo/<frame>.png",
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

      ticket_line = if identifier && identifier != "", do: "- Ticket: #{identifier}\n", else: ""

      String.trim_trailing("""
      Workspace for this task:
      - Worktree: #{worktree_path} (your working directory; every path you touch is under it)
      - Branch: #{branch}, already checked out. It is named for this ticket - do NOT create a branch of your own, and do not rename this one.
      - Base branch: #{base} on remote `origin`
      #{ticket_line}- Other agents share this repository. Never switch branches, never work in the main checkout, and never touch another worktree.
      """) <> "\n"
    end
  end

  defp resolve_identifier(opts) do
    get_opt(opts, :identifier) || get_opt(opts, :issue_identifier) || get_opt(opts, :issue_number)
  end

  defp dispatch_stage_brief(:architect, opts), do: architect_brief(opts)
  defp dispatch_stage_brief(:engineer, opts), do: engineer_brief(opts)
  defp dispatch_stage_brief(:review, opts), do: review_brief(opts)
  defp dispatch_stage_brief(:qa, opts), do: qa_brief(opts)
  defp dispatch_stage_brief(:qa_lead, opts), do: qa_lead_brief(opts)
  defp dispatch_stage_brief(:demo, opts), do: demo_brief(opts)
  defp dispatch_stage_brief(:ready_to_merge, _opts), do: ""
  defp dispatch_stage_brief(:merged, _opts), do: ""
  defp dispatch_stage_brief(_unknown, _opts), do: ""

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
      identifier: get_field(task, :identifier) || get_field(task, :issue_identifier) || issue_field(task, :identifier),
      branch: get_field(task, :worktree_name) || get_field(task, :branch_name),
      is_rebasing: get_field(task, :is_rebasing),
      scratch_path: get_field(task, :scratch_path),
      ticket: get_field(task, :ticket) || get_field(task, :description) || issue_field(task, :description),
      pr_number: get_field(task, :pr_number),
      title: get_field(task, :title) || issue_field(task, :title)
    ]

    merged =
      task_opts
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Keyword.merge(opts)

    {stage, merged}
  end

  defp extract_stage_and_opts(_other, opts), do: {nil, opts}

  # Every brief names scratch paths absolutely; the task carries the directory.
  defp scratch(opts), do: get_opt(opts, :scratch_path)

  defp get_opt(opts, key) when is_list(opts) do
    Keyword.get(opts, key)
  end

  defp get_opt(opts, key) when is_map(opts) do
    get_field(opts, key)
  end

  defp get_opt(_other, _key), do: nil

  # The title and ticket body live on the issue the task links to.
  defp issue_field(task, field), do: get_field(get_field(task, :issue), field)

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

  defp get_field(_other, _field), do: nil
end
