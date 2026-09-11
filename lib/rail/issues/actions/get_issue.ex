defmodule Rail.Issues.Actions.GetIssue do
  @moduledoc false

  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo
  alias Rail.Scope

  def get_issue(_scope, id) do
    do_get_issue(id)
  end

  def get_issue!(scope, id) do
    if authorized?(scope) do
      do_get_issue!(id)
    else
      raise "Unauthorized"
    end
  end

  defp authorized?(%Scope{system: true}), do: true
  defp authorized?(%Scope{user: %{}}), do: true
  defp authorized?(_scope), do: false

  defp do_get_issue(id) when is_binary(id) do
    query =
      from i in Issue,
        where: i.id == ^id or i.external_id == ^id,
        preload: [:project]

    case Repo.one(query) do
      %Issue{} = issue -> {:ok, issue}
      nil -> {:error, :not_found}
    end
  end

  defp do_get_issue!(id) when is_binary(id) do
    case do_get_issue(id) do
      {:ok, issue} -> issue
      {:error, :not_found} -> raise Ecto.NoResultsError, queryable: Issue
    end
  end
end
