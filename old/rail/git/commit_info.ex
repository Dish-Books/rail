defmodule Rail.Git.CommitInfo do
  @moduledoc """
  Information about a git commit.
  """

  @enforce_keys [:sha, :short_sha, :message, :author, :date]
  defstruct [:sha, :short_sha, :message, :author, :date]

  @type t :: %__MODULE__{
          sha: String.t(),
          short_sha: String.t(),
          message: String.t(),
          author: String.t(),
          date: String.t()
        }
end
