defmodule Rail.Initiatives.Utils.CountTickets do
  @moduledoc "The percent-done figures, read with the initiatives rather than stored, and the scope's access rule."

  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Scope

  @doc """
  Narrows a query of initiatives to the scope's projects and sets each one's `done_count` and `ticket_count`, in one
  grouped join that leaves Canceled tickets out. The join is the query's second binding.
  """
  def count_tickets(query, %Scope{} = scope) do
    query =
      case Scope.project_ids(scope) do
        ids when is_list(ids) -> where(query, [i], i.project_id in ^ids)
        nil -> query
      end

    from(i in query,
      left_join: t in Issue,
      on: t.initiative_id == i.id and t.project_id == i.project_id and t.state != ^:canceled,
      group_by: i.id,
      select_merge: %{
        done_count: filter(count(t.id), t.state == ^:done),
        ticket_count: count(t.id)
      }
    )
  end
end
