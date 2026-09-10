defmodule Rail.Issues.Actions.UpdateIssue do
  @moduledoc false

  import Rail.Issues.Utils.TokenResolver

  alias Rail.Issues.Clients.Linear
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  def update_issue(scope, %Issue{} = issue, attrs) do
    attrs_map = normalize_attrs(attrs)
    project = Repo.get(Project, issue.project_id)

    with {:ok, token, _identity} <- resolve_token(scope, project) do
      linear_attrs = build_linear_attrs(attrs_map, project)

      case maybe_update_linear(token, issue.external_id, linear_attrs) do
        {:ok, _result} ->
          issue
          |> Issue.changeset(attrs_map, issue.project_id)
          |> Repo.update()

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_linear_attrs(attrs, project) do
    %{}
    |> maybe_put(:title, get_field_val(attrs, [:title, "title"]))
    |> maybe_put(:description, get_field_val(attrs, [:description, "description"]))
    |> maybe_put_state(attrs, project)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_state(map, attrs, project) do
    state_val = get_field_val(attrs, [:state, "state"])
    state_id_val = get_field_val(attrs, [:state_id, "state_id", :stateId, "stateId"])

    cond do
      state_id_val != nil ->
        Map.put(map, :state_id, state_id_val)

      state_val != nil and project != nil ->
        state_key = to_string(state_val)

        case project.linear_state_ids[state_key] do
          state_id when is_binary(state_id) ->
            Map.put(map, :state_id, state_id)

          nil ->
            map
        end

      true ->
        map
    end
  end

  defp maybe_update_linear(_token, _external_id, linear_attrs) when map_size(linear_attrs) == 0 do
    {:ok, nil}
  end

  defp maybe_update_linear(token, external_id, linear_attrs) do
    Linear.update_issue(token, external_id, linear_attrs)
  end

  defp get_field_val(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp normalize_attrs(attrs) when is_list(attrs), do: Map.new(attrs)
  defp normalize_attrs(attrs) when is_map(attrs), do: attrs
end
