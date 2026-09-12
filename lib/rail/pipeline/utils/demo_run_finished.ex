defmodule Rail.Pipeline.Utils.DemoRunFinished do
  @moduledoc """
  Where a finished demo run leaves its task.

  The recording is only evidence if the worktree it was made from has not moved
  since, so that is checked before anything is captured. A manifest that reports a
  failed recording is still captured — the frames it did get are what a human
  looks at — but the failure is recorded on the run and the task stays on demo.
  """

  alias Rail.Artifacts
  alias Rail.Domain.TicketBody
  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Runs.Schemas.Run
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  @doc "Finishes `run` as the demo stage."
  def demo_run_finished(%Run{task: %Task{scratch_path: scratch_dir} = task} = run, opts) do
    scope = Scope.for_system()
    criteria = resolve_criteria(task, opts)
    read_opts = opts |> Keyword.take([:req_options]) |> Keyword.put(:criteria, criteria)

    with {:ok, manifest} <- Artifacts.read_demo(scope, scratch_dir, read_opts),
         :ok <- validate_worktree_stability(task, run) do
      capture_opts = build_capture_opts(task, run, opts, criteria)

      case manifest.outcome do
        outcome when outcome in ["recorded", "declined"] ->
          capture(scope, task, run, scratch_dir, capture_opts, opts)

        "failed" ->
          _capture_result = Artifacts.capture_demo(scope, task, scratch_dir, capture_opts)
          fail(run, manifest.note || "Demo recording failed.")
      end
    else
      {:error, reason} -> fail(run, reason)
    end
  end

  defp capture(scope, %Task{} = task, %Run{} = run, scratch_dir, capture_opts, opts) do
    case Artifacts.capture_demo(scope, task, scratch_dir, capture_opts) do
      {:ok, _demo} ->
        Pipeline.enter_stage(task, :ready_to_merge, opts)
        run

      {:error, reason} ->
        fail(run, reason)
    end
  end

  defp fail(%Run{task: task} = run, reason) do
    error = if is_binary(reason), do: reason, else: inspect(reason)
    {:ok, run} = run |> Run.changeset(%{error: error}) |> Repo.update()
    %{run | task: task}
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

  defp build_capture_opts(task, run, opts, criteria) do
    {head_sha, dirty_digest} = fingerprint(task, run)
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

  defp validate_worktree_stability(%Task{worktree_path: path}, run) when is_binary(path) and path != "" do
    if File.dir?(path) and
         (run.stage_fingerprint_head_sha != nil or run.stage_fingerprint_dirty_digest != nil) do
      compare_fingerprint(Git.branch_fingerprint(path), run)
    else
      :ok
    end
  end

  defp validate_worktree_stability(_task, _run), do: :ok

  defp compare_fingerprint(%{head_sha: current_sha, dirty_digest: current_digest}, run) do
    cond do
      run.stage_fingerprint_head_sha != nil and current_sha != run.stage_fingerprint_head_sha ->
        {:error, "The worktree moved during the demo run."}

      run.stage_fingerprint_dirty_digest != nil and current_digest != run.stage_fingerprint_dirty_digest ->
        {:error, "Worktree code outside .rail/ was modified during recording."}

      true ->
        :ok
    end
  end

  defp compare_fingerprint(_no_fingerprint, _run), do: :ok

  defp fingerprint(%Task{worktree_path: path}, run) when is_binary(path) and path != "" do
    if File.dir?(path) do
      case Git.branch_fingerprint(path) do
        %{head_sha: sha, dirty_digest: digest} -> {sha, digest}
        _none -> {run.stage_fingerprint_head_sha, run.stage_fingerprint_dirty_digest}
      end
    else
      {run.stage_fingerprint_head_sha, run.stage_fingerprint_dirty_digest}
    end
  end

  defp fingerprint(_task, run) do
    {run.stage_fingerprint_head_sha, run.stage_fingerprint_dirty_digest}
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
