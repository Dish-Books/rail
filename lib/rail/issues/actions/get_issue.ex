defmodule Rail.Issues.Actions.GetIssue do
  @moduledoc false

  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo

  def get_issue(id) do
    do_get_issue(id)
  end

  def get_issue!(id) do
    case do_get_issue(id) do
      {:ok, issue} -> issue
      {:error, :not_found} -> raise Ecto.NoResultsError, queryable: Issue
    end
  end

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
end
