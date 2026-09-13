defmodule Rail.Domain.Diff.FileHeaderRow do
  @moduledoc "Header row for a file in the diff view, showing path and viewed status."
  @enforce_keys [:file, :is_viewed]
  defstruct [:file, :is_viewed, extent: 40.0]

  @type t :: %__MODULE__{
          file: Rail.Domain.Diff.FileDiff.t(),
          is_viewed: boolean(),
          extent: float()
        }
end

defmodule Rail.Domain.Diff.BinaryNoticeRow do
  @moduledoc "Notice that a file is binary and cannot be displayed as text."
  @enforce_keys [:file]
  defstruct [:file, extent: 36.0]

  @type t :: %__MODULE__{
          file: Rail.Domain.Diff.FileDiff.t(),
          extent: float()
        }
end

defmodule Rail.Domain.Diff.HunkHeaderRow do
  @moduledoc "Hunk header row (`@@ -a,b +c,d @@ [section]`)."
  @enforce_keys [:file, :hunk]
  defstruct [:file, :hunk, extent: 28.0]

  @type t :: %__MODULE__{
          file: Rail.Domain.Diff.FileDiff.t(),
          hunk: Rail.Domain.Diff.DiffHunk.t(),
          extent: float()
        }
end

defmodule Rail.Domain.Diff.LineRow do
  @moduledoc "Individual line of diff code (added, deleted, or context)."
  @enforce_keys [:file, :line]
  defstruct [:file, :line, :line_index_in_file, extent: 22.0]

  @type t :: %__MODULE__{
          file: Rail.Domain.Diff.FileDiff.t(),
          line: Rail.Domain.Diff.DiffLine.t(),
          line_index_in_file: non_neg_integer() | nil,
          extent: float()
        }
end

defmodule Rail.Domain.Diff.GapRow do
  @moduledoc "Unchanged code gap between two hunks that can be expanded in place."
  @enforce_keys [:file, :gap_index, :start_line, :end_line, :count, :old_start_line, :key]
  defstruct [:file, :gap_index, :start_line, :end_line, :count, :old_start_line, :key, extent: 28.0]

  @type t :: %__MODULE__{
          file: Rail.Domain.Diff.FileDiff.t(),
          gap_index: non_neg_integer(),
          start_line: pos_integer(),
          end_line: pos_integer(),
          count: pos_integer(),
          old_start_line: pos_integer(),
          key: String.t(),
          extent: float()
        }
end

defmodule Rail.Domain.Diff.DiffFileSection do
  @moduledoc "Section representing a single file in the diff with header and body rows."
  @enforce_keys [:header, :body_rows, :start_offset, :file]
  defstruct [:header, :body_rows, :start_offset, :file]

  @type t :: %__MODULE__{
          header: Rail.Domain.Diff.FileHeaderRow.t(),
          body_rows: list(any()),
          start_offset: float(),
          file: Rail.Domain.Diff.FileDiff.t()
        }
end

defmodule Rail.Domain.Diff.DiffRowLayout do
  @moduledoc "Layout result holding flattened rows and precomputed scroll offsets."
  @enforce_keys [:sections, :rows, :offset_of_file]
  defstruct [:sections, :rows, :offset_of_file, max_line_chars: 0]

  @type t :: %__MODULE__{
          sections: list(Rail.Domain.Diff.DiffFileSection.t()),
          rows: list(any()),
          offset_of_file: %{String.t() => float()},
          max_line_chars: non_neg_integer()
        }

  @doc "Returns the total number of flattened rows."
  def row_count(%__MODULE__{rows: rows}), do: length(rows)

  @doc "Returns the extent of the row at the specified 0-based index."
  def extent_at(%__MODULE__{rows: rows}, index), do: Enum.at(rows, index).extent
end

