defmodule Rail.Domain.Diff.FileDiff do
  @moduledoc """
  Represents changes to a single file in a unified diff.

  Attributes:
    - `old_path`: Path before change; nil for additions.
    - `new_path`: Path after change; nil for deletions.
    - `status`: Change status: `:added`, `:deleted`, `:modified`, `:renamed`, or `:unchanged`.
    - `digest`: SHA256 digest of path headers and hunks (used for viewed marks).
    - `is_binary`: True if binary file.
    - `hunks`: List of `DiffHunk` structs.
    - `additions`: Number of added lines.
    - `deletions`: Number of deleted lines.
    - `raw_block`: Raw diff text for this file block.
    - `display_path`: Derived display string (`old_path → new_path` if renamed, else `path`).
    - `path`: Derived primary path (`new_path || old_path || ""`).
    - `is_renamed`: True if both `old_path` and `new_path` exist and are different.
  """

  alias Rail.Domain.Diff.DiffHunk

  @enforce_keys [:status, :digest]
  defstruct [
    :old_path,
    :new_path,
    :status,
    :digest,
    :raw_block,
    :display_path,
    :path,
    is_binary: false,
    hunks: [],
    additions: 0,
    deletions: 0,
    is_renamed: false
  ]

  @type status :: :added | :deleted | :modified | :renamed | :unchanged

  @type t :: %__MODULE__{
          old_path: String.t() | nil,
          new_path: String.t() | nil,
          status: status(),
          digest: String.t(),
          is_binary: boolean(),
          hunks: list(DiffHunk.t()),
          additions: non_neg_integer(),
          deletions: non_neg_integer(),
          raw_block: String.t() | nil,
          display_path: String.t(),
          path: String.t(),
          is_renamed: boolean()
        }

  @doc """
  Constructs a new `FileDiff` struct, normalizing status and computing paths.
  """
  def new(attrs) when is_list(attrs) do
    new(Map.new(attrs))
  end

  def new(%{digest: digest} = attrs) do
    old_path = Map.get(attrs, :old_path)
    new_path = Map.get(attrs, :new_path)
    path = Map.get(attrs, :path) || new_path || old_path || ""
    is_renamed = old_path != nil and new_path != nil and old_path != new_path

    display_path =
      Map.get(attrs, :display_path) ||
        if is_renamed do
          "#{old_path} → #{new_path}"
        else
          path
        end

    status = normalize_status(Map.get(attrs, :status, :modified))

    %__MODULE__{
      old_path: old_path,
      new_path: new_path,
      status: status,
      digest: digest,
      is_binary: Map.get(attrs, :is_binary, false),
      hunks: Map.get(attrs, :hunks, []),
      additions: Map.get(attrs, :additions, 0),
      deletions: Map.get(attrs, :deletions, 0),
      raw_block: Map.get(attrs, :raw_block),
      display_path: display_path,
      path: path,
      is_renamed: is_renamed
    }
  end

  @doc """
  Returns true if the file was renamed.
  """
  def renamed?(%__MODULE__{is_renamed: is_renamed}), do: is_renamed

  defp normalize_status(status) when is_atom(status), do: status

  defp normalize_status(status) when is_binary(status) do
    case status do
      "added" -> :added
      "deleted" -> :deleted
      "renamed" -> :renamed
      "unchanged" -> :unchanged
      _other -> :modified
    end
  end
end
