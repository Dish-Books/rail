defmodule Rail.Domain.Diff.UnifiedDiffParser do
  @moduledoc """
  Pure-Elixir parser for unified git diff strings.

  Converts raw `git diff` output into a list of `FileDiff` structs.
  Never throws on unexpected or malformed diff headers; degrades gracefully
  into a readable fallback `FileDiff`.

  Computes a rebase-stable SHA256 digest over paths and hunk lines only,
  omitting index hashes, mode lines, and similarity metrics so that rebasing
  without code changes preserves viewed marks.
  """

  alias Rail.Domain.Diff.DiffHunk
  alias Rail.Domain.Diff.DiffLine
  alias Rail.Domain.Diff.FileDiff

  @hunk_header_regex ~r/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(?: ?(.*))?$/
  @binary_files_regex ~r/^Binary files ("?a\/.*?"?) and ("?b\/.*?"?) differ/
  @binary_file_regex ~r/^Binary file ("?.*?"?) differs/
  @git_diff_quoted_regex ~r/^"a\/(.*?)"\s+"b\/(.*?)"$/

  @doc """
  Parses a raw git diff string into a list of `FileDiff` structs.
  """
  def parse(nil), do: []

  def parse(raw_diff) when is_binary(raw_diff) do
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

      %FileDiff{
        status: :modified,
        digest: digest,
        raw_block: block,
        display_path: "",
        path: ""
      }

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

    FileDiff.new(%{
      old_path: old_path,
      new_path: new_path,
      status: status,
      is_binary: is_binary,
      hunks: hunks,
      additions: additions,
      deletions: deletions,
      digest: digest,
      raw_block: block
    })
  end

  defp count_changes(hunks) do
    Enum.reduce(hunks, {0, 0}, &count_hunk_changes/2)
  end

  defp count_hunk_changes(hunk, acc) do
    Enum.reduce(hunk.lines, acc, &count_line_change/2)
  end

  defp count_line_change(%{kind: :added}, {adds, dels}), do: {adds + 1, dels}
  defp count_line_change(%{kind: :deleted}, {adds, dels}), do: {adds, dels + 1}
  defp count_line_change(%{kind: :context}, acc), do: acc

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
        [_all, g1, g2] -> {unquote_path(g1), unquote_path(g2)}
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
      [_match, old_start_str, old_count_str, new_start_str, new_count_str, heading_str] ->
        old_start = String.to_integer(old_start_str)
        old_count = if old_count_str == "", do: 1, else: String.to_integer(old_count_str)
        new_start = String.to_integer(new_start_str)
        new_count = if new_count_str == "", do: 1, else: String.to_integer(new_count_str)

        trimmed_heading = String.trim(heading_str)
        heading = if trimmed_heading == "", do: nil, else: trimmed_heading

        diff_lines = parse_hunk_lines(body_lines, old_start, new_start)

        %DiffHunk{
          header: header_line,
          heading: heading,
          section_heading: heading,
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
            diff_line = %DiffLine{
              kind: :added,
              old_line_number: nil,
              new_line_number: cur_new,
              text: String.slice(line, 1..-1//1)
            }

            {[diff_line | acc], cur_old, cur_new + 1}

          String.starts_with?(line, "-") ->
            diff_line = %DiffLine{
              kind: :deleted,
              old_line_number: cur_old,
              new_line_number: nil,
              text: String.slice(line, 1..-1//1)
            }

            {[diff_line | acc], cur_old + 1, cur_new}

          String.starts_with?(line, " ") ->
            diff_line = %DiffLine{
              kind: :context,
              old_line_number: cur_old,
              new_line_number: cur_new,
              text: String.slice(line, 1..-1//1)
            }

            {[diff_line | acc], cur_old + 1, cur_new + 1}

          line == "" ->
            diff_line = %DiffLine{
              kind: :context,
              old_line_number: cur_old,
              new_line_number: cur_new,
              text: ""
            }

            {[diff_line | acc], cur_old + 1, cur_new + 1}

          String.starts_with?(line, "\\") ->
            {acc, cur_old, cur_new}

          true ->
            diff_line = %DiffLine{
              kind: :context,
              old_line_number: cur_old,
              new_line_number: cur_new,
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
      p
      |> String.slice(1..-2//1)
      |> String.replace("\\\"", "\"")
      |> String.replace("\\\\", "\\")
    else
      p
    end
  end

  defp split_lines(text) do
    normalized =
      cond do
        String.ends_with?(text, "\r\n") -> String.slice(text, 0..-3//1)
        String.ends_with?(text, "\n") -> String.slice(text, 0..-2//1)
        true -> text
      end

    String.split(normalized, ~r/\r?\n/)
  end
end
