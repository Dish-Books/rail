defmodule Rail.Git.Actions.LoadDiff do
  @moduledoc """
  Everything a diff pane needs to draw a task's worktree, in one call.

  Two views, because the two questions are different. `:branch` is everything the
  branch did against the base it forked from, committed or not, which is what
  review means. `:uncommitted` is only what has not been committed yet, which is
  what "what has the engineer changed since I last looked" means. Untracked files
  are written into both by hand: git will not diff a file it has never seen, but
  the human still has to read it.

  The files come back already parsed into rows and already marked with whether
  this reader has read them, because there is nothing a caller would do with the
  halves separately.
  """

  import Rail.Git.Utils.ParseDiff

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Tools

  @doc """
  Loads `task`'s diff under `filter` for `scope`.

  Returns `{:ok, files}`, or `{:error, :no_worktree}` once the worktree has been
  cleaned up, since the change only ever existed on disk.
  """
  def load_diff(%Scope{} = scope, %Task{} = task, filter \\ :branch) do
    if Task.worktree_present?(task) do
      viewed = Git.list_viewed_files(scope, task)

      files =
        task
        |> raw_diff(filter)
        |> parse_diff()
        |> Enum.map(&Map.put(&1, :viewed?, Map.get(viewed, &1.path) == &1.digest))

      {:ok, files}
    else
      {:error, :no_worktree}
    end
  end

  defp raw_diff(%Task{worktree_path: worktree_path} = task, filter) do
    tracked(worktree_path, filter, base_branch(task)) <> untracked(worktree_path)
  end

  # Every project is required to name a default branch, so there is nothing to
  # fall back to: a project that cannot be read is a broken invariant.
  defp base_branch(%Task{project_id: project_id}) do
    %Project{default_branch: default_branch} = Repo.get(Project, project_id)

    default_branch
  end

  defp tracked(worktree_path, :uncommitted, _base), do: diff(worktree_path, ["diff", "HEAD"])

  # Diffing from the merge base rather than from the base branch's tip keeps the
  # base moving ahead out of the picture: what shows is what this branch did.
  defp tracked(worktree_path, :branch, base) do
    case Tools.run("git", ["merge-base", base, "HEAD"], cd: worktree_path, stderr_to_stdout: true) do
      {output, 0} -> diff(worktree_path, ["diff", String.trim(output)])
      _no_merge_base -> diff(worktree_path, ["diff", "HEAD"])
    end
  end

  defp diff(worktree_path, args) do
    case Tools.run("git", args, cd: worktree_path, stderr_to_stdout: true) do
      {output, 0} -> output
      _unreadable -> ""
    end
  end

  defp untracked(worktree_path) do
    case Tools.run("git", ["ls-files", "--others", "--exclude-standard"],
           cd: worktree_path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output
        |> String.split(~r/\r?\n/)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or String.starts_with?(&1, ".rail/")))
        |> Enum.map_join("", &synthesize(worktree_path, &1))

      _unreadable ->
        ""
    end
  end

  # The patch git will not write: a file it has never seen, added whole.
  defp synthesize(worktree_path, path) do
    case worktree_path |> Path.join(path) |> File.read() do
      {:ok, bytes} -> patch(path, bytes)
      {:error, _unreadable} -> ""
    end
  end

  defp patch(path, bytes) do
    header = "diff --git a/#{path} b/#{path}\nnew file (untracked)\n"

    if String.contains?(bytes, <<0>>) do
      header <> "Binary file #{path} differs\n"
    else
      lines = lines(bytes)

      header <>
        "--- /dev/null\n+++ b/#{path}\n@@ -0,0 +1,#{length(lines)} @@\n" <>
        Enum.map_join(lines, "", &"+#{&1}\n")
    end
  end

  defp lines(bytes) do
    case String.split(bytes, ~r/\r?\n/) do
      [""] -> []
      list -> if List.last(list) == "", do: Enum.slice(list, 0..-2//1), else: list
    end
  end
end
