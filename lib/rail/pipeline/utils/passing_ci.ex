defmodule Rail.Pipeline.Utils.PassingCi do
  @moduledoc false

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  The last CI run on `task` when it passed against the commit its worktree is on
  now, or nil. A pass for an earlier commit says nothing about this one.
  """
  def passing_ci(%Task{} = task) do
    case Tools.list_os_processes(task_id: task.id, kind: :ci) do
      [%OsProcess{exit_code: 0, head_sha: head_sha} = os_process | _earlier] when is_binary(head_sha) ->
        if match?(%{head_sha: ^head_sha}, Git.branch_fingerprint(task.worktree_path)), do: os_process

      _never_or_not_passing ->
        nil
    end
  end
end
