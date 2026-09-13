defmodule Rail.Issues.Actions.UpdateIssue do
  @moduledoc """
  Writes an issue locally. Linear hears about it afterwards.

  Nothing here talks to Linear: `Issue.changeset/2` enqueues
  `Rail.Issues.Workers.SyncIssue` for whatever this changed, so the push happens
  in the same transaction's wake and carries only the fields that actually moved.
  A field this update did not touch is never sent, so an edit made in Linear
  meanwhile survives.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo

  @doc """
  Updates `issue` with `attrs`, given as a map or a keyword list.
  """
  def update_issue(%Issue{} = issue, attrs) do
    issue
    |> Issue.changeset(Map.new(attrs))
    |> Repo.update()
  end
end
