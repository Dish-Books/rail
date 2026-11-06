defmodule RailWeb.Utils.BuildPlanSheet do
  @moduledoc """
  The plan sheet `ImplementationPlan.build_sheet/1` makes, its cards grouped by where the code goes, with every part a
  reader can comment on as a line, as `build_document_blocks/1` makes them, numbered in the order the page draws them.
  """

  import RailWeb.Utils.BuildDocumentBlocks
  import RailWeb.Utils.BuildPlanCards
  import RailWeb.Utils.RenderMarkdown

  alias Rail.Pipeline.Schemas.ImplementationPlan

  @line %{
    key: nil,
    kind: nil,
    text: "",
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

  @doc """
  Returns the plan's sheet with its cards in `groups`, and a criteria row for each of the ticket's criterion `numbers`,
  or `nil` when it does not lay out as one. `lines` holds every line in drawn order, folded and closed ones included.
  """
  def build_plan_sheet(content, numbers \\ []) when is_binary(content) do
    case ImplementationPlan.build_sheet(content) do
      %{} = sheet -> lay_out(sheet, numbers)
      nil -> nil
    end
  end

  defp lay_out(sheet, numbers) do
    {approach, counts} = section("Approach", sheet.approach, %{})
    {data_changes, counts} = items("Data changes", sheet.data_changes, &"Data change #{&1}", counts)
    {decisions, counts} = items("Decisions", sheet.decisions, &"Decisions, item #{&1}", counts)
    {changes_title, counts} = number(line(:section_title, "Changes", "Changes"), counts)
    {%{groups: groups, cards: cards}, counts} = build_plan_cards(sheet.cards, counts)
    {criteria, counts} = criteria(sheet.criteria, numbers, counts)
    {verification, _counts} = section("Verification", sheet.verification, counts)

    sheet = %{
      approach: approach,
      data_changes: data_changes,
      decisions: decisions,
      changes_title: changes_title,
      groups: groups,
      cards: cards,
      criteria: criteria,
      verification: verification
    }

    Map.put(sheet, :lines, collect(sheet))
  end

  defp section(_title, nil, counts), do: {nil, counts}

  defp section(title, markdown, counts) do
    {title_line, counts} = number(line(:section_title, title, title), counts)

    {lines, counts} =
      markdown |> build_document_blocks() |> Enum.map_reduce(counts, &number(%{&1 | label: within(title, &1.label)}, &2))

    {%{title_line: title_line, lines: lines}, counts}
  end

  defp items(_title, [], _label, counts), do: {nil, counts}

  defp items(title, items, label, counts) do
    {title_line, counts} = number(line(:section_title, title, title), counts)

    {items, counts} =
      items
      |> Enum.with_index(1)
      |> Enum.map_reduce(counts, fn {item, position}, counts ->
        [line | _nested] = build_document_blocks(item.markdown)
        {line, counts} = number(%{line | label: label.(position)}, counts)
        {Map.merge(item, %{line: line, html: render_markdown(item[:text] || item[:description])}), counts}
      end)

    {%{title_line: title_line, items: items}, counts}
  end

  # A row per criterion of the ticket or the plan, its cells as a table's would be, the ticket's words drawn by the page.
  defp criteria(criteria, numbers, counts) do
    answered = Enum.map(criteria, & &1.number)
    unanswered = for number <- Enum.uniq(numbers), number not in answered, do: %{number: number, files: [], tests: []}
    criteria(Enum.sort_by(criteria ++ unanswered, & &1.number), counts)
  end

  defp criteria([], counts), do: {nil, counts}

  defp criteria(criteria, counts) do
    {title_line, counts} = number(line(:section_title, "Acceptance criteria", "Acceptance criteria"), counts)
    last = length(criteria) - 1

    {rows, counts} =
      criteria
      |> Enum.with_index()
      |> Enum.map_reduce(counts, fn {criterion, index}, counts ->
        names = Enum.map([criterion.files, criterion.tests], fn paths -> Enum.map(paths, &Path.basename/1) end)
        text = Enum.join(["#{criterion.number}" | Enum.map(names, &Enum.join(&1, " "))], " | ")

        row =
          Map.merge(line(:table_row, text, "Criterion #{criterion.number}"), %{
            cells: Enum.map(["#{criterion.number}" | Enum.map(names, &code/1)], &render_markdown/1),
            columns: 3,
            first?: index == 0,
            last?: index == last
          })

        {row, counts} = number(row, counts)
        {Map.put(criterion, :line, row), counts}
      end)

    {%{title_line: title_line, rows: rows}, counts}
  end

  # Named by their file alone, as the cards above give each its whole path, one to a line.
  defp code(names), do: Enum.map_join(names, "\\\n", &"`#{&1}`")

  defp within(title, label), do: "#{title}, #{String.downcase(String.first(label))}#{String.slice(label, 1..-1//1)}"

  defp line(kind, text, label), do: Map.merge(@line, %{kind: kind, text: text, label: label})

  # Numbered across the whole plan, in the order it is drawn, so lines that read the same are told apart.
  defp number(%{kind: kind, text: text} = line, counts) do
    occurrence = Map.get(counts, {kind, text}, 0) + 1
    key = "#{kind}-#{:erlang.phash2({text, occurrence})}"
    {%{line | occurrence: occurrence, key: key}, Map.put(counts, {kind, text}, occurrence)}
  end

  defp collect(sheet) do
    [
      section_lines(sheet.approach),
      items_lines(sheet.data_changes),
      items_lines(sheet.decisions),
      sheet.changes_title,
      Enum.map(sheet.cards, &[&1.line, &1.prose, &1.signatures, &1.sketch]),
      sheet.criteria && [sheet.criteria.title_line, Enum.map(sheet.criteria.rows, & &1.line)],
      section_lines(sheet.verification)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp section_lines(nil), do: nil
  defp section_lines(section), do: [section.title_line, section.lines]

  defp items_lines(nil), do: nil
  defp items_lines(section), do: [section.title_line, Enum.map(section.items, & &1.line)]
end
