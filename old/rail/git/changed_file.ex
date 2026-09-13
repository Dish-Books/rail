defmodule Rail.Git.ChangedFile do
  @moduledoc """
  A single file modified or added in a worktree as reported by git diff.
  """

  @enforce_keys [:file_path]
  defstruct [:file_path, additions: 0, deletions: 0, content_hash: nil, status: "modified"]

  @type t :: %__MODULE__{
          file_path: String.t(),
          additions: non_neg_integer(),
          deletions: non_neg_integer(),
          content_hash: String.t() | nil,
          status: String.t()
        }
end
