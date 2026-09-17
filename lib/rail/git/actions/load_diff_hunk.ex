defmodule Rail.Git.Actions.LoadDiffHunk do
  @moduledoc """
  The one hunk of a task's diff that covers a given line of a given file.

  A finding points at a line, and what a reader wants beside it is the change
  that line is part of, not the whole file and not the whole branch. The rest of
  the file's hunks are counted rather than returned, so the pane can offer them
  without paying for them.

  A hunk can itself be long enough to bury the line it was fetched for, so only
  a few lines either side of that one come back, and the line itself is marked
  so the pane can say which of them the finding is about.
  """

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Scope

  # Enough either side to see what the line sits in, without the reader having
  # to hunt for it again.
  @context 6

  @doc """
  Returns the hunk covering `line` of `path` in `task`'s branch diff.

  `%{path:, display_path:, additions:, deletions:, rows:, other_hunks:,
  hidden_lines:}`, or `nil` when the branch does not touch that file at all. The
  row `line` falls on carries `focus?: true`. A `path` with no `line` takes the
  file's first hunk, which is what a finding that names only a file means. A line
  the diff does not cover reads as the first hunk too: the file did change, and
  showing the change is better than showing nothing.
  """
  def load_diff_hunk(%Scope{} = scope, %Task{} = task, path, line \\ nil) when is_binary(path) do
    with {:ok, files} <- Git.load_diff(scope, task, :branch),
         %{} = file <- find_file(files, path) do
      hunks = hunks(file.rows)

      case pick(hunks, line) do
        rows when is_list(rows) ->
          {trimmed, hidden} = trim(rows, line)

          %{
            path: file.path,
            display_path: file.display_path,
            additions: file.additions,
            deletions: file.deletions,
            rows: trimmed,
            other_hunks: max(length(hunks) - 1, 0),
            hidden_lines: hidden
          }

        nil ->
          nil
      end
    else
      _no_such_file -> nil
    end
  end

  # A finding names the path it read, which may be the repository-relative one or
  # a suffix of it, so the longest match wins rather than the first.
  defp find_file(files, path) do
    trimmed = String.trim_leading(path, "./")

    files
    |> Enum.filter(&(&1.path == trimmed or String.ends_with?(&1.path, "/" <> trimmed)))
    |> Enum.max_by(&String.length(&1.path), fn -> nil end)
  end

  # Rows arrive flat: a header, its lines, then the next header. Gaps between
  # hunks belong to neither and are dropped, since one hunk on its own has no gap
  # to expand into.
  defp hunks(rows) do
    rows
    |> Enum.reject(&(&1.kind == :gap))
    |> Enum.chunk_while(
      nil,
      fn
        %{kind: :hunk_header} = row, nil -> {:cont, [row]}
        %{kind: :hunk_header} = row, current -> {:cont, Enum.reverse(current), [row]}
        row, nil -> {:cont, [row]}
        row, current -> {:cont, [row | current]}
      end,
      fn
        nil -> {:cont, []}
        current -> {:cont, Enum.reverse(current), []}
      end
    )
    |> Enum.reject(&(&1 == []))
  end

  defp pick([], _line), do: nil
  defp pick([first | _rest], nil), do: first

  defp pick(hunks, line) do
    Enum.find(hunks, hd(hunks), fn rows -> Enum.any?(rows, &covers?(&1, line)) end)
  end

  defp covers?(%{kind: :line, new_line: new_line}, line), do: new_line == line
  defp covers?(_other_row, _line), do: false

  # The header stays whatever is cut, because it is what says where in the file
  # these lines are.
  defp trim(rows, line) do
    {headers, lines} = Enum.split_with(rows, &(&1.kind == :hunk_header))

    case Enum.find_index(lines, &covers?(&1, line)) do
      focus when is_integer(focus) ->
        first = max(focus - @context, 0)
        kept = lines |> Enum.slice(first, @context * 2 + 1) |> Enum.map(&mark(&1, line))

        {headers ++ kept, length(lines) - length(kept)}

      nil ->
        {rows, 0}
    end
  end

  defp mark(row, line) do
    if covers?(row, line), do: Map.put(row, :focus?, true), else: row
  end
end
