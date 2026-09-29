defmodule RailWeb.Utils.BuildPlanSheet do
  @moduledoc """
  Splits an implementation plan into the sections the Review sheet lays out.

  The sheet keys off the `###` titles the Architect prompt gives word for word, so a
  plan written any other way comes back `nil` and renders as plain markdown.
  """

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

  @empty %{
    approach: nil,
    no_diagrams: nil,
    diagrams: [],
    files: nil,
    modules: [],
    verification: nil,
    assumptions: nil,
    rest: []
  }

  @doc """
  Returns the plan's sections as a map, or `nil` when it has no `### Approach` or no
  `### File-level changes` naming one file per bullet.

  Prose comes back as markdown, so `render_markdown/2` stays the one place plan text
  becomes HTML. A diagram's `source` is the fenced block exactly as written.
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
  defp place({"Program design", body}, %{modules: []} = sheet), do: %{sheet | modules: modules(body)}
  defp place({"Verification", body}, %{verification: nil} = sheet), do: %{sheet | verification: markdown(body)}
  defp place({"Assumptions", body}, %{assumptions: nil} = sheet), do: %{sheet | assumptions: markdown(body)}
  defp place({:rest, {title, body}}, sheet), do: %{sheet | rest: [%{title: title, body: markdown(body)} | sheet.rest]}
  defp place(section, sheet), do: place({:rest, section}, sheet)

  defp finish(%{approach: approach, files: files, modules: modules} = sheet)
       when is_binary(approach) and is_list(files) and is_list(modules) do
    paths = MapSet.new(files, & &1.path)

    %{
      sheet
      | diagrams: Enum.reverse(sheet.diagrams),
        modules: Enum.map(modules, &%{&1 | listed?: MapSet.member?(paths, &1.path)}),
        rest: Enum.reverse(sheet.rest)
    }
  end

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
