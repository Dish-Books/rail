defmodule Rail.Roles.Actions.CopyRoles do
  @moduledoc false

  import Ecto.Query

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope
  alias Rail.Users

  def copy_roles(scope, target_project_or_id, source_project_id, opts \\ []) when is_binary(source_project_id) do
    if Scope.admin?(scope) or Users.can?(scope, :manage_roles) do
      target_project_id = extract_project_id(target_project_or_id)
      execute_copy(scope, target_project_id, source_project_id, opts)
    else
      {:error, :not_authorized}
    end
  end

  defp extract_project_id(%Project{id: id}), do: id
  defp extract_project_id(id) when is_binary(id), do: id
  defp extract_project_id(_other), do: nil

  defp execute_copy(_scope, nil, _source_project_id, _opts) do
    {:error, :target_project_not_found}
  end

  defp execute_copy(scope, target_project_id, source_project_id, opts) do
    source_roles = Rail.Roles.list_roles(scope, source_project_id)
    replace_all = Keyword.get(opts, :replace_all, false)

    Repo.transaction(fn ->
      if replace_all do
        Repo.delete_all(from(r in Role, where: r.project_id == ^target_project_id))
      end

      Enum.map(source_roles, fn role ->
        if role.stage && not replace_all do
          Repo.update_all(from(r in Role, where: r.project_id == ^target_project_id and r.stage == ^role.stage),
            set: [stage: nil]
          )
        end

        attrs = %{
          stage: role.stage,
          name: role.name,
          description: role.description,
          icon_name: role.icon_name,
          cli_backend: role.cli_backend,
          model: role.model,
          reasoning_effort: role.reasoning_effort,
          system_prompt: role.system_prompt,
          max_concurrent: role.max_concurrent,
          position: role.position
        }

        changeset = Role.changeset(%Role{}, attrs, target_project_id)

        case Repo.insert(changeset) do
          {:ok, copied} -> copied
          {:error, cs} -> Repo.rollback(cs)
        end
      end)
    end)
  end
end
