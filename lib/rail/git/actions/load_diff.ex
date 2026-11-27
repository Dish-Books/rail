defmodule Rail.Git.Actions.LoadDiff do
  @moduledoc """
  Everything a diff pane needs to draw a task's worktree, in one call.

  Three views, because the questions are different. `:branch` is everything the
  branch did against the base it forked from, committed or not, which is what
  review means. `:uncommitted` is only what has not been committed yet, which is
  what "what has the engineer changed since I last looked" means. `{:commit, sha}`
  is one commit against its first parent, so a merge shows what main brought in.
  The working tree is the checkout's as last synced into the task's repository,
  `refs/rail/wip`, untracked files and all.

  The files come back already parsed into rows, already highlighted and already
  marked with whether this reader has read them, because there is nothing a
  caller would do with the halves separately. A file whose digest has not moved
  since `previous_files` keeps the rows it was highlighted into there.
  """

  import Rail.Git.Utils.DiffSides
  import Rail.Git.Utils.FileLines
  import Rail.Git.Utils.HighlightLines
  import Rail.Git.Utils.ParseDiff
  import Rail.Git.Utils.WorkTree

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Scope
  alias Rail.Tools

  @sha ~r/\A[0-9a-f]{7,40}\z/

  @doc """
  Loads `task`'s diff under `filter` for `scope`.

  Returns `{:ok, files}`, or `{:error, :no_worktree}` once the worktree has been
  cleaned up, since the change only ever existed on disk.
  """
  def load_diff(%Scope{} = scope, %Task{} = task, filter \\ :branch, previous_files \\ []) do
    case work_tree(task) do
      %{repo: repo} = work_tree -> {:ok, load(scope, task, repo, diff_sides(task, work_tree, filter), previous_files)}
      nil -> {:error, :no_worktree}
    end
  end

  defp load(scope, task, repo, sides, previous_files) do
    viewed = Git.list_viewed_files(scope, task, :diff)
    drawn = Map.new(previous_files, &{{&1.path, &1.digest}, &1.rows})
    parsed = repo |> raw_diff(sides) |> parse_diff()

    highlighted =
      parsed
      |> Enum.reject(&Map.has_key?(drawn, {&1.path, &1.digest}))
      |> Elixir.Task.async_stream(&highlight(&1, repo, sides),
        ordered: true,
        max_concurrency: System.schedulers_online(),
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, file} -> file end)

    {files, []} = Enum.map_reduce(parsed, highlighted, &draw(&1, &2, drawn))

    Enum.map(files, &Map.put(&1, :viewed?, Map.get(viewed, &1.path) == &1.digest))
  end

  # Kept rows are put back here rather than in the tasks, so they stay the terms
  # the caller already holds instead of copies made on the way out and back.
  defp draw(file, highlighted, drawn) do
    case Map.fetch(drawn, {file.path, file.digest}) do
      {:ok, rows} -> {%{file | rows: rows}, highlighted}
      :error -> {hd(highlighted), tl(highlighted)}
    end
  end

  # A line's color depends on where it sits in its file, so each side is highlighted
  # whole: the old one as it was at the diff's base, and only when a deleted row needs it.
  defp highlight(%{rows: rows, path: path} = file, repo, {base, revision}) do
    old =
      if Enum.any?(rows, &(&1[:line_kind] == :deleted)),
        do: colors(rows, :deleted, :old_line, path, fn -> file_lines(repo, file.old_path, base) end),
        else: %{}

    new = colors(rows, :added, :new_line, path, fn -> file_lines(repo, path, revision) end)

    %{file | rows: Enum.map(rows, &stamp(&1, old, new))}
  end

  # A side whose file has moved on since the diff, or is not text, is highlighted
  # from the lines the diff shows instead, which colors all but multi-line constructs.
  defp colors(rows, changed, number, path, read) do
    case Enum.filter(rows, &side?(&1, changed)) do
      [] ->
        %{}

      side ->
        numbers = Enum.map(side, &Map.fetch!(&1, number))
        lines = read.()

        if whole?(lines, side, numbers) do
          html = lines |> highlight_lines(path) |> List.to_tuple()
          Map.new(numbers, &{&1, elem(html, &1 - 1)})
        else
          numbers |> Enum.zip(side |> Enum.map(& &1.text) |> highlight_lines(path)) |> Map.new()
        end
    end
  end

  defp side?(%{kind: :line, line_kind: line_kind}, changed), do: line_kind in [:context, changed]
  defp side?(_row, _changed), do: false

  defp whole?(nil, _side, _numbers), do: false

  defp whole?(lines, side, numbers) do
    file = List.to_tuple(lines)

    Enum.all?(lines, &String.valid?/1) and
      side
      |> Enum.zip(numbers)
      |> Enum.all?(fn {row, n} -> n in 1..tuple_size(file)//1 and elem(file, n - 1) == row.text end)
  end

  defp stamp(%{kind: :line, line_kind: :deleted, old_line: line} = row, old, _new), do: Map.put(row, :html, old[line])
  defp stamp(%{kind: :line, new_line: line} = row, _old, new), do: Map.put(row, :html, new[line])
  defp stamp(row, _old, _new), do: row

  # The sha comes from a page, so only a commit name, never an option, reaches git.
  defp raw_diff(repo, {base, revision}) do
    if revision =~ @sha do
      case Tools.run("git", ["diff", base, revision], cd: repo, stderr_to_stdout: true) do
        {output, 0} -> output
        _unreadable -> ""
      end
    else
      ""
    end
  end
end
