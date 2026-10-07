defmodule RailWeb.Utils.BuildPlanSheet do
  @moduledoc """
  Splits an implementation plan into the sections the Review sheet lays out.

  The sheet keys off the `###` titles the Architect prompt gives word for word, so a
  plan written any other way comes back `nil` and renders as plain markdown. Every part
  of it a reader can comment on is a line, as `build_document_blocks/1` makes them.
  """

  import RailWeb.Utils.BuildDocumentBlocks

  @extension [autolink: true, strikethrough: true, table: true, tasklist: true]

  @diagrams %{"Change diagram" => :change, "Call flow" => :call_flow}

  @type_labels %{
    "flowchart" => "Flowchart",
    "graph" => "Flowchart",
    "sequenceDiagram" => "Sequence diagram",
    "classDiagram" => "Class diagram",
    "stateDiagram" => "State diagram",
    "stateDiagram-v2" => "State diagram",
    "erDiagram" => "Entity relationship diagram"
  }

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

  @empty %{
    approach: nil,
    no_diagrams: nil,
    diagrams: [],
    files: nil,
    modules: [],
    program_design?: false,
    verification: nil,
    assumptions: nil,
    rest: []
  }

  @doc """
  Returns the plan's sections as a map, or `nil` when it has no `### Approach`, no
  `### File-level changes` naming one file per bullet, or nothing only the current
  prompt writes: a diagram, a `No diagrams:` line or a `### Program design`.

  Prose comes back as markdown, so `render_markdown/2` stays the one place plan text
  becomes HTML. A diagram's `source` is the fenced block exactly as written, and its
  `nodes` the ids it defines, links or declares. `lines` holds every line in reading order.
  """
  def build_plan_sheet(content) when is_binary(content) do
    content
    |> MDEx.parse_document!(extension: @extension)
    |> Map.fetch!(:nodes)
    |> split(3)
    |> Enum.reduce(@empty, &place/2)
    |> finish()
  end

  # Anything above the first section except the heading the brief asks for.
  defp place({nil, body}, sheet) do
    case Enum.reject(body, &match?(%MDEx.Heading{level: 2}, &1)) do
      [] -> sheet
      preamble -> %{sheet | rest: [%{title: nil, body: markdown(preamble)} | sheet.rest]}
    end
  end

  defp place({%MDEx.Heading{} = heading, body}, sheet), do: place({text(heading), body}, sheet)

  defp place({"Approach", body}, %{approach: nil} = sheet) do
    {no_diagrams, approach} =
      Enum.split_with(body, &(match?(%MDEx.Paragraph{}, &1) and String.starts_with?(text(&1), "No diagrams:")))

    %{
      sheet
      | approach: markdown(approach),
        no_diagrams: if(no_diagrams != [], do: Enum.map_join(no_diagrams, " ", &text/1))
    }
  end

  defp place({title, body} = section, sheet) when is_map_key(@diagrams, title) do
    case Enum.find(body, &match?(%MDEx.CodeBlock{info: "mermaid"}, &1)) do
      %MDEx.CodeBlock{literal: source} -> %{sheet | diagrams: [diagram(title, source, body) | sheet.diagrams]}
      nil -> place({:rest, section}, sheet)
    end
  end

  defp place({"File-level changes", body}, %{files: nil} = sheet), do: %{sheet | files: files(body)}

  defp place({"Program design", body}, %{program_design?: false} = sheet),
    do: %{sheet | modules: modules(body), program_design?: true}

  defp place({"Verification", body}, %{verification: nil} = sheet), do: %{sheet | verification: markdown(body)}
  defp place({"Assumptions", body}, %{assumptions: nil} = sheet), do: %{sheet | assumptions: markdown(body)}
  defp place({:rest, {title, body}}, sheet), do: %{sheet | rest: [%{title: title, body: markdown(body)} | sheet.rest]}
  defp place(section, sheet), do: place({:rest, section}, sheet)

  # A plan from the old three-section prompt has Approach and File-level changes too,
  # but none of these, and the summary would wrongly say no application code changes.
  defp finish(
         %{
           approach: approach,
           files: files,
           modules: modules,
           diagrams: diagrams,
           no_diagrams: no_diagrams,
           program_design?: program_design?
         } = sheet
       )
       when is_binary(approach) and is_list(files) and is_list(modules) and
              (diagrams != [] or is_binary(no_diagrams) or program_design?) do
    paths = MapSet.new(files, & &1.path)

    %{
      Map.delete(sheet, :program_design?)
      | diagrams: Enum.reverse(diagrams),
        modules: Enum.map(modules, &%{&1 | listed?: MapSet.member?(paths, &1.path)}),
        rest: Enum.reverse(sheet.rest)
    }
    |> add_lines()
    |> number_lines()
  end

  defp finish(_not_a_sheet), do: nil

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

  defp split(nodes, level) do
    nodes
    |> Enum.reduce([{nil, []}], fn
      %MDEx.Heading{level: ^level} = heading, sections -> [{heading, []} | sections]
      node, [{heading, body} | sections] -> [{heading, [node | body]} | sections]
    end)
    |> Enum.map(fn {heading, body} -> {heading, Enum.reverse(body)} end)
    |> Enum.reverse()
  end

  defp diagram(title, source, body) do
    type_label = Map.get(@type_labels, source |> String.split(~r/\s+/, parts: 2, trim: true) |> List.first(), "Diagram")

    caption =
      body
      |> Enum.filter(&match?(%MDEx.Paragraph{}, &1))
      |> Enum.map_join(" ", &text/1)
      |> String.trim()
      |> String.trim_trailing(".")

    %{
      kind: Map.fetch!(@diagrams, title),
      source: source,
      type_label: type_label,
      caption: if(caption == "", do: type_label, else: caption)
    }
  end

  # The page links modules to files by path, so every bullet has to lead with one.
  defp files(body) do
    items = for %MDEx.List{nodes: items} <- body, item <- items, do: item

    if items != [] and Enum.all?(body, &match?(%MDEx.List{}, &1)) and Enum.all?(items, &leads_with_path?/1) do
      items |> Enum.with_index(1) |> Enum.map(&file/1)
    else
      :error
    end
  end

  defp leads_with_path?(%MDEx.ListItem{nodes: [%MDEx.Paragraph{nodes: [%MDEx.Code{} | _inline]} | _blocks]}), do: true
  # A task-list bullet, or any shape a plan might hold, is left to the markdown fallback.
  defp leads_with_path?(_item), do: false

  defp file(
         {%MDEx.ListItem{nodes: [%MDEx.Paragraph{nodes: [%MDEx.Code{literal: path} | inline]} = lead | blocks]}, number}
       ) do
    inline =
      case inline do
        [%MDEx.Text{literal: literal} = first | more] ->
          [%{first | literal: String.replace(literal, ~r/\A\s*:?\s*/, "")} | more]

        inline ->
          inline
      end

    %{number: number, path: path, description: markdown([%{lead | nodes: inline} | blocks])}
  end

  defp modules(body) do
    case split(body, 4) do
      [{nil, []} | modules] -> Enum.map(modules, &program_module/1)
      _preamble_or_prose -> :error
    end
  end

  defp program_module({%MDEx.Heading{nodes: heading}, body}) do
    {name, suffix} =
      case heading do
        [%MDEx.Code{literal: name} | suffix] -> {name, Enum.map_join(suffix, &text/1)}
        heading -> {heading |> Enum.map_join(&text/1) |> String.trim(), ""}
      end

    lead = Enum.find(body, &match?(%MDEx.Paragraph{nodes: [%MDEx.Code{} | _inline]}, &1))

    %{
      name: name,
      new?: String.trim(suffix) == "new",
      path: lead && hd(lead.nodes).literal,
      signatures: body |> List.delete(lead) |> markdown(),
      listed?: false
    }
  end

  defp markdown(nodes), do: %MDEx.Document{nodes: nodes} |> MDEx.to_markdown!(extension: @extension) |> String.trim()

  defp text(%{literal: literal}), do: literal
  defp text(%{nodes: nodes}), do: Enum.map_join(nodes, &text/1)
  defp text(_break), do: " "
end
