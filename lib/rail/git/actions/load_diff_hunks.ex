defmodule Rail.Git.Actions.LoadDiffHunks do
  @moduledoc """
  The lines each of a finding's places names, as the branch reads them.

  A finding points at ranges, and what a reader wants beside each is those lines with a little either
  side, changed or not. Lines the branch changed come from its diff, read once for every range; lines
  it did not are read from the worktree, so a range never shows some other change in their place.
  """

  import Rail.Git.Utils.FileLines
  import Rail.Git.Utils.HighlightLines

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Scope

  # Enough either side to see what the lines sit in, and short enough that eight places stay readable.
  @context 3
  @hunk_header ~r/^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/

  @doc """
  Returns one excerpt or nil for each `{path, line, end_line}` in `ranges`, in order.

  An excerpt is `%{path:, display_path:, additions:, deletions:, rows:, changed?:, in_diff?:, missing:,
  hidden_lines:, other_changes:}`: one unbroken run of rows with no hunk header, each row in the range
  carrying `named?: true`. A range with no `line` takes its file's first change. A range in a file of the
  diff with no lines on the branch has no rows and says why in `missing`: `:deleted`, `:unreadable` or
  `{:past_end, lines}`. Nil means there is nothing to show.
  """
  def load_diff_hunks(%Scope{} = scope, %Task{} = task, ranges) when is_list(ranges) do
    case Git.load_diff(scope, task, :branch) do
      {:ok, files} ->
        {excerpts, _read} = Enum.map_reduce(ranges, %{}, &excerpt(&1, files, task.worktree_path, &2))
        excerpts

      {:error, :no_worktree} ->
        Enum.map(ranges, fn _range -> nil end)
    end
  end

  # Each file is read and highlighted at most once, however many ranges name it.
  defp excerpt({path, line, end_line}, files, worktree_path, read) when is_binary(path) do
    file = find_file(files, path)

    cond do
      file != nil and not is_integer(line) -> {first_change(file), read}
      file != nil and file.binary? -> {binary(file, true), read}
      not is_integer(line) -> {nil, read}
      true -> lines(file, path, line, end_line, worktree_path, read)
    end
  end

  # A finding names the path it read, which may be the repository-relative one or a suffix of it,
  # so the longest match wins rather than the first.
  defp find_file(files, path) do
    trimmed = String.trim_leading(path, "./")

    files
    |> Enum.filter(&(&1.path == trimmed or String.ends_with?(&1.path, "/" <> trimmed)))
    |> Enum.max_by(&String.length(&1.path), fn -> nil end)
  end

  defp first_change(%{binary?: true} = file), do: binary(file, true)

  defp first_change(file) do
    case hunks(file.rows) do
      [] ->
        nil

      [first | rest] ->
        Map.merge(stat(file, true), %{
          rows: first.rows,
          changed?: true,
          hidden_lines: 0,
          other_changes: length(rest)
        })
    end
  end

  defp binary(file, in_diff?),
    do:
      Map.merge(stat(file, in_diff?), %{rows: [%{kind: :binary}], changed?: in_diff?, hidden_lines: 0, other_changes: 0})

  defp stat(file, in_diff?) do
    %{
      path: file.path,
      display_path: file.display_path,
      additions: file.additions,
      deletions: file.deletions,
      in_diff?: in_diff?,
      missing: nil
    }
  end

  # No rows from elsewhere in the file stand in for lines the branch does not have.
  defp missing(file, why),
    do: Map.merge(stat(file, true), %{rows: [], changed?: false, hidden_lines: 0, other_changes: 0, missing: why})

  defp lines(file, path, line, end_line, worktree_path, read) do
    path = if file, do: file.path, else: String.trim_leading(path, "./")
    {source, read} = source(read, worktree_path, path)
    last = if is_integer(end_line) and end_line > line, do: end_line, else: line

    case {file, source} do
      {nil, nil} ->
        {nil, read}

      # A deleted file's rows are numbered as main read them, which a range named in an earlier round need not be.
      {%{status: :deleted}, nil} ->
        {missing(file, :deleted), read}

      {file, nil} ->
        {missing(file, :unreadable), read}

      {file, :binary} ->
        {binary(file || %{path: path, display_path: path, additions: 0, deletions: 0}, file != nil), read}

      _readable ->
        window(file, path, source, line, last, read)
    end
  end

  defp source(read, worktree_path, path) do
    case Map.fetch(read, path) do
      {:ok, source} ->
        {source, read}

      :error ->
        source = read_source(worktree_path, path)
        {source, Map.put(read, path, source)}
    end
  end

  # A file that is not text is named rather than drawn, as the diff names one.
  defp read_source(worktree_path, path) do
    case file_lines(worktree_path, path) do
      lines when is_list(lines) ->
        cond do
          Enum.any?(lines, &String.contains?(&1, <<0>>)) -> :binary
          Enum.all?(lines, &String.valid?/1) -> %{path: path, lines: List.to_tuple(lines), html: :unread}
          true -> %{path: path, lines: lines |> Enum.map(&String.replace_invalid/1) |> List.to_tuple(), html: nil}
        end

      nil ->
        nil
    end
  end

  defp window(file, path, source, line, last, read) do
    count = tuple_size(source.lines)
    {by_new, deleted_at, hunks} = if file, do: index(file.rows), else: {%{}, %{}, []}
    from = max(line - @context, 1)
    to = last + @context
    {source, read} = highlighted(source, Enum.any?(from..min(to, count)//1, &(not Map.has_key?(by_new, &1))), read)

    rows =
      Enum.flat_map(from..to//1, fn n ->
        deleted = if n > from or n == 1, do: Map.get(deleted_at, n, []), else: []
        kept = Map.get(by_new, n) || unchanged(source, n, count, by_new)
        # What was deleted just before the range is what it replaced, which the range does not name.
        Enum.map(deleted, &name(&1, n > line and n <= last)) ++ if(kept, do: [name(kept, n in line..last)], else: [])
      end)

    # What was deleted after the file's last line follows it.
    rows = if to == count, do: rows ++ Map.get(deleted_at, count + 1, []), else: rows

    cond do
      Enum.any?(rows, &(&1[:named?] == true)) -> {summarize(file, path, rows, hunks), read}
      file -> {missing(file, {:past_end, count}), read}
      true -> {nil, read}
    end
  end

  # Highlighted whole, so a line inside a heredoc reads as the file does, and only once a range needs it.
  defp highlighted(%{html: :unread} = source, true, read) do
    source = %{source | html: source.lines |> Tuple.to_list() |> highlight_lines(source.path) |> List.to_tuple()}
    {source, Map.put(read, source.path, source)}
  end

  defp highlighted(source, _needed, read), do: {source, read}

  defp unchanged(_source, n, count, _by_new) when n > count, do: nil

  defp unchanged(source, n, _count, by_new) do
    %{
      kind: :line,
      line_kind: :context,
      old_line: old_line(by_new, n),
      new_line: n,
      text: elem(source.lines, n - 1),
      html: if(is_tuple(source.html), do: elem(source.html, n - 1))
    }
  end

  # An unchanged line sits as far from its old number as the nearest unchanged row of the diff above it.
  defp old_line(by_new, n) do
    by_new
    |> Enum.filter(fn {new, row} -> new < n and row.line_kind == :context end)
    |> Enum.max_by(fn {new, _row} -> new end, fn -> nil end)
    |> case do
      {new, row} -> row.old_line + n - new
      nil -> n
    end
  end

  defp name(row, true), do: Map.put(row, :named?, true)
  defp name(row, false), do: row

  defp summarize(nil, path, rows, _hunks) do
    Map.merge(stat(%{path: path, display_path: path, additions: 0, deletions: 0}, false), %{
      rows: rows,
      changed?: false,
      hidden_lines: 0,
      other_changes: 0
    })
  end

  defp summarize(file, _path, rows, hunks) do
    shown = for %{index: index} <- rows, into: MapSet.new(), do: index
    changed? = Enum.any?(rows, &(&1[:named?] == true and &1[:line_kind] in [:added, :deleted]))
    {touched, others} = Enum.split_with(hunks, fn hunk -> Enum.any?(hunk.changed, &MapSet.member?(shown, &1)) end)

    Map.merge(stat(file, true), %{
      rows: rows,
      changed?: changed?,
      hidden_lines:
        if(changed?, do: touched |> Enum.flat_map(& &1.changed) |> Enum.count(&(not MapSet.member?(shown, &1))), else: 0),
      other_changes: if(changed?, do: length(others), else: length(hunks))
    })
  end

  # The diff's rows by the new line each stands on, its deleted rows by the new line they sit before,
  # and each hunk's changed rows, by the index the parse gave them.
  defp index(rows) do
    {by_new, deleted_at, _next} =
      Enum.reduce(rows, {%{}, %{}, 1}, fn
        %{kind: :hunk_header, text: text}, {by_new, deleted_at, _next} ->
          {by_new, deleted_at, start(text)}

        %{kind: :line, line_kind: :deleted} = row, {by_new, deleted_at, next} ->
          {by_new, Map.update(deleted_at, next, [row], &[row | &1]), next}

        %{kind: :line, new_line: n} = row, {by_new, deleted_at, _next} ->
          {Map.put(by_new, n, row), deleted_at, n + 1}

        _gap, acc ->
          acc
      end)

    deleted_at = Map.new(deleted_at, fn {n, deleted} -> {n, Enum.reverse(deleted)} end)

    hunks =
      rows
      |> hunks()
      |> Enum.map(fn hunk -> %{changed: for(%{line_kind: kind, index: i} <- hunk.rows, kind != :context, do: i)} end)

    {by_new, deleted_at, hunks}
  end

  # A hunk that only deletes names the line it follows, so what it deletes sits before the next one.
  defp start(text) do
    case Regex.run(@hunk_header, text) do
      [_header, first, "0"] -> String.to_integer(first) + 1
      [_header, first | _count] -> String.to_integer(first)
    end
  end

  # Rows arrive flat: a header, its lines, then the next header, with gaps between that belong to neither.
  defp hunks(rows) do
    rows
    |> Enum.reject(&(&1.kind == :gap))
    |> Enum.chunk_by(&(&1.kind == :hunk_header))
    |> Enum.reject(fn [row | _rest] -> row.kind == :hunk_header end)
    |> Enum.map(&%{rows: &1})
  end
end
