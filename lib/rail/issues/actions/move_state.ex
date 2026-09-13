defmodule Rail.Issues.Actions.MoveState do
  @moduledoc false

  import Rail.Issues.Utils.TokenResolver

  alias Rail.Issues.Clients.Linear
  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo

  def move_state(project, %Issue{} = issue, state_type, owner_user \\ nil) do
    with {:ok, token, _identity} <- resolve_token(owner_user, project),
         {:ok, state_id, state_name} <- resolve_state(token, project, state_type) do
      case Linear.update_issue(token, issue.external_id, %{state_id: state_id}) do
        {:ok, linear_issue} ->
          local_attrs = %{
            project_id: project.id,
            state: state_type,
            state_name: state_name,
            linear_updated_at: parse_datetime(linear_issue.updated_at)
          }

          issue
          |> Issue.changeset(local_attrs)
          |> Repo.update()

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp resolve_state(token, project, state_type) do
    state_key = to_string(state_type)

    case project.linear_state_ids[state_key] do
      state_id when is_binary(state_id) ->
        label = Issue.state_label(state_type) || Phoenix.Naming.humanize(state_key)
        {:ok, state_id, label}

      nil ->
        find_state_from_linear(token, project.linear_team_id, state_type)
    end
  end

  defp find_state_from_linear(token, team_id, state_type) do
    type_str = linear_type_for_state(state_type)

    case Linear.workflow_states(token, team_id) do
      {:ok, states} ->
        case Enum.find(states, fn s -> s.type == type_str or s.name == Issue.state_label(state_type) end) do
          %{id: id, name: name} ->
            {:ok, id, name}

          nil ->
            {:error, {:state_not_found, state_type}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp linear_type_for_state(:triage), do: "triage"
  defp linear_type_for_state(:backlog), do: "backlog"
  defp linear_type_for_state(:in_progress), do: "started"
  defp linear_type_for_state(:done), do: "completed"
  defp linear_type_for_state(:canceled), do: "canceled"
  defp linear_type_for_state(_other), do: "unstarted"

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _other -> nil
    end
  end
end
