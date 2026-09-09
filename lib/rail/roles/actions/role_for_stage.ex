defmodule Rail.Roles.Actions.RoleForStage do
  @moduledoc false

  alias Rail.Domain.Enums.TaskStage
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  def role_for_stage(project_id, stage) when is_binary(project_id) do
    role_for_stage(Scope.for_system(), project_id, stage)
  end

  def role_for_stage(%Scope{system: true}, project_id, stage) when is_binary(project_id) do
    find_role_for_stage(project_id, stage)
  end

  def role_for_stage(%Scope{user: %{}}, project_id, stage) when is_binary(project_id) do
    find_role_for_stage(project_id, stage)
  end

  def role_for_stage(_scope, _project_id, _stage), do: {:error, :not_authorized}

  def role_for_stage!(project_id, stage) when is_binary(project_id) do
    role_for_stage!(Scope.for_system(), project_id, stage)
  end

  def role_for_stage!(scope, project_id, stage) when is_binary(project_id) do
    case role_for_stage(scope, project_id, stage) do
      {:ok, %Role{} = role} -> role
      _other -> raise Ecto.NoResultsError, queryable: Role
    end
  end

  defp find_role_for_stage(project_id, stage) do
    stage_atom = normalize_stage(stage)

    if stage_atom do
      case Repo.get_by(Role, project_id: project_id, stage: stage_atom) do
        %Role{} = role -> {:ok, role}
        nil -> {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  defp normalize_stage(stage) when is_atom(stage) do
    if stage in TaskStage.values(), do: stage
  end

  defp normalize_stage(stage) when is_binary(stage) do
    case TaskStage.cast(stage) do
      {:ok, atom_val} -> atom_val
      _error -> nil
    end
  end

  defp normalize_stage(_other), do: nil
end
