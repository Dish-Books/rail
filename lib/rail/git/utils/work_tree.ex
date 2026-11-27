defmodule Rail.Git.Utils.WorkTree do
  @moduledoc false

  import Rail.Git.Utils.TaskBranch

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  @wip "refs/rail/wip"

  @doc """
  Brings `task`'s repository up to date with its checkout, then says where it stands: `%{repo:, branch:, head:,
  work:}`, the repository's path, the branch's ref, the commit the branch is at, and the commit whose tree is the
  checkout's working tree. That is `refs/rail/wip` while it sits on the branch, and the branch itself otherwise. Nil
  when the repository has no such branch.
  """
  def work_tree(%Task{} = task) do
    _synced = Git.sync_checkout(task)
    repo = Task.repo_path(task)
    branch = "refs/heads/" <> task_branch(task)

    case Tools.run("git", ["for-each-ref", "--format=%(refname) %(objectname) %(parent)", branch, @wip],
           cd: repo,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        refs = for line <- String.split(output, "\n", trim: true), into: %{}, do: ref(line)

        case refs do
          %{^branch => {head, _parents}} -> %{repo: repo, branch: branch, head: head, work: work(refs, head)}
          %{} -> nil
        end

      {_output, _unreadable} ->
        nil
    end
  end

  defp ref(line) do
    [name, sha | parents] = String.split(line, " ", trim: true)
    {name, {sha, parents}}
  end

  # A wip left from an earlier head is no longer the checkout's, so the branch stands for it.
  defp work(%{@wip => {wip, [head]}}, head), do: wip
  defp work(_refs, head), do: head
end
