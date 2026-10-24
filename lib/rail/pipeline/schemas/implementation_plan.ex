defmodule Rail.Pipeline.Schemas.ImplementationPlan do
  @moduledoc """
  How Rail reads an implementation plan: the `###` sections it lays one out by, the checks a saved plan has to
  pass, and the sheet the page shows. The plan itself is its round's.
  """
  import Ecto.Changeset

  @heading ~r/\A## Implementation plan\s*(\n|\z)/

  # The `###` sections Rail lays a plan out by, in their order. Data changes only when tables or columns change.
  @sections ["Approach", "Data changes", "Decisions", "Changes", "Acceptance criteria", "Verification"]
  @required @sections -- ["Data changes"]

  @decision_kinds %{"Decision" => :decision, "Ruled out" => :ruled_out, "Assumption" => :assumption}

  @extension [autolink: true, strikethrough: true, table: true, tasklist: true]

  @empty %{approach: nil, data_changes: [], decisions: [], cards: nil, criteria: [], verification: nil}

  # Rail lays a plan out for review by its sections, so one whose shape is off is refused with what
  # to fix, rather than shown broken. Only the shape is checked, never how long or how good it is.
  @doc """
  Refuses a plan in `field` whose sections are not the ones Rail lays a plan out by, saying what to
  fix. A field already refused, such as for its heading, is left as it is.
  """
  def validate_structure(%Ecto.Changeset{} = changeset, field) do
    if Keyword.has_key?(changeset.errors, field) do
      changeset
    else
      validate_change(changeset, field, fn ^field, plan ->
        {lead, sections} = plan |> String.replace(@heading, "") |> sections()

        errors =
          lead_errors(lead) ++
            title_errors(Enum.map(sections, &elem(&1, 0))) ++ Enum.flat_map(sections, &section_errors/1)

        errors = if errors == [], do: sheet_errors(build_sheet(plan)), else: errors
        Enum.map(errors, &{field, &1})
      end)
    end
  end

  @doc """
  Splits a plan into the parts the plan sheet lays out, or `nil` when it does not lay out, as a plan saved before
  `### Changes` does not. Prose comes back as markdown, each item with its own bullet, and a card's code fenced.
  """
  def build_sheet(content) when is_binary(content) do
    content
    |> MDEx.parse_document!(extension: @extension)
    |> Map.fetch!(:nodes)
    |> split(3)
    |> Enum.reduce(@empty, &place/2)
    |> finish()
  end

  @doc """
  Refuses markdown in `field` whose `### File-level changes` section is not the cards a fix plan's sheet lays out,
  each as a plan's `### Changes` card is. Markdown without the section is left alone.
  """
  def validate_file_changes(%Ecto.Changeset{} = changeset, field) do
    validate_change(changeset, field, fn ^field, content ->
      case content |> sections() |> elem(1) |> List.keyfind("File-level changes", 0) do
        {_title, lines} ->
          errors = card_section_errors(lines, "File-level changes")

          errors =
            if errors == [] and build_file_changes(content) == nil,
              do: ["does not lay out its `### File-level changes` as a `#### `path/to/file`` card for each file"],
              else: errors

          Enum.map(errors, &{field, &1})

        nil ->
          []
      end
    end)
  end

  @doc """
  The cards of any markdown's `### File-level changes`, each as `build_sheet/1` reads a plan's, or `nil` when it has no
  such section or the section does not lay out. A section of bullets, as a fix plan saved before cards wrote it, reads
  as a card of prose per bullet.
  """
  def build_file_changes(content) when is_binary(content) do
    content
    |> MDEx.parse_document!(extension: @extension)
    |> Map.fetch!(:nodes)
    |> split(3)
    |> Enum.find_value(fn
      {%MDEx.Heading{} = heading, body} -> if text(heading) == "File-level changes", do: file_cards(body)
      {nil, _preamble} -> nil
    end)
    |> case do
      [_first | _rest] = cards -> cards
      _absent_or_unlaid -> nil
    end
  end

  # Splits on the `###` headings outside fenced blocks, keeping each section's body as lines.
  defp sections(body) do
    {lead, sections} = body |> String.split("\n") |> split_lines(~r/\A### (.+?)\s*\z/)
    {lead, Enum.map(sections, fn {[_line, title], lines} -> {title, lines} end)}
  end

  # Lines before the first heading `pattern` matches outside a fence, then each heading's match and its lines.
  defp split_lines(lines, pattern) do
    {lead, sections, _fenced} =
      Enum.reduce(lines, {[], [], false}, fn line, {lead, sections, fenced} ->
        fenced = if String.starts_with?(line, "```"), do: not fenced, else: fenced

        case {fenced, Regex.run(pattern, line), sections} do
          {false, [_line | _captures] = match, _sections} -> {lead, [{match, []} | sections], fenced}
          {_fenced, _not_a_heading, []} -> {[line | lead], [], fenced}
          {_fenced, _not_a_heading, [{match, lines} | rest]} -> {lead, [{match, [line | lines]} | rest], fenced}
        end
      end)

    {Enum.reverse(lead), sections |> Enum.reverse() |> Enum.map(fn {match, lines} -> {match, Enum.reverse(lines)} end)}
  end

  defp lead_errors(lead) do
    if Enum.all?(lead, &(String.trim(&1) == "")),
      do: [],
      else: [
        "has text between `## Implementation plan` and `### Approach`; every part of the plan goes under its section"
      ]
  end

  defp title_errors(titles) do
    unknown = Enum.reject(titles, &(&1 in @sections))

    duplicated =
      titles |> Enum.frequencies() |> Enum.filter(fn {_title, count} -> count > 1 end) |> Enum.map(&elem(&1, 0))

    known = Enum.filter(titles, &(&1 in @sections))

    Enum.map(unknown, &"has a `### #{&1}` section, but the sections are #{listed()}, with exactly these titles") ++
      Enum.map(duplicated, &"has `### #{&1}` more than once") ++
      Enum.map(@required -- titles, &"is missing its `### #{&1}` section") ++
      order_errors(known)
  end

  defp order_errors(known) do
    if Enum.uniq(known) == Enum.filter(@sections, &(&1 in known)),
      do: [],
      else: ["has its sections out of order; they go #{listed()}"]
  end

  defp section_errors({"Data changes", lines}) do
    bullet_errors(
      lines,
      "Data changes",
      ~r/\A[-*+] [^`\s][^`]*`[^`]+`/,
      "a bullet giving the change's kind and then the table or column in backticks, " <>
        "such as `* New column `users.slack_notifications`: ...`"
    )
  end

  defp section_errors({"Decisions", lines}) do
    bullet_errors(
      lines,
      "Decisions",
      ~r/\A[-*+] (Decision|Ruled out|Assumption): /,
      "a bullet starting `Decision:`, `Ruled out:` or `Assumption:`"
    )
  end

  # The page fills each row from the ticket's criterion of that number, so each number has one bullet.
  defp section_errors({"Acceptance criteria", lines}) do
    errors =
      bullet_errors(
        lines,
        "Acceptance criteria",
        ~r/\A[-*+] \d+: /,
        "a bullet starting with the number of the ticket's criterion it answers, such as `* 1: `lib/a.ex``"
      )

    numbers = for line <- lines, [_line, number] <- [Regex.run(~r/\A[-*+] (\d+):/, line)], do: number

    errors ++
      Enum.map(
        duplicates(numbers),
        &"has criterion #{&1} more than once under `### Acceptance criteria`; give each criterion one bullet"
      )
  end

  defp section_errors({"Changes", lines}), do: card_section_errors(lines, "Changes")
  defp section_errors({_title, _lines}), do: []

  # The sheet reads each `####` as a file's card, so nothing comes before the first, and each names its file.
  defp card_section_errors(lines, title) do
    {lead, cards} = split_lines(lines, ~r/\A#### .*\z/)
    headings = Enum.map(cards, fn {[heading], _body} -> heading end)
    paths = for heading <- headings, [_heading, path] <- [Regex.run(~r/\A#### `([^`]+)`/, heading)], do: path

    cond do
      Enum.any?(lead, &(String.trim(&1) != "")) or cards == [] ->
        ["needs `### #{title}` to be a `#### `path/to/file`` card for each file, each saying what changes in it"]

      Enum.any?(headings, &(not Regex.match?(~r/\A#### `[^`]+`( deleted)?\s*\z/, &1))) ->
        ["has a heading under `### #{title}` that is not `#### `path/to/file``, optionally followed by `deleted`"]

      true ->
        Enum.map(duplicates(paths), &"lists `#{&1}` more than once under `### #{title}`; give each file one card") ++
          Enum.flat_map(cards, &card_errors/1)
    end
  end

  # The sheet is the last word, so nothing is saved that would show unlaid-out, or a criterion covered by nothing.
  defp sheet_errors(nil) do
    [
      "does not lay out as a plan: each section must be its own `###` block, each file under `### Changes` " <>
        "a `#### `path`` card, and the data changes, decisions and criteria flat lists of bullets"
    ]
  end

  defp sheet_errors(sheet) do
    for %{files: [], tests: [], number: number} <- sheet.criteria do
      "has criterion #{number} under `### Acceptance criteria` with no file or test in backticks; name what " <>
        "satisfies it, or leave the criterion out so it reads Not covered"
    end
  end

  defp card_errors({[heading], body}) do
    {blocks, _fenced} =
      Enum.reduce(body, {[], false}, fn line, {blocks, fenced} ->
        cond do
          String.starts_with?(line, "```") and fenced -> {blocks, false}
          String.starts_with?(line, "```") -> {[sketch?(String.trim_leading(line, "`")) | blocks], true}
          true -> {blocks, fenced}
        end
      end)

    if Enum.count(blocks, & &1) > 1 or Enum.count(blocks, &(not &1)) > 1,
      do: [
        "has more than one code block of a kind under `#{heading}`; a card holds one block of signatures and one " <>
          "marked `sketch` at most"
      ],
      else: []
  end

  defp bullet_errors(lines, title, pattern, shape) do
    lines = lines |> outside_fences() |> Enum.reject(&(String.trim(&1) == ""))

    cond do
      lines == [] ->
        ["has nothing under `### #{title}`; it is one bullet per item, each #{shape}"]

      Enum.any?(lines, &Regex.match?(~r/\A\s+([-*+]|\d+\.)\s/, &1)) ->
        ["has sub-bullets under `### #{title}`; it is one flat bullet per item"]

      Enum.any?(lines, &(not Regex.match?(pattern, &1) and not Regex.match?(~r/\A\s/, &1))) ->
        ["has a line under `### #{title}` that is not #{shape}"]

      true ->
        []
    end
  end

  defp outside_fences(lines) do
    {kept, _fenced} =
      Enum.reduce(lines, {[], false}, fn line, {kept, fenced} ->
        cond do
          String.starts_with?(line, "```") -> {kept, not fenced}
          fenced -> {kept, fenced}
          true -> {[line | kept], fenced}
        end
      end)

    Enum.reverse(kept)
  end

  defp duplicates(values) do
    values |> Enum.frequencies() |> Enum.filter(fn {_value, count} -> count > 1 end) |> Enum.map(&elem(&1, 0))
  end

  defp listed, do: Enum.map_join(@sections, ", ", &"`### #{&1}`")

  # Nothing goes above the first section but the heading the brief asks for.
  defp place({nil, body}, sheet) do
    if Enum.all?(body, &match?(%MDEx.Heading{level: 2}, &1)), do: sheet, else: :error
  end

  defp place(_section, :error), do: :error
  defp place({%MDEx.Heading{} = heading, body}, sheet), do: place({text(heading), body}, sheet)
  defp place({"Approach", body}, %{approach: nil} = sheet), do: %{sheet | approach: markdown(body)}

  defp place({"Data changes", body}, %{data_changes: []} = sheet),
    do: put(sheet, :data_changes, items(body, &data_change/1))

  defp place({"Decisions", body}, %{decisions: []} = sheet), do: put(sheet, :decisions, items(body, &decision/1))
  defp place({"Changes", body}, %{cards: nil} = sheet), do: put(sheet, :cards, cards(body))
  defp place({"Acceptance criteria", body}, %{criteria: []} = sheet), do: put(sheet, :criteria, criteria(body))
  defp place({"Verification", body}, %{verification: nil} = sheet), do: %{sheet | verification: markdown(body)}
  defp place(_unknown_or_repeated, _sheet), do: :error

  defp put(_sheet, _field, :error), do: :error
  defp put(sheet, field, value), do: Map.put(sheet, field, value)

  defp finish(%{cards: [_first | _rest]} = sheet), do: sheet
  defp finish(_not_a_sheet), do: nil

  defp split(nodes, level) do
    nodes
    |> Enum.reduce([{nil, []}], fn
      %MDEx.Heading{level: ^level} = heading, sections -> [{heading, []} | sections]
      node, [{heading, body} | sections] -> [{heading, [node | body]} | sections]
    end)
    |> Enum.map(fn {heading, body} -> {heading, Enum.reverse(body)} end)
    |> Enum.reverse()
  end

  # Each bullet of a flat list, read by `read`, which says `:error` for one it cannot lay out.
  defp items(body, read) do
    items =
      for %MDEx.List{} = list <- body,
          item <- list.nodes,
          do: read.({item, markdown([%{list | nodes: [item]}])})

    if items != [] and Enum.all?(body, &match?(%MDEx.List{}, &1)) and :error not in items, do: items, else: :error
  end

  defp data_change(
         {%MDEx.ListItem{
            nodes: [
              %MDEx.Paragraph{nodes: [%MDEx.Text{literal: kind}, %MDEx.Code{literal: name} | inline]} = lead | blocks
            ]
          }, item}
       ) do
    if String.trim(kind) == "" do
      :error
    else
      description = markdown([%{lead | nodes: trim_lead(inline, ~r/\A\s*:?\s*/)} | blocks])
      %{kind: String.trim(kind), name: name, description: description, markdown: item}
    end
  end

  defp data_change(_item), do: :error

  defp decision(
         {%MDEx.ListItem{nodes: [%MDEx.Paragraph{nodes: [%MDEx.Text{literal: literal} | _inline]} | _blocks]} = node,
          item}
       ) do
    case Regex.run(~r/\A(Decision|Ruled out|Assumption):\s*/, literal) do
      [_match, kind] ->
        [%MDEx.Paragraph{nodes: inline} = lead | blocks] = node.nodes
        text = markdown([%{lead | nodes: trim_lead(inline, ~r/\A[^:]+:\s*/)} | blocks])
        %{kind: Map.fetch!(@decision_kinds, kind), text: text, markdown: item}

      nil ->
        :error
    end
  end

  defp decision(_item), do: :error

  defp trim_lead([%MDEx.Text{literal: literal} = first | more], pattern) do
    case String.replace(literal, pattern, "") do
      "" -> more
      literal -> [%{first | literal: literal} | more]
    end
  end

  defp trim_lead(inline, _pattern), do: inline

  defp cards(body) do
    with [{nil, []} | sections] <- split(body, 4),
         cards = Enum.map(sections, &card/1),
         true <- :error not in cards,
         paths = Enum.map(cards, & &1.path),
         true <- Enum.uniq(paths) == paths do
      cards
    else
      _preamble_or_unlaid -> :error
    end
  end

  defp card({%MDEx.Heading{nodes: [%MDEx.Code{literal: path} | suffix]}, body}) do
    {sketches, rest} = Enum.split_with(body, &(match?(%MDEx.CodeBlock{}, &1) and sketch?(&1.info)))
    {signatures, prose} = Enum.split_with(rest, &match?(%MDEx.CodeBlock{}, &1))
    deleted = suffix |> Enum.map_join(&text/1) |> String.trim()

    if deleted in ["", "deleted"] and length(sketches) <= 1 and length(signatures) <= 1 do
      %{
        path: path,
        deleted?: deleted == "deleted",
        prose: markdown(prose),
        signatures: if(signatures != [], do: markdown(signatures)),
        sketch: if(sketches != [], do: markdown(sketches))
      }
    else
      :error
    end
  end

  defp card(_heading_without_a_path), do: :error

  defp sketch?(info), do: "sketch" in String.split(info || "")

  defp criteria(body) do
    with [_first | _rest] = criteria <- items(body, &criterion/1),
         numbers = Enum.map(criteria, & &1.number),
         true <- Enum.uniq(numbers) == numbers do
      Enum.sort_by(criteria, & &1.number)
    else
      _unlaid -> :error
    end
  end

  # A path naming a test goes under Test, and every other under Files.
  defp criterion(
         {%MDEx.ListItem{nodes: [%MDEx.Paragraph{nodes: [%MDEx.Text{literal: literal} | _inline]} | _blocks]} = item,
          _markdown}
       ) do
    case Regex.run(~r/\A(\d+):/, literal) do
      [_match, number] ->
        {tests, files} = item |> paths() |> Enum.split_with(&String.ends_with?(&1, ["_test.exs", ".test.js"]))
        %{number: String.to_integer(number), files: files, tests: tests}

      nil ->
        :error
    end
  end

  defp criterion(_item), do: :error

  defp paths(%MDEx.Code{literal: literal}), do: [literal]
  defp paths(%{nodes: nodes}), do: Enum.flat_map(nodes, &paths/1)
  defp paths(_leaf), do: []

  defp file_cards(body) do
    case cards(body) do
      :error -> files(body)
      cards -> cards
    end
  end

  # Each file is named by its path, so every bullet has to lead with one.
  defp files(body) do
    items = for %MDEx.List{nodes: items} <- body, item <- items, do: item

    if items != [] and Enum.all?(body, &match?(%MDEx.List{}, &1)) and Enum.all?(items, &leads_with_path?/1) do
      Enum.map(items, &file/1)
    else
      :error
    end
  end

  defp leads_with_path?(%MDEx.ListItem{nodes: [%MDEx.Paragraph{nodes: [%MDEx.Code{} | _inline]} | _blocks]}), do: true
  # A task-list bullet, or any other shape, does not lay out.
  defp leads_with_path?(_item), do: false

  defp file(%MDEx.ListItem{nodes: [%MDEx.Paragraph{nodes: [%MDEx.Code{literal: path} | inline]} = lead | blocks]}) do
    prose = markdown([%{lead | nodes: trim_lead(inline, ~r/\A\s*:?\s*/)} | blocks])
    %{path: path, deleted?: false, prose: prose, signatures: nil, sketch: nil}
  end

  defp markdown(nodes), do: %MDEx.Document{nodes: nodes} |> MDEx.to_markdown!(extension: @extension) |> String.trim()

  defp text(%{literal: literal}), do: literal
  defp text(%{nodes: nodes}), do: Enum.map_join(nodes, &text/1)
end
