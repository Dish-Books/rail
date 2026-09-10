defmodule Rail.Git.BranchFingerprint do
  @moduledoc """
  A snapshot of a worktree's HEAD commit SHA and working-copy dirty digest.
  """

  @enforce_keys [:head_sha, :dirty_digest]
  defstruct [:head_sha, :dirty_digest]

  @type t :: %__MODULE__{
          head_sha: String.t(),
          dirty_digest: String.t()
        }

  @doc """
  Returns the short (7-char) representation of the HEAD SHA.
  """
  def short_head_sha(%__MODULE__{head_sha: head_sha}) when is_binary(head_sha) do
    if String.length(head_sha) >= 7 do
      String.slice(head_sha, 0, 7)
    else
      head_sha
    end
  end
end
