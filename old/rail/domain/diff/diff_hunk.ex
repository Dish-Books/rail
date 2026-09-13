defmodule Rail.Domain.Diff.DiffHunk do
  @moduledoc """
  Represents one hunk in a unified diff (`@@ -a,b +c,d @@ [heading]`).

  Attributes:
    - `header`: The raw `@@ ... @@` header line.
    - `heading`: Optional function or section context after `@@`.
    - `section_heading`: Alias for `heading`.
    - `old_start`: 1-based start line on old side.
    - `old_count`: Number of lines on old side (default 1).
    - `new_start`: 1-based start line on new side.
    - `new_count`: Number of lines on new side (default 1).
    - `lines`: List of `DiffLine` structs.
  """

  alias Rail.Domain.Diff.DiffLine

  @enforce_keys [:header, :old_start, :new_start]
  defstruct [
    :header,
    :old_start,
    :new_start,
    heading: nil,
    section_heading: nil,
    old_count: 1,
    new_count: 1,
    lines: []
  ]

  @type t :: %__MODULE__{
          header: String.t(),
          heading: String.t() | nil,
          section_heading: String.t() | nil,
          old_start: non_neg_integer(),
          old_count: non_neg_integer(),
          new_start: non_neg_integer(),
          new_count: non_neg_integer(),
          lines: list(DiffLine.t())
        }

  @doc """
  Constructs a new `DiffHunk` struct.
  """
  def new(attrs) when is_list(attrs) do
    new(Map.new(attrs))
  end

  def new(%{header: header, old_start: old_start, new_start: new_start} = attrs) do
    heading = Map.get(attrs, :heading) || Map.get(attrs, :section_heading)

    %__MODULE__{
      header: header,
      old_start: old_start,
      old_count: Map.get(attrs, :old_count, 1),
      new_start: new_start,
      new_count: Map.get(attrs, :new_count, 1),
      heading: heading,
      section_heading: heading,
      lines: Map.get(attrs, :lines, [])
    }
  end
end
