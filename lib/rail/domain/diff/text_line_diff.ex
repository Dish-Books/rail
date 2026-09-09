defmodule Rail.Domain.Diff.TextLineDiff do
  @moduledoc """
  Computes a line-by-line unified diff between two text strings using LCS.

  Used when comparing text blobs directly in memory (e.g. proposed role instructions)
  without git blobs. Follows spec 02 §24 exact tie-breaking: additions are preferred
  over deletions on a tie (`dp[i][j-1] >= dp[i-1][j]`).
  """

  alias Rail.Domain.Diff.DiffHunk
  alias Rail.Domain.Diff.DiffLine
  alias Rail.Domain.Diff.FileDiff

  @context_size 3

  @doc """
  Computes unified line diff between `before` and `after` strings for the given `path`.
  """
  def diff(before, after_text, path) when is_binary(before) and is_binary(after_text) and is_binary(path) do
    digest =
      :sha256
      |> :crypto.hash(after_text)
      |> Base.encode16(case: :lower)

    norm_before = String.trim_trailing(before)
    norm_after = String.trim_trailing(after_text)

    if norm_before == norm_after do
      FileDiff.new(%{
        old_path: path,
        new_path: path,
        status: :unchanged,
        digest: digest,
        hunks: [],
        additions: 0,
        deletions: 0
      })
    else
      old_lines = split_lines(before)
      new_lines = split_lines(after_text)

      edits = compute_edits(old_lines, new_lines)
      hunks = build_hunks(edits)

      status =
        cond do
          before == "" -> :added
          after_text == "" -> :deleted
          true -> :modified
        end

      {additions, deletions} = count_changes(hunks)

      FileDiff.new(%{
        old_path: path,
        new_path: path,
        status: status,
        digest: digest,
        hunks: hunks,
        additions: additions,
        deletions: deletions
      })
    end
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

  defp split_lines(""), do: []

  defp split_lines(text) do
    normalized =
      cond do
        String.ends_with?(text, "\r\n") -> String.slice(text, 0..-3//1)
        String.ends_with?(text, "\n") -> String.slice(text, 0..-2//1)
        true -> text
      end

    String.split(normalized, ~r/\r?\n/)
  end

  defp compute_edits(old_lines, new_lines) do
    m = length(old_lines)
    n = length(new_lines)

    old_tuple = List.to_tuple(old_lines)
    new_tuple = List.to_tuple(new_lines)

    n_cols = n + 1
    size = (m + 1) * n_cols
    dp = :atomics.new(size, signed: true)

    fill_dp_table(dp, old_tuple, new_tuple, m, n, n_cols)

    # Backtrack from (m, n)
    backtrack(dp, old_tuple, new_tuple, m, n, n_cols, [])
  end

  defp fill_dp_table(_dp, _old_tuple, _new_tuple, 0, _n, _n_cols), do: :ok
  defp fill_dp_table(_dp, _old_tuple, _new_tuple, _m, 0, _n_cols), do: :ok

  defp fill_dp_table(dp, old_tuple, new_tuple, m, n, n_cols) do
    for i <- 1..m, j <- 1..n do
      old_val = elem(old_tuple, i - 1)
      new_val = elem(new_tuple, j - 1)
      idx_ij = i * n_cols + j + 1
      compute_and_store_dp(dp, old_val, new_val, i, j, n_cols, idx_ij)
    end

    :ok
  end

  defp compute_and_store_dp(dp, val, val, i, j, n_cols, idx_ij) do
    idx_prev = (i - 1) * n_cols + (j - 1) + 1
    :atomics.put(dp, idx_ij, :atomics.get(dp, idx_prev) + 1)
  end

  defp compute_and_store_dp(dp, _old_val, _new_val, i, j, n_cols, idx_ij) do
    up = :atomics.get(dp, (i - 1) * n_cols + j + 1)
    left = :atomics.get(dp, i * n_cols + (j - 1) + 1)
    val = if up >= left, do: up, else: left
    :atomics.put(dp, idx_ij, val)
  end

  defp backtrack(_dp, _old_tuple, _new_tuple, 0, 0, _n_cols, acc) do
    acc
  end

  defp backtrack(dp, old_tuple, new_tuple, i, j, n_cols, acc) do
    cond do
      i > 0 and j > 0 and elem(old_tuple, i - 1) == elem(new_tuple, j - 1) ->
        edit = %{
          kind: :context,
          old_line_number: i,
          new_line_number: j,
          text: elem(old_tuple, i - 1)
        }

        backtrack(dp, old_tuple, new_tuple, i - 1, j - 1, n_cols, [edit | acc])

      j > 0 and (i == 0 or dp_val(dp, i, j - 1, n_cols) >= dp_val(dp, i - 1, j, n_cols)) ->
        edit = %{
          kind: :added,
          old_line_number: nil,
          new_line_number: j,
          text: elem(new_tuple, j - 1)
        }

        backtrack(dp, old_tuple, new_tuple, i, j - 1, n_cols, [edit | acc])

      i > 0 ->
        edit = %{
          kind: :deleted,
          old_line_number: i,
          new_line_number: nil,
          text: elem(old_tuple, i - 1)
        }

        backtrack(dp, old_tuple, new_tuple, i - 1, j, n_cols, [edit | acc])
    end
  end

  defp dp_val(dp, i, j, n_cols) do
    :atomics.get(dp, i * n_cols + j + 1)
  end

  defp build_hunks(edits) do
    change_indices = find_change_indices(edits)

    if change_indices == [] do
      []
    else
      total_len = length(edits)
      ranges = compute_hunk_ranges(change_indices, total_len)
      edits_tuple = List.to_tuple(edits)

      Enum.map(ranges, fn range ->
        build_hunk(range, edits_tuple, total_len)
      end)
    end
  end

  defp find_change_indices(edits) do
    edits
    |> Enum.with_index()
    |> Enum.filter(fn {edit, _idx} -> edit.kind != :context end)
    |> Enum.map(fn {_edit, idx} -> idx end)
  end

  defp compute_hunk_ranges([first | rest], total_len) do
    current_start = max(0, first - @context_size)
    current_end = min(total_len - 1, first + @context_size)

    {ranges, last_start, last_end} =
      Enum.reduce(rest, {[], current_start, current_end}, fn idx, {acc, c_start, c_end} ->
        r_start = max(0, idx - @context_size)
        r_end = min(total_len - 1, idx + @context_size)

        if r_start <= c_end + 1 do
          {acc, c_start, max(c_end, r_end)}
        else
          {[{c_start, c_end} | acc], r_start, r_end}
        end
      end)

    Enum.reverse([{last_start, last_end} | ranges])
  end

  defp build_hunk({r_start, r_end}, edits_tuple, total_len) do
    hunk_edits = for idx <- r_start..r_end, do: elem(edits_tuple, idx)

    {hunk_lines, first_old, first_new, old_count, new_count} =
      Enum.reduce(hunk_edits, {[], nil, nil, 0, 0}, &process_hunk_edit/2)

    old_start = first_old || find_old_line_at(edits_tuple, total_len, r_start)
    new_start = first_new || find_new_line_at(edits_tuple, total_len, r_start)
    header = format_hunk_header(old_start, old_count, new_start, new_count)

    %DiffHunk{
      header: header,
      old_start: old_start,
      old_count: old_count,
      new_start: new_start,
      new_count: new_count,
      lines: Enum.reverse(hunk_lines)
    }
  end

  defp format_hunk_header(old_start, old_count, new_start, new_count) do
    old_cnt_str = if old_count == 1, do: "", else: ",#{old_count}"
    new_cnt_str = if new_count == 1, do: "", else: ",#{new_count}"
    "@@ -#{old_start}#{old_cnt_str} +#{new_start}#{new_cnt_str} @@"
  end

  defp process_hunk_edit(%{kind: :context} = edit, {acc_lines, f_old, f_new, o_cnt, n_cnt}) do
    line = %DiffLine{
      kind: :context,
      old_line_number: edit.old_line_number,
      new_line_number: edit.new_line_number,
      text: edit.text
    }

    {[line | acc_lines], f_old || edit.old_line_number, f_new || edit.new_line_number, o_cnt + 1, n_cnt + 1}
  end

  defp process_hunk_edit(%{kind: :deleted} = edit, {acc_lines, f_old, f_new, o_cnt, n_cnt}) do
    line = %DiffLine{
      kind: :deleted,
      old_line_number: edit.old_line_number,
      new_line_number: nil,
      text: edit.text
    }

    {[line | acc_lines], f_old || edit.old_line_number, f_new, o_cnt + 1, n_cnt}
  end

  defp process_hunk_edit(%{kind: :added} = edit, {acc_lines, f_old, f_new, o_cnt, n_cnt}) do
    line = %DiffLine{
      kind: :added,
      old_line_number: nil,
      new_line_number: edit.new_line_number,
      text: edit.text
    }

    {[line | acc_lines], f_old, f_new || edit.new_line_number, o_cnt, n_cnt + 1}
  end

  defp find_old_line_at(edits_tuple, total_len, index) do
    Enum.find_value(index..(total_len - 1), fn i ->
      elem(edits_tuple, i).old_line_number
    end) || 1
  end

  defp find_new_line_at(edits_tuple, total_len, index) do
    Enum.find_value(index..(total_len - 1), fn i ->
      elem(edits_tuple, i).new_line_number
    end) || 1
  end
end
