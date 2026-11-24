defmodule Rail.Initiatives.Actions.CreateUpdateBrief do
  @moduledoc "Posts where an initiative stands as a Markdown comment, listing what is Done since the last one."

  import Ecto.Query

  alias Rail.Initiatives.Schemas.Initiative
  alias Rail.Initiatives.Schemas.InitiativeComment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  @doc """
  Builds the brief from the initiative's tickets as they are now and posts it as a comment by the scope's user, then
  broadcasts on `"initiatives"`. A second brief at once, from a double click or a second tab, lists nothing as Done since.
  """
  def create_update_brief(%Scope{user: user} = scope, %Initiative{id: id, project_id: project_id}) do
    if Scope.can_access_project?(scope, project_id) do
      fn ->
        initiative =
          case Repo.one(from(i in Initiative, where: i.id == ^id and i.project_id == ^project_id, lock: "FOR UPDATE")) do
            %Initiative{} = locked -> locked
            nil -> Repo.rollback(:not_found)
          end

        # Taken before the tickets are read, so one finishing meanwhile falls in the next brief rather than in neither.
        now = DateTime.utc_now()
        last_at = Repo.one(from(c in InitiativeComment, where: c.initiative_id == ^id, select: max(c.inserted_at)))

        tickets =
          Repo.all(
            from(t in Issue,
              where: t.initiative_id == ^id and t.project_id == ^project_id,
              order_by: [asc: t.number],
              preload: :owner_user
            )
          )

        %InitiativeComment{initiative_id: id, author_user_id: user && user.id}
        |> InitiativeComment.changeset(%{body: brief_body(initiative, tickets, last_at, DateTime.to_date(now))})
        |> Ecto.Changeset.put_change(:inserted_at, now)
        |> Repo.insert!()
      end
      |> Repo.transaction()
      |> tap(fn
        {:ok, _comment} -> Phoenix.PubSub.broadcast(Rail.PubSub, "initiatives", {:initiatives_changed, project_id})
        {:error, _reason} -> :ok
      end)
    else
      {:error, :not_found}
    end
  end

  defp brief_body(initiative, tickets, last_at, today) do
    counted = Enum.reject(tickets, &(&1.state == :canceled))
    done = Enum.filter(counted, &(&1.state == :done))
    initiative = %{initiative | done_count: length(done), ticket_count: length(counted)}

    Enum.join(
      [
        "**#{initiative.name}**: update for #{Calendar.strftime(today, "%b %-d, %Y")}",
        "**#{Initiative.calculate_percent(initiative)}% done**: #{length(done)} of #{length(counted)} tickets." <>
          expected(initiative, today),
        section("Done since the last update", Enum.filter(done, &done_since?(&1, last_at)), true),
        section("In progress", Enum.filter(counted, &Issue.started_state?(&1.state)), true),
        section("Not started", Enum.filter(counted, &(&1.state == :todo)), false),
        RailWeb.Endpoint.url() <> "/initiatives/" <> initiative.id
      ],
      "\n\n"
    )
  end

  defp done_since?(%Issue{}, nil), do: true
  defp done_since?(%Issue{completed_at: %DateTime{} = at}, last_at), do: DateTime.after?(at, last_at)
  defp done_since?(%Issue{completed_at: nil}, _last_at), do: false

  defp expected(%Initiative{expected_on: nil}, _today), do: ""

  defp expected(%Initiative{expected_on: on} = initiative, today),
    do: " Expected #{Calendar.strftime(on, "%b %-d, %Y")}, #{Initiative.calculate_due_text(initiative, today)}."

  defp section(title, tickets, with_owner?) do
    lines = for ticket <- tickets, do: "- #{ticket.identifier} #{ticket.title}" <> owner(ticket, with_owner?)
    Enum.join(["**#{title} (#{length(tickets)})**" | lines], "\n")
  end

  defp owner(%Issue{owner_user: %User{} = user}, true), do: " · " <> (user.name || user.login)
  defp owner(_issue, _with_owner), do: ""
end
