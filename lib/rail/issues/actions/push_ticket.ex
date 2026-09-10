defmodule Rail.Issues.Actions.PushTicket do
  @moduledoc false

  import Rail.Issues.Utils.TokenResolver

  alias Rail.Domain.TicketBody
  alias Rail.Issues.Clients.Linear
  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo

  def push_ticket(scope, project, identifier, ticket_content, owner_user \\ nil) do
    user_target = owner_user || scope

    with {:ok, token, _identity} <- resolve_token(user_target, project) do
      case Repo.get_by(Issue, project_id: project.id, identifier: identifier) do
        %Issue{} = issue ->
          ticket = TicketBody.parse(ticket_content)

          linear_attrs = %{
            title: ticket.title,
            description: ticket.description
          }

          case Linear.update_issue(token, issue.external_id, linear_attrs) do
            {:ok, updated_linear_issue} ->
              local_attrs = %{
                title: ticket.title,
                description: ticket.description,
                linear_updated_at: parse_datetime(updated_linear_issue.updated_at)
              }

              issue
              |> Issue.changeset(local_attrs, project.id)
              |> Repo.update()

            {:error, reason} ->
              {:error, reason}
          end

        nil ->
          {:error, :not_found}
      end
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _other -> nil
    end
  end
end
