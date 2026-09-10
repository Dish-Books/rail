defmodule Rail.Issues.Actions.CaptureIssue do
  @moduledoc false

  import Rail.Issues.Utils.TokenResolver

  alias Rail.Domain.Formatters
  alias Rail.Issues.Clients.Linear
  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo

  def capture_issue(scope, project, ask, opts \\ []) do
    with {:ok, token, _identity} <- resolve_token(scope, project) do
      title = Formatters.summarize_ask(ask)
      triage_state_id = project.linear_state_ids["triage"] || project.linear_state_ids[:triage]
      priority = resolve_priority(Keyword.get(opts, :priority, :medium))

      issue_attrs = %{
        team_id: project.linear_team_id,
        title: title,
        description: ask,
        state_id: triage_state_id
      }

      case Linear.create_issue(token, issue_attrs) do
        {:ok, linear_issue} ->
          local_attrs = %{
            external_id: linear_issue.id,
            identifier: linear_issue.identifier,
            title: linear_issue.title,
            description: linear_issue.description,
            priority: priority,
            state: :triage,
            state_name: (linear_issue.state && linear_issue.state.name) || "Triage",
            branch_name: linear_issue.branch_name,
            url: linear_issue.url,
            linear_created_at: parse_datetime(linear_issue.created_at),
            linear_updated_at: parse_datetime(linear_issue.updated_at)
          }

          %Issue{}
          |> Issue.changeset(local_attrs, project.id)
          |> Repo.insert()

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp resolve_priority(nil), do: :medium

  defp resolve_priority(val) do
    case Issue.cast_priority(val) do
      {:ok, priority} -> priority
      :error -> :medium
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
