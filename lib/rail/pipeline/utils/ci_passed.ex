defmodule Rail.Pipeline.Utils.CiPassed do
  @moduledoc false

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  True when the last CI run on `task` passed, against the commit its worktree is
  on now. A pass for an earlier commit says nothing about this one.
  """
  def ci_passed?(%Task{} = task) do
    case Tools.list_os_processes(task_id: task.id, kind: :ci) do
      [%OsProcess{exit_code: 0, head_sha: head_sha} | _earlier] when is_binary(head_sha) ->
        match?(%{head_sha: ^head_sha}, Git.branch_fingerprint(task.worktree_path))

      _never_or_not_passing ->
        false
    end
  end
end
