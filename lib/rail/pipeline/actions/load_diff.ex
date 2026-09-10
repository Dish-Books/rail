defmodule Rail.Pipeline.Actions.LoadDiff do
  @moduledoc false

  alias Rail.Domain.Diff.UnifiedDiffParser
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Loads and parses the diff for the task's worktree.
  Reconciles viewed diff marks against the parsed files.
  Returns `{:ok, parsed_files, diff_rev}` or `{:error, reason}`.
  """
  def load_diff(scope_or_task, task_or_opts \\ nil)

  def load_diff(%Task{} = task, _opts) do
    do_load_diff(task)
  end

  def load_diff(_scope, %Task{} = task) do
    do_load_diff(task)
  end

  defp do_load_diff(%Task{worktree_path: nil}), do: {:error, :no_worktree}

  defp do_load_diff(%Task{worktree_path: worktree_path} = task) when is_binary(worktree_path) do
    changes = Rail.Git.get_worktree_changes(worktree_path)

    {filter, diff_rev} =
      if changes.filter in [:main, "main"] do
        {:main, "HEAD"}
      else
        {:uncommitted, nil}
      end

    diff_text = Rail.Git.get_diff(worktree_path, filter: filter)
    parsed_files = UnifiedDiffParser.parse(diff_text)

    {:ok, _reconciled_task} = Rail.Pipeline.reconcile_viewed_diff_files(task, parsed_files)

    {:ok, parsed_files, diff_rev}
  end
end
