defmodule Rail.Issues.Actions.GetIssue do
  @moduledoc false

  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo

  @doc """
  Finds an issue by Rail's id or Linear's, with its project.
  """
  def get_issue(id) when is_binary(id) do
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
