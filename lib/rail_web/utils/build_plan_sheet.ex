defmodule RailWeb.Utils.BuildPlanSheet do
  @moduledoc """
  The plan sheet `ImplementationPlan.build_sheet/1` makes, with every part of it a reader can comment on as a line,
  as `build_document_blocks/1` makes them: section titles and text, the In this plan card, files, module cards, and
  each diagram's source lines and nodes.
  """

  import RailWeb.Utils.BuildDocumentBlocks

  alias Rail.Pipeline.Schemas.ImplementationPlan

  @titles %{change: "Change diagram", call_flow: "Call flow"}

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
  Returns the plan's sheet with its lines, or `nil` when it does not lay out as one. A diagram's `nodes` are the ids it
  defines, links or declares, and `lines` holds every line in reading order.
  """
  def build_plan_sheet(content) when is_binary(content) do
    case ImplementationPlan.build_sheet(content) do
      %{} = sheet -> sheet |> add_lines() |> number_lines()
      nil -> nil
    end
  end

  # Each part's lines, labelled as the page names them; their keys and occurrences come once all are in.
  defp add_lines(sheet) do
    summary = summary(sheet)

    Map.merge(
      %{
        sheet
        | diagrams: Enum.map(sheet.diagrams, &diagram_lines/1),
          files: Enum.map(sheet.files, &Map.put(&1, :line, line(:file, &1.path, "File #{&1.number}"))),
          modules: Enum.map(sheet.modules, &module_lines/1),
          rest: Enum.map(sheet.rest, &Map.merge(&1, section_lines(&1.title, &1.body)))
      },
      %{
        approach_lines: section_lines("Approach", sheet.approach),
        no_diagrams_line: sheet.no_diagrams && line(:paragraph, sheet.no_diagrams, "Approach, no diagrams"),
        summary: summary,
        files_title: line(:section_title, "File-level changes", "File-level changes"),
        program_title: line(:section_title, "Program design", "Program design"),
        verification_lines: sheet.verification && section_lines("Verification", sheet.verification),
        assumptions_lines: sheet.assumptions && section_lines("Assumptions", sheet.assumptions)
      }
    )
  end

  # What the In this plan card says, worded here so each line is one a reader can comment on.
  defp summary(sheet) do
    unlisted =
      Enum.count(sheet.modules, &(not MapSet.member?(MapSet.new(sheet.files, fn file -> file.path end), &1.path)))

    kinds = Enum.map(sheet.diagrams, & &1.kind)

    tally =
      Enum.map_join(
        [{length(sheet.files), "file"}, {length(sheet.modules), "module"}, {length(sheet.diagrams), "diagram"}],
        " · ",
        fn {count, noun} -> "#{count} #{if count == 1, do: noun, else: noun <> "s"}" end
      )

    lines =
      [
        {[:call_flow, :change] -- kinds == [], :check, "Change diagram and call flow"},
        {is_binary(sheet.no_diagrams), :absent, "No diagrams, as the plan explains"},
        {sheet.modules != [] and unlisted == 0, :check, "Every module in Program design is in File-level changes"},
        {unlisted == 1, :warning, "1 module in Program design is not in File-level changes"},
        {unlisted > 1, :warning, "#{unlisted} modules in Program design are not in File-level changes"},
        {sheet.modules == [], :absent, "No program design: no application code changes"}
      ]
      |> Enum.filter(&elem(&1, 0))
      |> Enum.with_index(2)
      |> Enum.map(fn {{true, tone, text}, number} ->
        %{tone: tone, line: line(:summary, text, "In this plan, line #{number}")}
      end)

    %{tally: line(:summary, tally, "In this plan, line 1"), lines: lines}
  end

  defp section_lines(title, markdown) do
    %{
      title_line: title && line(:section_title, title, title),
      lines: Enum.map(build_document_blocks(markdown || ""), &%{&1 | label: within(title, &1.label)})
    }
  end

  defp within(nil, label), do: label
  defp within(title, label), do: "#{title}, #{String.downcase(String.first(label))}#{String.slice(label, 1..-1//1)}"

  defp diagram_lines(%{kind: kind, source: source} = diagram) do
    title = Map.fetch!(@titles, kind)
    sources = source |> String.trim_trailing("\n") |> String.split("\n")
    last = length(sources)

    Map.merge(diagram, %{
      source_lines:
        sources
        |> Enum.with_index(1)
        |> Enum.map(fn {text, number} ->
          Map.merge(line(:source, text, "#{title} line #{number}"), %{
            number: number,
            first?: number == 1,
            last?: number == last
          })
        end),
      nodes: source |> node_ids() |> Enum.map(&line(:node, &1, "#{title} node"))
    })
  end

  defp module_lines(%{name: name, path: path, signatures: signatures} = module) do
    short = name |> String.split(".") |> List.last()

    signature_lines =
      for line <- build_document_blocks(signatures) do
        if line.kind == :code,
          do: %{line | kind: :signature, label: "#{short} line #{line.number}"},
          else: %{line | label: within(short, line.label)}
      end

    Map.merge(module, %{
      name_line: line(:module, name, name),
      path_line: path && line(:module, path, "#{short} file"),
      signature_lines: signature_lines
    })
  end

  defp line(kind, text, label), do: Map.merge(@line, %{kind: kind, text: text, label: label})

  # The ids Mermaid draws a node for: every one a flowchart defines or links, and every participant a sequence
  # diagram declares or messages. A line it cannot read adds none, so that node only goes without its +.
  defp node_ids(source) do
    [header | body] = source |> String.split("\n") |> Enum.map(&String.trim/1)

    ids =
      if String.starts_with?(header, "sequenceDiagram"),
        do: Enum.flat_map(body, &participants/1),
        else: Enum.flat_map(body, &flowchart_ids/1)

    Enum.uniq(ids)
  end

  defp participants(line) do
    cond do
      match = Regex.run(~r/\A(?:participant|actor)\s+(\S+?)(?:\s+as\s+.*)?\z/, line) ->
        [Enum.at(match, 1)]

      match =
          Regex.run(
            ~r/\A([^\s:+-][^:]*?)\s*(?:<<-->>|<<->>|-->>|->>|--x|-x|--\)|-\)|-->|->)\s*[+-]?\s*([^:]+?)\s*:/,
            line
          ) ->
        [Enum.at(match, 1), Enum.at(match, 2)]

      true ->
        []
    end
  end

  @flowchart_skip ~r/\A(%%|classDef\s|class\s|style\s|linkStyle\s|click\s|subgraph\b|end\b|direction\s|flowchart\b|graph\b)/

  defp flowchart_ids(line) do
    if line == "" or Regex.match?(@flowchart_skip, line) do
      []
    else
      line
      |> String.replace(~r/"[^"]*"/, "")
      |> String.replace(~r/\|[^|]*\|/, "")
      |> String.replace(~r/(?:--|==|-\.)\s[^-=.>]*?\s*(?:-->|---|==>|===|\.->|\.-)/, " --> ")
      |> String.replace(~r/(?<=\w)(\[|\(|\{|>)[^\]\)\}]*(\]|\)|\})+/, "")
      |> String.replace(~r/:::[\w-]+/, "")
      |> String.split(~r/\s*(?:&|<?(?:-{2,}|={2,}|-\.+-?|~{3,})[->ox]?)\s*/)
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&Regex.match?(~r/\A[A-Za-z0-9_][\w-]*\z/, &1))
    end
  end

  # Numbered across the whole plan, in the order it reads, so lines that read the same are told apart.
  defp number_lines(sheet) do
    parts = [
      :approach_lines,
      :no_diagrams_line,
      :summary,
      :diagrams,
      :files_title,
      :files,
      :program_title,
      :modules,
      :verification_lines,
      :assumptions_lines,
      :rest
    ]

    {sheet, _counts} = number_in(sheet, parts, %{})
    Map.put(sheet, :lines, collect(sheet))
  end

  defp number(nil, counts), do: {nil, counts}

  defp number(%{lines: lines, title_line: title} = section, counts) do
    {title, counts} = number(title, counts)
    {lines, counts} = number(lines, counts)
    {%{section | title_line: title, lines: lines}, counts}
  end

  defp number(list, counts) when is_list(list), do: Enum.map_reduce(list, counts, &number/2)
  defp number(%{tally: _tally} = summary, counts), do: number_in(summary, [:tally, :lines], counts)
  defp number(%{tone: _tone} = summary, counts), do: number_in(summary, [:line], counts)
  defp number(%{source_lines: _sources} = diagram, counts), do: number_in(diagram, [:source_lines, :nodes], counts)
  defp number(%{path: _path, line: _line} = file, counts), do: number_in(file, [:line], counts)

  defp number(%{name_line: _name} = module, counts),
    do: number_in(module, [:name_line, :path_line, :signature_lines], counts)

  defp number(%{kind: kind, text: text} = line, counts) do
    occurrence = Map.get(counts, {kind, text}, 0) + 1
    key = "#{kind}-#{:erlang.phash2({text, occurrence})}"
    {%{line | occurrence: occurrence, key: key}, Map.put(counts, {kind, text}, occurrence)}
  end

  defp number_in(map, fields, counts) do
    Enum.reduce(fields, {map, counts}, fn field, {map, counts} ->
      {value, counts} = number(Map.fetch!(map, field), counts)
      {Map.put(map, field, value), counts}
    end)
  end

  defp collect(sheet) do
    [
      sheet.approach_lines.title_line,
      sheet.approach_lines.lines,
      sheet.no_diagrams_line,
      sheet.summary.tally,
      Enum.map(sheet.summary.lines, & &1.line),
      Enum.map(sheet.diagrams, &[&1.source_lines, &1.nodes]),
      sheet.files_title,
      Enum.map(sheet.files, & &1.line),
      sheet.program_title,
      Enum.map(sheet.modules, &[&1.name_line, &1.path_line, &1.signature_lines]),
      sheet.verification_lines && [sheet.verification_lines.title_line, sheet.verification_lines.lines],
      sheet.assumptions_lines && [sheet.assumptions_lines.title_line, sheet.assumptions_lines.lines],
      Enum.map(sheet.rest, &[&1.title_line, &1.lines])
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end
end
