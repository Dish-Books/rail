defmodule Rail.Initiatives.Actions.GetInitiative do
  @moduledoc "One initiative a scope can open, with its progress, tickets and update briefs."

  import Ecto.Query
  import Rail.Initiatives.Utils.CountTickets

  alias Rail.Initiatives.Schemas.Initiative
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Reads the initiative with its project, its tickets by number and its briefs newest first. Options: `:preload`, what
  each ticket needs. One in a project the scope cannot open is `{:error, :not_found}`.
  """
  def get_initiative(%Scope{} = scope, id, opts \\ []) when is_binary(id) do
    case from(i in Initiative, where: i.id == ^id) |> count_tickets(scope) |> Repo.one() do
      %Initiative{} = initiative ->
        {:ok, Repo.preload(initiative, [:project, comments: :author_user, issues: Keyword.get(opts, :preload, [])])}

      nil ->
        {:error, :not_found}
    end
  end
end
