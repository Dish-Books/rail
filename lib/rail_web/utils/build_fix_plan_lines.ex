defmodule RailWeb.Utils.BuildFixPlanLines do
  @moduledoc """
  Splits a fix round's plan, as `FixPlan.build_sheet/1` lays it out, into the lines a reader comments on: the changes
  to the plan, the summary, each item's body, each file's card, as a plan's are, and Verification. Each line's label
  names the part of the sheet it is in, so a comment read away from the page still says where it was written, and
  lines are numbered across the whole sheet, so two that read the same in different parts are told apart.
  """

  import RailWeb.Utils.BuildDocumentBlocks
  import RailWeb.Utils.BuildPlanCards

  @doc """
  Returns `sheet` with the lines of each of its parts beside it, `changes_lines`, `summary_lines`, each item's
  `body_lines` and the cards it names as `%{number:, path:}`, the files' `files_title` line, their cards in `groups`
  and `cards`, `verification_lines`, and every line in reading order as `lines`.
  """
  def build_fix_plan_lines(sheet) do
    {changes, counts} = number(blocks(sheet.changes, "Changes to the plan"), %{})
    {summary, counts} = number(blocks(sheet.summary, "Summary"), counts)

    {items, counts} =
      Enum.map_reduce(sheet.items, counts, fn item, counts ->
        {body, counts} = number(blocks(item.body, item_part(item)), counts)
        {Map.put(item, :body_lines, body), counts}
      end)

    {files_title, counts} = number(files_title(sheet.files), counts)
    {%{groups: groups, cards: cards}, counts} = build_plan_cards(sheet.files, counts)
    {verification, _counts} = number(blocks(sheet.verification, "Verification"), counts)

    # A mark is for its round's card, so the next round's card for the same file reads unreviewed rather than revised.
    in_round = &%{&1 | digest: "#{sheet.round}-#{&1.digest}"}
    cards = Enum.map(cards, in_round)
    groups = Enum.map(groups, &%{&1 | cards: Enum.map(&1.cards, in_round)})

    numbers = Map.new(cards, &{&1.path, &1.number})
    items = Enum.map(items, fn item -> %{item | files: Enum.map(item.files, &%{number: numbers[&1], path: &1})} end)

    lines =
      changes ++
        summary ++
        Enum.flat_map(items, & &1.body_lines) ++
        files_title ++ Enum.flat_map(cards, &[&1.line, &1.prose, &1.signatures, &1.sketch]) ++ verification

    Map.merge(sheet, %{
      changes_lines: changes,
      summary_lines: summary,
      items: items,
      files_title: List.first(files_title),
      groups: groups,
      cards: cards,
      verification_lines: verification,
      lines: List.flatten(lines)
    })
  end

  defp item_part(%{kind: :finding, key: key}), do: "Fix finding #{key}"
  defp item_part(%{kind: :comment, number: number}), do: "Comment #{number}"

  defp files_title([]), do: []
  defp files_title(_files), do: [%{line(:section_title, "File-level changes") | label: "File-level changes"}]

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