defmodule Rail.Domain.Diff.DiffRowModel do
  @moduledoc """
  Flattens a list of `FileDiff` structs and active viewed / gap expansion state
  into a linear list of fixed-height `DiffRow` items.
  """

  alias Rail.Domain.Diff.BinaryNoticeRow
  alias Rail.Domain.Diff.DiffFileSection
  alias Rail.Domain.Diff.DiffLine
  alias Rail.Domain.Diff.DiffRowLayout
  alias Rail.Domain.Diff.FileDiff
  alias Rail.Domain.Diff.FileHeaderRow
  alias Rail.Domain.Diff.GapRow
  alias Rail.Domain.Diff.HunkHeaderRow
  alias Rail.Domain.Diff.LineRow

  @doc """
  Builds a `DiffRowLayout` from files, viewed files map/set, and expanded gaps map.
  Supports both keyword options or positional arguments.
  """
  def build_rows(opts) when is_list(opts) and is_tuple(hd(opts)) do
    files = Keyword.get(opts, :files, [])
    viewed_files = Keyword.get(opts, :viewed_files, %{})
    expanded_gaps = Keyword.get(opts, :expanded_gaps, %{})
    build_rows(files, viewed_files, expanded_gaps)
  end

  def build_rows(files, viewed_files \\ %{}, expanded_gaps \\ %{}) when is_list(files) do
    expanded_gaps = expanded_gaps || %{}

    {sections, _offset, max_chars} =
      Enum.reduce(files, {[], 0.0, 0}, fn file, {sec_acc, offset, max_c} ->
        viewed = file_viewed?(viewed_files, file.path)
        sec_start = offset

        header_row = %FileHeaderRow{file: file, is_viewed: viewed, extent: 40.0}
        offset_after_header = offset + header_row.extent

        {body_rows, final_offset, updated_max_c} =
          if viewed do
            {[], offset_after_header, max_c}
          else
            build_file_body(file, expanded_gaps, offset_after_header, max_c)
          end

        section = %DiffFileSection{
          header: header_row,
          body_rows: body_rows,
          start_offset: sec_start,
          file: file
        }

        {[section | sec_acc], final_offset, updated_max_c}
      end)

    ordered_sections = Enum.reverse(sections)
    flattened_rows = Enum.flat_map(ordered_sections, fn s -> [s.header | s.body_rows] end)

    offset_of_file =
      Map.new(ordered_sections, fn section ->
        {section.file.path, section.start_offset}
      end)

    %DiffRowLayout{
      sections: ordered_sections,
      rows: flattened_rows,
      offset_of_file: offset_of_file,
      max_line_chars: max_chars
    }
  end

  defp build_file_body(%FileDiff{is_binary: true} = file, _expanded_gaps, offset, max_chars) do
    row = %BinaryNoticeRow{file: file, extent: 36.0}
    {[row], offset + row.extent, max_chars}
  end

  defp build_file_body(%FileDiff{} = file, expanded_gaps, offset, max_chars) do
    {body_rows, final_offset, final_max_c, _line_idx} =
      file.hunks
      |> Enum.with_index()
      |> Enum.reduce({[], offset, max_chars, 0}, fn {hunk, h_idx}, {rows_acc, cur_offset, cur_max_c, cur_line_idx} ->
        # Check for gap before this hunk
        {gap_rows, cur_offset, cur_max_c} =
          if h_idx > 0 do
            prev_hunk = Enum.at(file.hunks, h_idx - 1)
            maybe_build_gap(file, prev_hunk, hunk, h_idx - 1, expanded_gaps, cur_offset, cur_max_c)
          else
            {[], cur_offset, cur_max_c}
          end

        # Hunk header row
        hunk_header = %HunkHeaderRow{file: file, hunk: hunk, extent: 28.0}
        cur_offset = cur_offset + hunk_header.extent

        # Hunk lines
        {line_rows, cur_offset, cur_max_c, next_line_idx} =
          Enum.reduce(hunk.lines, {[], cur_offset, cur_max_c, cur_line_idx}, fn line, {l_acc, l_offset, l_max_c, l_idx} ->
            line_len = String.length(line.text)
            new_max = max(l_max_c, line_len)
            line_with_idx = %{line | line_index_in_file: l_idx}

            line_row = %LineRow{
              file: file,
              line: line_with_idx,
              line_index_in_file: l_idx,
              extent: 22.0
            }

            {[line_row | l_acc], l_offset + line_row.extent, new_max, l_idx + 1}
          end)

        new_hunk_rows = gap_rows ++ [hunk_header] ++ Enum.reverse(line_rows)
        {rows_acc ++ new_hunk_rows, cur_offset, cur_max_c, next_line_idx}
      end)

    {body_rows, final_offset, final_max_c}
  end

  defp maybe_build_gap(file, prev_hunk, hunk, gap_index, expanded_gaps, offset, max_chars) do
    prev_new_end = prev_hunk.new_start + prev_hunk.new_count - 1
    prev_old_end = prev_hunk.old_start + prev_hunk.old_count - 1
    gap_new_start = prev_new_end + 1
    gap_new_end = hunk.new_start - 1
    gap_count = gap_new_end - gap_new_start + 1

    if gap_count > 0 do
      gap_key = "#{file.path}:#{gap_index}"
      gap_old_start = prev_old_end + 1

      if Map.has_key?(expanded_gaps, gap_key) do
        fetched_lines = Map.get(expanded_gaps, gap_key)

        {expanded_rows, new_offset, new_max_c} =
          fetched_lines
          |> Enum.with_index()
          |> Enum.reduce({[], offset, max_chars}, fn {text, k}, {acc, cur_off, cur_max} ->
            line_len = String.length(text)
            updated_max = max(cur_max, line_len)

            line = %DiffLine{
              kind: :context,
              old_line_number: gap_old_start + k,
              new_line_number: gap_new_start + k,
              text: text,
              line_index_in_file: nil
            }

            line_row = %LineRow{
              file: file,
              line: line,
              line_index_in_file: nil,
              extent: 22.0
            }

            {[line_row | acc], cur_off + line_row.extent, updated_max}
          end)

        {Enum.reverse(expanded_rows), new_offset, new_max_c}
      else
        gap_row = %GapRow{
          file: file,
          gap_index: gap_index,
          start_line: gap_new_start,
          end_line: gap_new_end,
          count: gap_count,
          old_start_line: gap_old_start,
          key: gap_key,
          extent: 28.0
        }

        {[gap_row], offset + gap_row.extent, max_chars}
      end
    else
      {[], offset, max_chars}
    end
  end

  defp file_viewed?(viewed_files, path) when is_map(viewed_files) do
    Map.has_key?(viewed_files, path)
  end

  defp file_viewed?(_viewed_files, _path), do: false
end
