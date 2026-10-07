defmodule RailWeb.Utils.BuildDocumentBlocks do
  @moduledoc """
  Splits markdown into the lines a reader comments on, in reading order: each heading, paragraph, list item at any
  depth, table row, blockquote and line of a code block. A list item is only its own text, so a nested one is a line
  of its own and editing it never moves a comment on its parent.
  """

  import RailWeb.Utils.RenderMarkdown

  @extension [autolink: true, strikethrough: true, table: true, tasklist: true]

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
  Returns the lines of `markdown`, each with its `key`, `kind`, anchor `text`, `occurrence` among lines of its kind
  that read the same, readable `label`, and what the page draws it from: its `html`, or a code line's `number`, a
  list item's `depth` and `marker`, a table row's `cells`.
  """
  def build_document_blocks(markdown) when is_binary(markdown) do
    markdown
    |> MDEx.parse_document!(extension: @extension)
    |> Map.fetch!(:nodes)
    |> Enum.reduce(%{lines: [], section: nil, counts: %{}}, &block/2)
    |> Map.fetch!(:lines)
    |> Enum.reverse()
    |> number_lines()
  end

  defp block(%MDEx.Heading{} = heading, state) do
    {count, state} = count(state, :heading)
    state = add(state, %{kind: :heading, text: text(heading), label: "Heading #{count}", html: html([heading])})
    %{state | section: text(heading), counts: Map.delete(state.counts, :item)}
  end

  defp block(%MDEx.List{} = list, state), do: list_items(list, [], state)

  defp block(%MDEx.Table{nodes: rows}, state) do
    {table, state} = count(state, :table)
    columns = rows |> List.first() |> Map.fetch!(:nodes) |> length()
    last = length(rows) - 1

    rows
    |> Enum.with_index()
    |> Enum.reduce(state, fn {%MDEx.TableRow{header: header?, nodes: cells}, index}, state ->
      prefix = if table == 1, do: "Table", else: "Table #{table},"
      label = if header?, do: "#{prefix} header", else: "#{prefix} row #{index}"

      add(state, %{
        kind: :table_row,
        text: Enum.map_join(cells, " | ", &text/1),
        label: label,
        cells: Enum.map(cells, &html([%MDEx.Paragraph{nodes: &1.nodes}])),
        header?: header?,
        columns: columns,
        first?: index == 0,
        last?: index == last
      })
    end)
  end

  defp block(%MDEx.CodeBlock{literal: literal}, state) do
    {block, state} = count(state, :code)
    lines = literal |> String.trim_trailing("\n") |> String.split("\n")
    last = length(lines)
    prefix = if block == 1, do: "Code line", else: "Code block #{block}, line"

    lines
    |> Enum.with_index(1)
    |> Enum.reduce(state, fn {line, number}, state ->
      add(state, %{
        kind: :code,
        text: line,
        label: "#{prefix} #{number}",
        number: number,
        first?: number == 1,
        last?: number == last
      })
    end)
  end

  defp block(%MDEx.BlockQuote{nodes: nodes} = quote, state) do
    {count, state} = count(state, :blockquote)
    add(state, %{kind: :blockquote, text: text(quote), label: "Blockquote #{count}", html: html(nodes)})
  end

  defp block(%MDEx.ThematicBreak{}, state), do: state

  # A paragraph, or anything else that holds words, such as an HTML block, which is escaped like the rest.
  defp block(node, state) do
    {count, state} = count(state, :paragraph)
    add(state, %{kind: :paragraph, text: text(node), label: "Paragraph #{count}", html: html([node])})
  end

  defp list_items(%MDEx.List{nodes: items} = list, path, state) do
    items
    |> Enum.with_index()
    |> Enum.reduce(state, fn {item, index}, state ->
      {position, state} = if path == [], do: count(state, :item), else: {index + 1, state}
      # Held innermost first, so an item's position is pushed rather than appended.
      path = [position | path]
      {own, nested} = Enum.split_with(item.nodes, &(not match?(%MDEx.List{}, &1)))

      state =
        add(state, %{
          kind: :list_item,
          text: own |> Enum.map_join(" ", &text/1) |> String.trim(),
          label: item_label(state.section, path |> Enum.reverse() |> Enum.join(".")),
          html: html(own),
          depth: length(path) - 1,
          marker: marker(list, item, index)
        })

      Enum.reduce(nested, state, &list_items(&1, path, &2))
    end)
  end

  defp item_label(nil, position), do: "Item #{position}"

  defp item_label(section, position) do
    if Regex.match?(~r/\Aacceptance criteria\z/i, String.trim(section)),
      do: "Criterion #{position}",
      else: "#{section}, item #{position}"
  end

  defp marker(_list, %MDEx.TaskItem{checked: checked}, _index), do: {:task, checked}
  defp marker(%MDEx.List{list_type: :ordered, start: start}, _item, index), do: {:ordered, start + index}
  defp marker(_list, _item, _index), do: :bullet

  defp count(state, counter) do
    count = Map.get(state.counts, counter, 0) + 1
    {count, %{state | counts: Map.put(state.counts, counter, count)}}
  end

  defp add(state, line), do: %{state | lines: [Map.merge(@line, line) | state.lines]}

  # Numbered once every line is in, so two lines that read the same are told apart by which comes first.
  defp number_lines(lines) do
    {lines, _counts} =
      Enum.map_reduce(lines, %{}, fn line, counts ->
        occurrence = Map.get(counts, {line.kind, line.text}, 0) + 1
        key = "#{line.kind}-#{:erlang.phash2({line.text, occurrence})}"
        {%{line | occurrence: occurrence, key: key}, Map.put(counts, {line.kind, line.text}, occurrence)}
      end)

    lines
  end

  defp html(nodes), do: render_markdown(MDEx.to_markdown!(%MDEx.Document{nodes: nodes}, extension: @extension))

  defp text(node), do: node |> raw_text() |> String.split() |> Enum.join(" ")

  # Words inside a paragraph run together as written; the blocks inside a quote or a list are kept apart.
  defp raw_text(%{literal: literal}) when is_binary(literal), do: literal

  defp raw_text(%{nodes: nodes} = node) when is_struct(node, MDEx.BlockQuote) or is_struct(node, MDEx.List),
    do: Enum.map_join(nodes, " ", &raw_text/1)

  defp raw_text(%{nodes: nodes} = node) when is_struct(node, MDEx.ListItem) or is_struct(node, MDEx.TaskItem),
    do: Enum.map_join(nodes, " ", &raw_text/1)

  defp raw_text(%{nodes: nodes}), do: Enum.map_join(nodes, &raw_text/1)
  defp raw_text(_break), do: " "
end
