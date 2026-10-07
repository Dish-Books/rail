defmodule Rail.Issues.Utils.UpsertGithubComment do
  @moduledoc """
  Writes one comment GitHub told us about onto its issue, and tells the issue's page.
  """

  import Ecto.Query

  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo
  alias Rail.Users.Schemas.User

  @doc """
  Upserts `comment` by its GitHub node id onto `issue` and broadcasts
  `{:issue_comments_changed, issue_id}` on `"issues"`. GitHub comments are flat, so none has a parent.
  """
  def upsert_github_comment(%Issue{id: issue_id}, %{"node_id" => external_id} = comment) do
    user = comment["user"] || %{}
    github_id = user["id"] && to_string(user["id"])

    attrs = %{
      issue_id: issue_id,
      external_id: external_id,
      body: comment["body"] || "",
      author_name: user["login"],
      author_avatar_url: user["avatar_url"],
      author_user_id: github_id && Repo.one(from u in User, where: u.github_id == ^github_id, select: u.id),
      inserted_at: timestamp(comment["created_at"]),
      updated_at: timestamp(comment["updated_at"] || comment["created_at"])
    }

    with {:ok, saved} <-
           (Repo.get_by(Comment, external_id: external_id) || %Comment{})
           |> Comment.changeset(attrs)
           |> Repo.insert_or_update() do
      Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_comments_changed, issue_id})
      {:ok, saved}
    end
  end

  defp timestamp(value) do
    {:ok, %DateTime{microsecond: {usec, _precision}} = at, _offset} = DateTime.from_iso8601(value)
    %{at | microsecond: {usec, 6}}
  end
end
