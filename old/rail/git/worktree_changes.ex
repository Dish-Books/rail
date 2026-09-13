defmodule Rail.Git.WorktreeChanges do
  @moduledoc """
  Aggregate changes detected in a task worktree.
  """

  alias Rail.Git.ChangedFile

  defstruct filter: "uncommitted", files: []

  @type t :: %__MODULE__{
          filter: String.t(),
          files: [ChangedFile.t()]
        }

  @doc """
  Returns the sum of all additions across files.
  """
  def additions(%__MODULE__{files: files}) do
    Enum.reduce(files, 0, fn file, acc -> acc + file.additions end)
  end

  @doc """
  Returns the sum of all deletions across files.
  """
  def deletions(%__MODULE__{files: files}) do
    Enum.reduce(files, 0, fn file, acc -> acc + file.deletions end)
  end

  @doc """
  Returns true if there are no changed files.
  """
  def empty?(%__MODULE__{files: files}) do
    files == []
  end
end
