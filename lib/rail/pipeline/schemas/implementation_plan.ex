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

        Enum.map(errors, &{field, &1})
      end)
    end
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

  defp section_errors({"Approach", lines}, sections) do
    with false <- Enum.any?(sections, &(elem(&1, 0) in @diagrams)),
         false <- Enum.any?(lines, &String.starts_with?(&1, "No diagrams:")) do
      ["leaves out both diagrams, so `### Approach` must end with a line starting `No diagrams:` that says why"]
    else
      true -> []
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
end
