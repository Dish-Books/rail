defmodule Rail.Roles.Actions.RoleForStage do
  @moduledoc false

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  def role_for_stage(project_id, stage) when is_binary(project_id) do
    role_for_stage(Scope.for_system(), project_id, stage)
  end

  def role_for_stage(_scope, project_id, stage) do
    find_role_for_stage(project_id, stage)
  end

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
    cond do
      stage in Role.canonical_stages() -> stage
      stage in Task.stages() -> stage
      true -> nil
    end
  end

  defp normalize_stage(stage) when is_binary(stage) do
    atom =
      try do
        String.to_existing_atom(stage)
      rescue
        ArgumentError -> nil
      end

    normalize_stage(atom)
  end

  defp normalize_stage(_other), do: nil
end
