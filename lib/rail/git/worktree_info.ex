defmodule Rail.Git.WorktreeInfo do
  @moduledoc """
  Information about a git worktree.
  """

  @enforce_keys [:path, :branch, :commit_sha]
  defstruct [:path, :branch, :commit_sha, is_bare: false]

  @type t :: %__MODULE__{
          path: String.t(),
          branch: String.t(),
          commit_sha: String.t(),
          is_bare: boolean()
        }
end
