defmodule RailWeb.Utils.BuildFixPlanLines do
  @moduledoc """
  Splits a fix round's plan, as `FixPlan.build_sheet/1` lays it out, into the lines a reader comments on: the changes
  to the plan, the summary, each item's body, each file's path and description, and Verification. Each line's label
  names the part of the sheet it is in, so a comment read away from the page still says where it was written, and
  lines are numbered across the whole sheet, so two that read the same in different parts are told apart.
  """

  import RailWeb.Utils.BuildDocumentBlocks

  @doc """
  Returns `sheet` with the lines of each of its parts beside it, `changes_lines`, `summary_lines`, each item's
  `body_lines`, each file's `path_line` and `description_lines` and `verification_lines`, and every line in reading
  order as `lines`.
  """
  def build_fix_plan_lines(sheet) do
    {changes, counts} = number(blocks(sheet.changes, "Changes to the plan"), %{})
    {summary, counts} = number(blocks(sheet.summary, "Summary"), counts)

    {items, counts} =
      Enum.map_reduce(sheet.items, counts, fn item, counts ->
        {body, counts} = number(blocks(item.body, item_part(item)), counts)
        {Map.put(item, :body_lines, body), counts}
      end)

    {files, counts} =
      Enum.map_reduce(sheet.files, counts, fn file, counts ->
        path = %{line(:file, file.path) | label: "File #{file.number}"}
        {[path], counts} = number([path], counts)
        {description, counts} = number(blocks(file.description, "File #{file.number}"), counts)
        {file |> Map.put(:path_line, path) |> Map.put(:description_lines, description), counts}
      end)

    {verification, _counts} = number(blocks(sheet.verification, "Verification"), counts)

    lines =
      changes ++
        summary ++
        Enum.flat_map(items, & &1.body_lines) ++
        Enum.flat_map(files, &[&1.path_line | &1.description_lines]) ++ verification

    Map.merge(sheet, %{
      changes_lines: changes,
      summary_lines: summary,
      items: items,
      files: files,
      verification_lines: verification,
      lines: lines
    })
  end

  defp item_part(%{kind: :finding, key: key}), do: "Fix finding #{key}"
  defp item_part(%{kind: :comment, number: number}), do: "Comment #{number}"

  defp blocks(nil, _part), do: []
  defp blocks("", _part), do: []

  defp blocks(markdown, part) do
    for line <- build_document_blocks(markdown), do: %{line | label: "#{part}, #{downcase_first(line.label)}"}
  end

  defp line(kind, text) do
    %{
      key: nil,
      kind: kind,
      text: text,
      occurrence: 1,
      label: nil,
      html: nil,
      depth: 0,
      marker: nil,
      cells: [],
      header?: false,
      columns: 0,
      number: nil,
      first?: false,
      last?: false
    }
  end

  defp downcase_first(<<first::utf8, rest::binary>>), do: String.downcase(<<first::utf8>>) <> rest

  # Across the whole sheet, as the plan's own sheet numbers its lines.
  defp number(lines, counts) do
    Enum.map_reduce(lines, counts, fn %{kind: kind, text: text} = line, counts ->
      occurrence = Map.get(counts, {kind, text}, 0) + 1
      key = "#{kind}-#{:erlang.phash2({text, occurrence})}"
      {%{line | occurrence: occurrence, key: key}, Map.put(counts, {kind, text}, occurrence)}
    end)
  end
end
