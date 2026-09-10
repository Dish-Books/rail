defmodule Rail.Domain.Diff.DiffLine do
  @moduledoc """
  Represents a single line inside a diff hunk.

  Attributes:
    - `kind`: `:context`, `:added`, or `:deleted`.
    - `old_line_number`: 1-based line number on the old file side, or nil for additions.
    - `new_line_number`: 1-based line number on the new file side, or nil for deletions.
    - `text`: Content of the line without the leading diff marker (`+`, `-`, or space).
    - `line_index_in_file`: Monotonically increasing index across all hunks of a file,
      or nil for expanded gap lines (used as key for syntax highlighting spans).
  """

  @enforce_keys [:kind, :text]
  defstruct [
    :kind,
    :old_line_number,
    :new_line_number,
    :text,
    :line_index_in_file
  ]

  @type kind :: :context | :added | :deleted

  @type t :: %__MODULE__{
          kind: kind(),
          old_line_number: pos_integer() | nil,
          new_line_number: pos_integer() | nil,
          text: String.t(),
          line_index_in_file: non_neg_integer() | nil
        }

  @valid_kinds [:context, :added, :deleted]

  @doc """
  Constructs a new `DiffLine` struct with defaults.
  """
  def new(attrs) when is_list(attrs) do
    new(Map.new(attrs))
  end

  def new(%{kind: kind} = attrs) when kind in @valid_kinds do
    %__MODULE__{
      kind: kind,
      old_line_number: Map.get(attrs, :old_line_number),
      new_line_number: Map.get(attrs, :new_line_number),
      text: Map.get(attrs, :text, ""),
      line_index_in_file: Map.get(attrs, :line_index_in_file)
    }
  end
end
