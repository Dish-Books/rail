defmodule Rail.Git.Actions.ListRoundPaths do
  @moduledoc false

  import Rail.Git.Utils.WorkTree

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Tools

  @doc """
  The files a round changed on its own since `base`, sorted, as `{:ok, paths}`, or `{:error, :unreadable}` when git
  cannot say. A round that merged the default branch in is held to what the agents checking it read: its own commits'
  files, and what the merge changed in the files the branch had touched before the round. The rest of a merge is the
  default branch's own work, already checked there.
  """
  def list_round_paths(%Task{} = task, change) do
    case work_tree(task) do
      %{repo: repo, head: head} -> paths(task, repo, head, change)
      nil -> {:error, :unreadable}
    end
  end

  defp paths(%Task{}, repo, head, %{base: base, merged: false}) do
    with {:ok, paths} <- names(repo, ["diff", "--name-only", "-z", base, head]), do: {:ok, Enum.sort(paths)}
  end

  defp paths(%Task{} = task, repo, head, %{base: base, merged: true}) do
    %Project{default_branch: default_branch} = Repo.get(Project, task.project_id)

    # The first parent is the branch's own line, so commits the merge brought in are left out.
    with {:ok, own} <-
           names(repo, ["log", "--first-parent", "--no-merges", "--format=", "--name-only", "-z", "#{base}..#{head}"]),
         {:ok, touched} <- names(repo, ["diff", "--name-only", "-z", "origin/#{default_branch}...#{base}"]),
         {:ok, merged} <- names(repo, ["diff", "--name-only", "-z", base, head]) do
      {:ok, Enum.sort(Enum.uniq(own ++ Enum.filter(merged, &(&1 in touched))))}
    end
  end

  # `log` ends each commit's names with a newline as well as the NUL.
  defp names(repo, args) do
    case Tools.run("git", args, cd: repo, stderr_to_stdout: true) do
      {output, 0} ->
        names = output |> String.split(<<0>>) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
        {:ok, names}

      _unreadable ->
        {:error, :unreadable}
    end
  end
end
