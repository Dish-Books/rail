defmodule Rail.Issues.Utils.UpsertLinearComment do
  @moduledoc """
  Writes one comment Linear told us about, from a webhook or the reply to a
  comment Rail posted, and tells the issue's page.
  """

  import Ecto.Query
  import Rail.Issues.Utils.FormatLinearComment

  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo
  alias Rail.Users.Schemas.User

  @refs [:issue_external_id, :parent_external_id, :author_linear_id]

  @doc """
  Upserts `node` by its Linear id onto the issue and parent it names, and
  broadcasts `{:issue_comments_changed, issue_id}` on `"issues"`.

  Returns `{:error, :issue_not_found}` or `{:error, :parent_not_found}` when
  Rail has not synced what the comment belongs to yet.
  """
  def upsert_linear_comment(%{} = node) do
    {refs, attrs} = node |> format_linear_comment() |> Map.split(@refs)

    with {:ok, issue_id} <- issue_id(refs.issue_external_id),
         {:ok, parent_id} <- parent_id(refs.parent_external_id),
         {:ok, comment} <-
           (Repo.get_by(Comment, external_id: attrs.external_id) || %Comment{})
           |> Comment.changeset(
             Map.merge(attrs, %{issue_id: issue_id, parent_id: parent_id, author_user_id: author_user_id(refs)})
           )
           |> Repo.insert_or_update() do
      Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_comments_changed, issue_id})
      {:ok, comment}
    end
  end

  defp issue_id(external_id) when is_binary(external_id) do
    case Repo.one(from i in Issue, where: i.external_id == ^external_id, select: i.id) do
      issue_id when is_binary(issue_id) -> {:ok, issue_id}
      nil -> {:error, :issue_not_found}
    end
  end

  defp issue_id(_missing), do: {:error, :issue_not_found}

  defp parent_id(nil), do: {:ok, nil}

  defp parent_id(external_id) do
    case Repo.one(from c in Comment, where: c.external_id == ^external_id, select: c.id) do
      parent_id when is_binary(parent_id) -> {:ok, parent_id}
      nil -> {:error, :parent_not_found}
    end
  end

  defp author_user_id(%{author_linear_id: nil}), do: nil

  defp author_user_id(%{author_linear_id: linear_id}) do
    Repo.one(from u in User, where: u.linear_user_id == ^linear_id, select: u.id)
  end
end
