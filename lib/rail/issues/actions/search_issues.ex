defmodule Rail.Issues.Actions.SearchIssues do
  @moduledoc """
  Finds a project's tickets by meaning, finished and archived ones included, for an agent checking what is already tracked.
  """

  import Ecto.Query
  import Pgvector.Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Learnings
  alias Rail.Repo

  @limit 10

  @doc """
  Returns `{:ok, issues}`, the ten embedded tickets of `project_id` nearest `query`, or the error when `query` cannot be embedded.
  """
  def search_issues(project_id, query) when is_binary(project_id) and is_binary(query) do
    with {:ok, values} <- Learnings.embed_query(query) do
      vector = Pgvector.new(values)

      {:ok,
       Repo.all(
         from i in Issue,
           where: i.project_id == ^project_id and not is_nil(i.embedding),
           order_by: [asc: cosine_distance(i.embedding, ^vector), asc: i.id],
           limit: @limit
       )}
    end
  end
end
