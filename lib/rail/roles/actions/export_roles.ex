defmodule Rail.Roles.Actions.ExportRoles do
  @moduledoc false

  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  def export_roles(scope, project_id) when is_binary(project_id) do
    if Scope.admin?(scope) or match?(%Scope{user: %{}}, scope) do
      roles = Rail.Roles.list_roles(scope, project_id)
      exported = Enum.map(roles, &serialize_role/1)
      {:ok, exported}
    else
      {:error, :not_authorized}
    end
  end

  def export_roles(_scope, _project_id), do: {:error, :not_authorized}

  defp serialize_role(%Role{} = role) do
    %{
      "stage" => if(role.stage, do: to_string(role.stage)),
      "name" => role.name,
      "description" => role.description,
      "icon_name" => role.icon_name,
      "cli_backend" => to_string(role.cli_backend),
      "model" => role.model,
      "reasoning_effort" => if(role.reasoning_effort, do: to_string(role.reasoning_effort)),
      "system_prompt" => role.system_prompt,
      "max_concurrent" => role.max_concurrent,
      "position" => role.position
    }
  end
end
