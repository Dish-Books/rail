defmodule Rail.Git.Utils.ParseDiff do
  @moduledoc """
  Turns `git diff` output into the files and rows a diff pane draws.

  Every file comes back as a map carrying a flat `:rows` list, already in the
  order it is read: hunk headers, lines, and a gap standing for the unchanged
  stretch between two hunks. Nothing here is a struct, because nothing outside
  the pane does anything with it but render it.

  The digest covers paths and hunk lines only, leaving out index hashes, mode
  lines and similarity metrics, so a rebase that changed no code leaves a
  reader's viewed marks standing. A block it cannot parse degrades into a
  readable fallback rather than taking the whole diff down.
  """

  @hunk_header_regex ~r/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(?: ?(.*))?$/
  @binary_files_regex ~r/^Binary files ("?a\/.*?"?) and ("?b\/.*?"?) differ/
  @binary_file_regex ~r/^Binary file ("?.*?"?) differs/
  @git_diff_quoted_regex ~r/^"a\/(.*?)"\s+"b\/(.*?)"$/

  @doc """
  Parses a raw git diff into a list of file maps.
  """
  def parse_diff(nil), do: []

  def parse_diff(raw_diff) when is_binary(raw_diff) do
    if String.trim(raw_diff) == "" do
      []
    else
      raw_diff
      |> split_diff_blocks()
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.map(&parse_or_fallback_block/1)
    end
  end

  defp parse_or_fallback_block(block) do
    parse_block(block)
    # coveralls-ignore-start (defensive degradation fallback for unexpected parser crashes)
  rescue
    _error ->
      digest =
        :sha256
        |> :crypto.hash(block)
        |> Base.encode16(case: :lower)

      file(%{status: :modified, digest: digest, path: "", display_path: "", rows: []})

      # coveralls-ignore-stop
  end

  defp split_diff_blocks(raw_diff) do
    lines = split_lines(raw_diff)

    {blocks, current_block} =
      Enum.reduce(lines, {[], []}, fn line, {blocks_acc, current_acc} ->
        if String.starts_with?(line, "diff --git ") and current_acc != [] do
          block_str = current_acc |> Enum.reverse() |> Enum.join("\n") |> Kernel.<>("\n")
          {[block_str | blocks_acc], [line]}
        else
          {blocks_acc, [line | current_acc]}
        end
      end)

    last_block = current_block |> Enum.reverse() |> Enum.join("\n") |> Kernel.<>("\n")
    Enum.reverse([last_block | blocks])
  end

  defp parse_block(block) do
    lines = split_lines(block)
    digest = compute_block_digest(lines, block)
    header_info = scan_headers(lines)

    old_path = header_info.old_path
    new_path = header_info.new_path
    is_binary = header_info.is_binary
    hunk_start_index = header_info.hunk_start_index

    {old_path, new_path} =
      if is_nil(old_path) and is_nil(new_path) and lines != [] do
        fallback_paths(hd(lines), old_path, new_path)
      else
        {old_path, new_path}
      end

    status = infer_status(header_info.status, old_path, new_path)

    {hunks, additions, deletions} =
      if not is_binary and hunk_start_index != -1 do
        hunk_lines = Enum.drop(lines, hunk_start_index)
        parsed_hunks = parse_hunks(hunk_lines)
        {adds, dels} = count_changes(parsed_hunks)
        {parsed_hunks, adds, dels}
      else
        {[], 0, 0}
      end

    path = new_path || old_path || ""
    renamed? = is_binary(old_path) and is_binary(new_path) and old_path != new_path

    file(%{
      path: path,
      display_path: if(renamed?, do: "#{old_path} \u2192 #{new_path}", else: path),
      status: status,
      digest: digest,
      binary?: is_binary,
      additions: additions,
      deletions: deletions,
      rows: rows(path, hunks, is_binary)
    })
  end

  # Every file reads the same way whether it parsed or not, so the caller never
  # has to ask which it was.
  defp file(attrs) do
    Map.merge(
      %{path: "", display_path: "", status: :modified, digest: nil, binary?: false, additions: 0, deletions: 0, rows: []},
      attrs
    )
  end

  # The rows, in the order they are drawn. A gap carries what it would take to
  # fill it in; whether it has been is the reader's business, not the diff's.
  defp rows(_path, _hunks, true), do: [%{kind: :binary}]

  defp rows(path, hunks, _text) do
    {rows, _index} =
      hunks
      |> Enum.with_index()
      |> Enum.reduce({[], 0}, fn {hunk, position}, {acc, index} ->
        gap = if position > 0, do: gap_row(path, Enum.at(hunks, position - 1), hunk, position - 1), else: []
        header = %{kind: :hunk_header, text: hunk.header}

        {lines, next_index} =
          Enum.map_reduce(hunk.lines, index, fn line, i ->
            {Map.merge(line, %{kind: :line, index: i}), i + 1}
          end)

        {acc ++ gap ++ [header] ++ lines, next_index}
      end)

    rows
  end

  defp gap_row(path, previous, hunk, gap_index) do
    start_line = previous.new_start + previous.new_count
    end_line = hunk.new_start - 1

    if end_line >= start_line do
      [
        %{
          kind: :gap,
          key: "#{path}:#{gap_index}",
          path: path,
          gap_index: gap_index,
          start_line: start_line,
          end_line: end_line,
          old_start_line: previous.old_start + previous.old_count,
          count: end_line - start_line + 1
        }
      ]
    else
      []
    end
  end

  defp count_changes(hunks) do
    Enum.reduce(hunks, {0, 0}, &count_hunk_changes/2)
  end

  defp count_hunk_changes(hunk, acc) do
    Enum.reduce(hunk.lines, acc, &count_line_change/2)
  end

  defp count_line_change(%{line_kind: :added}, {adds, dels}), do: {adds + 1, dels}
  defp count_line_change(%{line_kind: :deleted}, {adds, dels}), do: {adds, dels + 1}
  defp count_line_change(%{line_kind: :context}, acc), do: acc

  defp compute_block_digest(lines, block) do
    {hash_lines, _in_hunks} =
      Enum.reduce(lines, {[], false}, fn line, {acc, in_hunks} ->
        cond do
          String.starts_with?(line, "--- ") or
            String.starts_with?(line, "+++ ") or
            String.starts_with?(line, "rename from ") or
            String.starts_with?(line, "rename to ") or
            String.starts_with?(line, "Binary files ") or
            String.starts_with?(line, "Binary file ") or
              String.starts_with?(line, "GIT binary patch") ->
            {[line | acc], in_hunks}

          String.starts_with?(line, "@@ ") ->
            {[line | acc], true}

          in_hunks ->
            {[line | acc], true}

          true ->
            {acc, in_hunks}
        end
      end)

    digest_content =
      if hash_lines == [] do
        block
      else
        hash_lines |> Enum.reverse() |> Enum.join("\n") |> Kernel.<>("\n")
      end

    :sha256
    |> :crypto.hash(digest_content)
    |> Base.encode16(case: :lower)
  end

  defp scan_headers(lines) do
    initial = %{
      old_path: nil,
      new_path: nil,
      status: nil,
      is_binary: false,
      hunk_start_index: -1
    }

    Enum.reduce_while(Enum.with_index(lines), initial, &process_header_line/2)
  end

  defp process_header_line({line, i}, acc) do
    cond do
      String.starts_with?(line, "@@ ") ->
        {:halt, %{acc | hunk_start_index: i}}

      String.starts_with?(line, "--- ") ->
        {:cont, %{acc | old_path: clean_path(String.slice(line, 4..-1//1), "a/")}}

      String.starts_with?(line, "+++ ") ->
        {:cont, %{acc | new_path: clean_path(String.slice(line, 4..-1//1), "b/")}}

      String.starts_with?(line, "rename from ") ->
        path = unquote_path(String.trim(String.slice(line, 12..-1//1)))
        {:cont, %{acc | old_path: path, status: :renamed}}

      String.starts_with?(line, "rename to ") ->
        path = unquote_path(String.trim(String.slice(line, 10..-1//1)))
        {:cont, %{acc | new_path: path, status: :renamed}}

      String.starts_with?(line, "new file mode ") or
          String.starts_with?(line, "new file (untracked)") ->
        {:cont, %{acc | status: :added}}

      String.starts_with?(line, "deleted file mode ") ->
        {:cont, %{acc | status: :deleted}}

      String.starts_with?(line, "similarity index ") ->
        {:cont, %{acc | status: :renamed}}

      binary_header_line?(line) ->
        {:cont, parse_binary_line(line, acc)}

      true ->
        {:cont, acc}
    end
  end

  defp binary_header_line?(line) do
    String.starts_with?(line, "Binary files ") or
      String.starts_with?(line, "Binary file ") or
      String.starts_with?(line, "GIT binary patch")
  end

  defp parse_binary_line(line, acc) do
    acc = %{acc | is_binary: true}

    cond do
      String.starts_with?(line, "Binary files ") ->
        parse_binary_files_paths(line, acc)

      String.starts_with?(line, "Binary file ") ->
        parse_single_binary_path(line, acc)

      true ->
        acc
    end
  end

  defp parse_binary_files_paths(line, acc) do
    case Regex.run(@binary_files_regex, line) do
      [_all, p1, p2] ->
        %{
          acc
          | old_path: acc.old_path || clean_path(p1, "a/"),
            new_path: acc.new_path || clean_path(p2, "b/")
        }

      _other ->
        acc
    end
  end

  defp parse_single_binary_path(line, acc) do
    case Regex.run(@binary_file_regex, line) do
      [_all, p] ->
        unquoted = unquote_path(String.trim(p))
        %{acc | old_path: acc.old_path || unquoted, new_path: acc.new_path || unquoted}

      _other ->
        acc
    end
  end

  defp fallback_paths(first_line, old_path, new_path) do
    if String.starts_with?(first_line, "diff --git ") do
      remainder = String.trim(String.slice(first_line, 11..-1//1))

      case parse_diff_git_line(remainder) do
        {p1, p2} -> {old_path || p1, new_path || p2}
        nil -> {old_path, new_path}
      end
    else
      {old_path, new_path}
    end
  end

  defp parse_diff_git_line(remainder) do
    if String.starts_with?(remainder, "\"") do
      case Regex.run(@git_diff_quoted_regex, remainder) do
        [_all, g1, g2] -> {unescape(g1), unescape(g2)}
        _other -> nil
      end
    else
      parts = String.split(remainder, " ")

      if length(parts) == 2 do
        [p1, p2] = parts

        clean_p1 =
          if String.starts_with?(p1, "a/"), do: String.slice(p1, 2..-1//1), else: p1

        clean_p2 =
          if String.starts_with?(p2, "b/"), do: String.slice(p2, 2..-1//1), else: p2

        {clean_p1, clean_p2}
      end
    end
  end

  defp infer_status(nil, old_path, new_path) do
    cond do
      is_nil(old_path) and is_binary(new_path) -> :added
      is_nil(new_path) and is_binary(old_path) -> :deleted
      is_binary(old_path) and is_binary(new_path) and old_path != new_path -> :renamed
      true -> :modified
    end
  end

  defp infer_status(status, _old_path, _new_path), do: status

  defp parse_hunks(lines) do
    {hunk_groups, current_group} =
      Enum.reduce(lines, {[], []}, fn line, {groups_acc, current_acc} ->
        if String.starts_with?(line, "@@ ") and current_acc != [] do
          {[Enum.reverse(current_acc) | groups_acc], [line]}
        else
          {groups_acc, [line | current_acc]}
        end
      end)

    last_group = Enum.reverse(current_group)
    all_groups = Enum.reverse([last_group | hunk_groups])

    all_groups
    |> Enum.map(&parse_single_hunk/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_single_hunk([header_line | body_lines]) do
    case Regex.run(@hunk_header_regex, header_line) do
      [_match, old_start_str, old_count_str, new_start_str, new_count_str, _heading] ->
        old_start = String.to_integer(old_start_str)
        old_count = if old_count_str == "", do: 1, else: String.to_integer(old_count_str)
        new_start = String.to_integer(new_start_str)
        new_count = if new_count_str == "", do: 1, else: String.to_integer(new_count_str)

        diff_lines = parse_hunk_lines(body_lines, old_start, new_start)

        %{
          header: header_line,
          old_start: old_start,
          old_count: old_count,
          new_start: new_start,
          new_count: new_count,
          lines: diff_lines
        }

      _other ->
        nil
    end
  end

  defp parse_hunk_lines(body_lines, old_start, new_start) do
    {diff_lines, _final_old, _final_new} =
      Enum.reduce(body_lines, {[], old_start, new_start}, fn line, {acc, cur_old, cur_new} ->
        cond do
          String.starts_with?(line, "+") ->
            diff_line = %{
              line_kind: :added,
              old_line: nil,
              new_line: cur_new,
              text: String.slice(line, 1..-1//1)
            }

            {[diff_line | acc], cur_old, cur_new + 1}

          String.starts_with?(line, "-") ->
            diff_line = %{
              line_kind: :deleted,
              old_line: cur_old,
              new_line: nil,
              text: String.slice(line, 1..-1//1)
            }

            {[diff_line | acc], cur_old + 1, cur_new}

          String.starts_with?(line, " ") ->
            diff_line = %{
              line_kind: :context,
              old_line: cur_old,
              new_line: cur_new,
              text: String.slice(line, 1..-1//1)
            }

            {[diff_line | acc], cur_old + 1, cur_new + 1}

          line == "" ->
            diff_line = %{
              line_kind: :context,
              old_line: cur_old,
              new_line: cur_new,
              text: ""
            }

            {[diff_line | acc], cur_old + 1, cur_new + 1}

          String.starts_with?(line, "\\") ->
            {acc, cur_old, cur_new}

          true ->
            diff_line = %{
              line_kind: :context,
              old_line: cur_old,
              new_line: cur_new,
              text: line
            }

            {[diff_line | acc], cur_old + 1, cur_new + 1}
        end
      end)

    Enum.reverse(diff_lines)
  end

  defp clean_path(raw, prefix) do
    unquoted = unquote_path(String.trim(raw))

    cond do
      unquoted == "/dev/null" -> nil
      String.starts_with?(unquoted, prefix) -> String.slice(unquoted, String.length(prefix)..-1//1)
      true -> unquoted
    end
  end

  defp unquote_path(path) do
    p = String.trim(path)

    if String.length(p) >= 2 and String.starts_with?(p, "\"") and String.ends_with?(p, "\"") do
      p |> String.slice(1..-2//1) |> unescape()
    else
      p
    end
  end

  defp unescape(path) do
    path |> String.replace("\\\"", "\"") |> String.replace("\\\\", "\\")
  end

  # Trimmed with a regex rather than by slicing: CRLF is a single grapheme, so
  # slicing a fixed number of positions off the end eats the character before it.
  defp split_lines(text) do
    text
    |> String.replace(~r/\r?\n\z/, "")
    |> String.split(~r/\r?\n/)
  end
end
