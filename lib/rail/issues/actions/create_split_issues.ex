defmodule Rail.Issues.Actions.CreateSplitIssues do
  @moduledoc false

  import Rail.Issues.Utils.TokenResolver

  alias Rail.Domain.TicketBody
  alias Rail.Issues.Clients.Linear
  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo

  def create_split_issues(scope, project, split_tickets, owner_user \\ nil) do
    user_target = owner_user || scope

    with {:ok, token, _identity} <- resolve_token(user_target, project) do
      tickets = normalize_tickets(split_tickets)
      triage_state_id = project.linear_state_ids["triage"] || project.linear_state_ids[:triage]

      Repo.transaction(fn ->
        Enum.map(tickets, fn ticket ->
          create_single_split_issue(token, project, ticket, triage_state_id)
        end)
      end)
    end
  end

  defp create_single_split_issue(token, project, ticket, triage_state_id) do
    linear_attrs = %{
      team_id: project.linear_team_id,
      title: ticket.title,
      description: ticket.description,
      state_id: triage_state_id
    }

    case Linear.create_issue(token, linear_attrs) do
      {:ok, linear_issue} ->
        insert_split_issue(project.id, linear_issue)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp insert_split_issue(project_id, linear_issue) do
    local_attrs = %{
      external_id: linear_issue.id,
      identifier: linear_issue.identifier,
      title: linear_issue.title,
      description: linear_issue.description,
      state: :triage,
      state_name: (linear_issue.state && linear_issue.state.name) || "Triage",
      branch_name: linear_issue.branch_name,
      url: linear_issue.url,
      linear_created_at: parse_datetime(linear_issue.created_at),
      linear_updated_at: parse_datetime(linear_issue.updated_at)
    }

    %Issue{}
    |> Issue.changeset(local_attrs, project_id)
    |> Repo.insert!()
  end

  defp normalize_tickets(tickets) when is_list(tickets) do
    Enum.map(tickets, fn
      %TicketBody{} = t ->
        t

      %{title: title} = m ->
        %TicketBody{title: title, description: Map.get(m, :description, "")}

      %{"title" => title} = m ->
        %TicketBody{title: title, description: Map.get(m, "description", "")}

      str when is_binary(str) ->
        TicketBody.parse(str)
    end)
  end

  defp normalize_tickets(tickets) when is_map(tickets) do
    TicketBody.parse_splits(tickets)
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _other -> nil
    end
  end
end
