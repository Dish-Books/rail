defmodule Rail.Git.Actions.LoadDiff do
  @moduledoc """
  Everything a diff pane needs to draw a task's worktree, in one call.

  Two views, because the two questions are different. `:branch` is everything the
  branch did against the base it forked from, committed or not, which is what
  review means. `:uncommitted` is only what has not been committed yet, which is
  what "what has the engineer changed since I last looked" means. Untracked files
  are written into both by hand: git will not diff a file it has never seen, but
  the human still has to read it.

  The files come back already parsed into rows, already highlighted and already
  marked with whether this reader has read them, because there is nothing a
  caller would do with the halves separately. A file whose digest has not moved
  since `previous_files` keeps the rows it was highlighted into there.
  """

  import Rail.Git.Utils.BranchBase
  import Rail.Git.Utils.HighlightLines
  import Rail.Git.Utils.ParseDiff
  import Rail.Git.Utils.UntrackedPaths

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Scope
  alias Rail.Tools

  @doc """
  Loads `task`'s diff under `filter` for `scope`.

  Returns `{:ok, files}`, or `{:error, :no_worktree}` once the worktree has been
  cleaned up, since the change only ever existed on disk.
  """
  def load_diff(%Scope{} = scope, %Task{} = task, filter \\ :branch, previous_files \\ []) do
    if Task.worktree_present?(task) do
      viewed = Git.list_viewed_files(scope, task)
      drawn = Map.new(previous_files, &{{&1.path, &1.digest}, &1.rows})
      parsed = task |> raw_diff(filter) |> parse_diff()

      highlighted =
        parsed
        |> Enum.reject(&Map.has_key?(drawn, {&1.path, &1.digest}))
        |> Elixir.Task.async_stream(&highlight/1,
          ordered: true,
          max_concurrency: System.schedulers_online(),
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, file} -> file end)

      {files, []} = Enum.map_reduce(parsed, highlighted, &draw(&1, &2, drawn))

      {:ok, Enum.map(files, &Map.put(&1, :viewed?, Map.get(viewed, &1.path) == &1.digest))}
    else
      {:error, :no_worktree}
    end
  end

  # Kept rows are put back here rather than in the tasks, so they stay the terms
  # the caller already holds instead of copies made on the way out and back.
  defp draw(file, highlighted, drawn) do
    case Map.fetch(drawn, {file.path, file.digest}) do
      {:ok, rows} -> {%{file | rows: rows}, highlighted}
      :error -> {hd(highlighted), tl(highlighted)}
    end
  end

  # Each side of the file is highlighted as its own piece of code, then handed
  # back to the rows it came from in the order they were taken.
  defp highlight(%{rows: rows, path: path} = file) do
    old = Enum.filter(rows, &side?(&1, :deleted))
    new = Enum.filter(rows, &side?(&1, :added))

    %{file | rows: stamp(rows, highlighted(old, path), highlighted(new, path))}
  end

  defp side?(%{kind: :line, line_kind: line_kind}, changed), do: line_kind in [:context, changed]
  defp side?(_row, _changed), do: false

  defp highlighted(rows, path), do: rows |> Enum.map(& &1.text) |> highlight_lines(path)

  defp stamp([], _old, _new), do: []

  defp stamp([%{kind: :line, line_kind: :deleted} = row | rows], [html | old], new),
    do: [Map.put(row, :html, html) | stamp(rows, old, new)]

  defp stamp([%{kind: :line, line_kind: :added} = row | rows], old, [html | new]),
    do: [Map.put(row, :html, html) | stamp(rows, old, new)]

  defp stamp([%{kind: :line, line_kind: :context} = row | rows], [_old_side | old], [html | new]),
    do: [Map.put(row, :html, html) | stamp(rows, old, new)]

  defp stamp([row | rows], old, new), do: [row | stamp(rows, old, new)]

  defp raw_diff(%Task{worktree_path: worktree_path} = task, filter) do
    tracked(task, filter) <> Enum.map_join(untracked_paths(worktree_path), "", &synthesize(worktree_path, &1))
  end

  defp tracked(%Task{worktree_path: worktree_path}, :uncommitted), do: diff(worktree_path, ["diff", "HEAD"])
  defp tracked(%Task{worktree_path: worktree_path} = task, :branch), do: diff(worktree_path, ["diff", branch_base(task)])

  defp diff(worktree_path, args) do
    case Tools.run("git", args, cd: worktree_path, stderr_to_stdout: true) do
      {output, 0} -> output
      _unreadable -> ""
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
      header <> "Binary files /dev/null and b/#{path} differ\n"
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
