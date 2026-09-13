defmodule Rail.Issues.Actions.GetIssue do
  @moduledoc false

  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo

  @doc """
  Finds an issue by Rail's id, Linear's id or its identifier, such as `DIS-123`.

  Options: `:preload`, which defaults to the project.
  """
  def get_issue(id, opts \\ []) when is_binary(id) and is_list(opts) do
    query =
      from i in Issue,
        where: i.id == ^id or i.external_id == ^id or i.identifier == ^id,
        preload: ^Keyword.get(opts, :preload, [:project])

    case Repo.one(query) do
      %Issue{} = issue -> {:ok, issue}
      nil -> {:error, :not_found}
    end
  end
end
