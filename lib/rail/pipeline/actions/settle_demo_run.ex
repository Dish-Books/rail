defmodule Rail.Pipeline.Actions.SettleDemoRun do
  @moduledoc """
  Settles a finished demo-stage run.

  The recording is only evidence if the worktree it was made from has not moved
  since, so that is checked before anything is captured. A manifest that reports
  a failed recording is still captured — the frames it did get are what a human
  looks at — but the stage stays on demo and fails.
  """

  import Rail.Pipeline.Utils.AdvanceStage

  alias Rail.Artifacts
  alias Rail.Domain.TicketBody
  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  @doc "Settles the finished demo `run` against `outcome`."
  def settle_demo_run(%Run{} = run, _outcome \\ %{}, opts \\ []) do
    advance_stage(run, opts, &capture_demo/3)
  end

  defp capture_demo(%Task{scratch_path: scratch_dir} = task, role_run, opts) do
    scope = Scope.for_system()
    criteria = resolve_criteria(task, opts)
    read_opts = opts |> Keyword.take([:req_options]) |> Keyword.put(:criteria, criteria)

    with {:ok, manifest} <- Artifacts.read_demo(scope, scratch_dir, read_opts),
         :ok <- validate_worktree_stability(task, role_run) do
      capture_opts = build_capture_opts(task, role_run, opts, criteria)

      case manifest.outcome do
        outcome when outcome in ["recorded", "declined"] ->
          advance_captured(scope, task, role_run, scratch_dir, capture_opts)

        "failed" ->
          advance_failed(scope, task, role_run, scratch_dir, manifest, capture_opts)
      end
    else
      {:error, reason} ->
        error = if is_binary(reason), do: reason, else: inspect(reason)

        {%{stage_state: :failed, error: error, retry_after: nil}, role_run}
    end
  end

  defp advance_captured(scope, task, role_run, scratch_dir, capture_opts) do
    case Artifacts.capture_demo(scope, task, scratch_dir, capture_opts) do
      {:ok, _demo} ->
        {:ok, role_run} = role_run |> RoleRun.changeset(%{auto_retries: 0}) |> Repo.update()

        attrs = %{
          stage: :ready_to_merge,
          stage_state: :awaiting_approval,
          retry_after: nil,
          error: nil
        }

        {attrs, role_run}

      {:error, reason} ->
        error = if is_binary(reason), do: reason, else: inspect(reason)

        {%{stage_state: :failed, error: error, retry_after: nil}, role_run}
    end
  end

  defp advance_failed(scope, task, role_run, scratch_dir, manifest, capture_opts) do
    _capture_result = Artifacts.capture_demo(scope, task, scratch_dir, capture_opts)

    {:ok, role_run} = role_run |> RoleRun.changeset(%{auto_retries: 0}) |> Repo.update()

    attrs = %{
      stage: :demo,
      stage_state: :failed,
      error: manifest.note || "Demo recording failed.",
      retry_after: nil
    }

    {attrs, role_run}
  end

  defp resolve_criteria(%Task{} = task, opts) do
    case Keyword.get(opts, :criteria) do
      explicit when explicit != nil ->
        explicit

      nil ->
        case TicketBody.acceptance_criteria(issue_description(task) || "") do
          list when is_list(list) and list != [] -> list
          _empty -> nil
        end
    end
  end

  defp build_capture_opts(task, role_run, opts, criteria) do
    {head_sha, dirty_digest} = fingerprint(task, role_run)
    issue = Keyword.get(opts, :issue) || (task.issue_id && Repo.get(Issue, task.issue_id))
    owner_user = Keyword.get(opts, :owner_user) || (issue && issue.owner_user_id && Repo.get(User, issue.owner_user_id))

    opts
    |> Keyword.take([:req_options])
    |> Keyword.put(:criteria, criteria)
    |> Keyword.put(:head_sha, head_sha)
    |> Keyword.put(:commit, head_sha)
    |> Keyword.put(:dirty_digest, dirty_digest)
    |> Keyword.put(:issue, issue)
    |> Keyword.put(:owner_user, owner_user)
  end

  defp validate_worktree_stability(%Task{worktree_path: path}, role_run) when is_binary(path) and path != "" do
    if File.dir?(path) and
         (role_run.stage_fingerprint_head_sha != nil or role_run.stage_fingerprint_dirty_digest != nil) do
      compare_fingerprint(Git.branch_fingerprint(path), role_run)
    else
      :ok
    end
  end

  defp validate_worktree_stability(_task, _role_run), do: :ok

  defp compare_fingerprint(%{head_sha: current_sha, dirty_digest: current_digest}, role_run) do
    cond do
      role_run.stage_fingerprint_head_sha != nil and current_sha != role_run.stage_fingerprint_head_sha ->
        {:error, "The worktree moved during the demo run."}

      role_run.stage_fingerprint_dirty_digest != nil and current_digest != role_run.stage_fingerprint_dirty_digest ->
        {:error, "Worktree code outside .rail/ was modified during recording."}

      true ->
        :ok
    end
  end

  defp compare_fingerprint(_no_fingerprint, _role_run), do: :ok

  defp fingerprint(%Task{worktree_path: path}, role_run) when is_binary(path) and path != "" do
    if File.dir?(path) do
      case Git.branch_fingerprint(path) do
        %{head_sha: sha, dirty_digest: digest} -> {sha, digest}
        _none -> {role_run.stage_fingerprint_head_sha, role_run.stage_fingerprint_dirty_digest}
      end
    else
      {role_run.stage_fingerprint_head_sha, role_run.stage_fingerprint_dirty_digest}
    end
  end

  defp fingerprint(_task, role_run) do
    {role_run.stage_fingerprint_head_sha, role_run.stage_fingerprint_dirty_digest}
  end

  # The ticket body lives on the issue; the task only links to it.
  defp issue_description(%Task{issue: %Issue{description: description}}), do: description

  defp issue_description(%Task{issue_id: issue_id}) when is_binary(issue_id) do
    case Repo.get(Issue, issue_id) do
      %Issue{description: description} -> description
      nil -> nil
    end
  end

  defp issue_description(%Task{}), do: nil
end
