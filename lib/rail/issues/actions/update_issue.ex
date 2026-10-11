defmodule Rail.Issues.Actions.UpdateIssue do
  @moduledoc """
  Writes an issue locally. Its tracker hears about it afterwards.

  Nothing here talks to the tracker: `Issue.changeset/2` enqueues
  `Rail.Issues.Workers.SyncIssue` for whatever this changed, so the push happens
  in the same transaction's wake and carries only the fields that actually moved.
  A field this update did not touch is never sent, so an edit made in the tracker
  meanwhile survives.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo

  @doc """
  Updates `issue` with the `attrs` map.
  """
  def update_issue(%Issue{} = issue, %{} = attrs) do
    issue
    |> Issue.changeset(attrs)
    |> Repo.update()
  end
end
