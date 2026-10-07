defmodule Rail.Pipeline.Schemas.ImplementationPlan do
  @moduledoc """
  The plan the architect wrote for a task, once a human approved it.

  One per task: a second architect pass replaces what the first one said rather
  than leaving two plans for a reader to choose between. The plan lives in scratch
  while it is being written and argued over; a row here means it was approved.
  """
  use Rail.Schema

  alias Rail.Pipeline.Schemas.Task

  @heading ~r/\A## Implementation plan\s*(\n|\z)/

  # The `###` sections Rail lays a plan out by, in their order. The diagrams come as a pair or not
  # at all, Program design only when application code changes, and Assumptions only when there are some.
  @sections [
    "Approach",
    "Change diagram",
    "Call flow",
    "File-level changes",
    "Program design",
    "Verification",
    "Assumptions"
  ]
  @required ["Approach", "File-level changes", "Verification"]
  @diagrams ["Change diagram", "Call flow"]

  @extension [autolink: true, strikethrough: true, table: true, tasklist: true]

  @diagram_kinds %{"Change diagram" => :change, "Call flow" => :call_flow}

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
    program_design?: false,
    verification: nil,
    assumptions: nil,
    rest: []
  }

  @primary_key {:id, UXID, autogenerate: true, prefix: "pln"}
  schema "implementation_plans" do
    belongs_to :task, Task

    field :content, :string
    field :captured_at, :utc_datetime_usec

    timestamps()
  end

  @cast_fields [
    :task_id,
    :content,
    :captured_at
  ]

  @required_fields [
    :task_id,
    :content,
    :captured_at
  ]

  @doc """
  Builds a changeset for an implementation plan.
  """
  def changeset(implementation_plan, attrs) do
    implementation_plan
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:task_id)
    |> unique_constraint(:task_id)
  end

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
            title_errors(Enum.map(sections, &elem(&1, 0))) ++ Enum.flat_map(sections, &section_errors(&1, sections))

        # The sheet is the last word, so nothing is saved that would show unlaid-out.
        errors =
          if errors == [] and build_sheet(plan) == nil,
            do: [
              "does not lay out as a plan: each section must be its own `###` block, `No diagrams:` a paragraph of " <>
                "its own after a blank line, and File-level changes a list of bullets that each start with a path in backticks"
            ],
            else: errors

        Enum.map(errors, &{field, &1})
      end)
    end
  end

  @doc """
  Splits a plan into the sections the plan sheet lays out, or `nil` when it does not lay out. Prose comes
  back as markdown, and a diagram's `source` is its fenced block exactly as written.
  """
  def build_sheet(content) when is_binary(content) do
    content
    |> MDEx.parse_document!(extension: @extension)
    |> Map.fetch!(:nodes)
    |> split(3)
    |> Enum.reduce(@empty, &place/2)
    |> finish()
  end

  # Splits on the `###` headings outside fenced blocks, keeping each section's body as lines.
  defp sections(body) do
    {lead, sections, _fenced} =
      body
      |> String.split("\n")
      |> Enum.reduce({[], [], false}, fn line, {lead, sections, fenced} ->
        fenced = if String.starts_with?(line, "```"), do: not fenced, else: fenced

        case {fenced, Regex.run(~r/\A### (.+?)\s*\z/, line), sections} do
          {false, [_line, title], _sections} -> {lead, [{title, []} | sections], fenced}
          {_fenced, _not_a_heading, []} -> {[line | lead], [], fenced}
          {_fenced, _not_a_heading, [{title, lines} | rest]} -> {lead, [{title, [line | lines]} | rest], fenced}
        end
      end)

    {Enum.reverse(lead), sections |> Enum.reverse() |> Enum.map(fn {title, lines} -> {title, Enum.reverse(lines)} end)}
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
      order_errors(known) ++ diagram_errors(titles)
  end

  defp order_errors(known) do
    if Enum.uniq(known) == Enum.filter(@sections, &(&1 in known)),
      do: [],
      else: ["has its sections out of order; they go #{listed()}"]
  end

  defp diagram_errors(titles) do
    case Enum.filter(@diagrams, &(&1 in titles)) do
      [_one] ->
        ["has one diagram section without the other; include both `### Change diagram` and `### Call flow`, or neither"]

      _both_or_neither ->
        []
    end
  end

  # The sheet reads `No diagrams:` only as a paragraph's start, so a line run into the one above is not one.
  defp section_errors({"Approach", lines}, sections) do
    paragraph? = ["" | lines] |> Enum.zip(lines) |> Enum.any?(&no_diagrams_paragraph?/1)

    cond do
      Enum.any?(sections, &(elem(&1, 0) in @diagrams)) or paragraph? ->
        []

      Enum.any?(lines, &String.starts_with?(&1, "No diagrams:")) ->
        ["`No diagrams:` must start a paragraph of its own, after a blank line"]

      true ->
        ["leaves out both diagrams, so `### Approach` must end with a line starting `No diagrams:` that says why"]
    end
  end

  defp section_errors({title, lines}, _sections) when title in @diagrams do
    if Enum.any?(lines, &String.starts_with?(&1, "```mermaid")),
      do: [],
      else: ["needs a ```mermaid block under `### #{title}`"]
  end

  # The plan sheet lists this section file by file, so it is bullets and nothing else.
  defp section_errors({"File-level changes", lines}, _sections) do
    lines = lines |> outside_fences() |> Enum.reject(&(String.trim(&1) == ""))

    cond do
      lines == [] ->
        ["has nothing under `### File-level changes`; it is one bullet per file, starting with its path in backticks"]

      Enum.any?(lines, &Regex.match?(~r/\A\s+([-*+]|\d+\.)\s/, &1)) ->
        ["has sub-bullets under `### File-level changes`; it is one flat bullet per file"]

      Enum.any?(lines, &(not Regex.match?(~r/\A(\s|[-*+] `[^`]+`)/, &1))) ->
        ["has a line under `### File-level changes` that is not a bullet starting with a file path in backticks"]

      true ->
        []
    end
  end

  # The sheet reads each `####` as a module, so nothing comes before the first, and each names its file.
  defp section_errors({"Program design", lines}, _sections) do
    {lead, modules} = lines |> outside_fences() |> Enum.split_while(&(not String.starts_with?(&1, "####")))
    headings = Enum.filter(modules, &String.starts_with?(&1, "####"))

    cond do
      Enum.any?(lead, &(String.trim(&1) != "")) or modules == [] ->
        [
          "needs `### Program design` to start with a `#### `Module.Name`` heading; leave the section out when no signature changes"
        ]

      Enum.any?(headings, &(not Regex.match?(~r/\A#### (`[A-Z][\w.]*`|[A-Z][\w.]*)( new)?\s*\z/, &1))) ->
        ["has a heading under `### Program design` that is not `#### `Module.Name``, optionally followed by `new`"]

      Enum.count(modules, &Regex.match?(~r/\A`[^`]+`\s*\z/, &1)) < length(headings) ->
        ["needs each module under `### Program design` followed by its file path in backticks on a line of its own"]

      true ->
        []
    end
  end

  defp section_errors({_title, _lines}, _sections), do: []

  defp no_diagrams_paragraph?({before, line}), do: String.trim(before) == "" and String.starts_with?(line, "No diagrams:")

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

  defp listed, do: Enum.map_join(@sections, ", ", &"`### #{&1}`")

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

  defp place({title, body} = section, sheet) when is_map_key(@diagram_kinds, title) do
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
      kind: Map.fetch!(@diagram_kinds, title),
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
