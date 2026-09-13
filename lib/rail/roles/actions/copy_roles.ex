defmodule Rail.Roles.Actions.CopyRoles do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Roles.Schemas.Role

  def copy_roles(_scope, target_project_id, source_project_id, opts)
      when is_binary(target_project_id) and is_binary(source_project_id) do
    source_roles = Rail.Roles.list_roles(source_project_id)
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
          project_id: target_project_id,
          stage: role.stage,
          name: role.name,
          description: role.description,
          icon_name: role.icon_name,
          backend_id: role.backend_id,
          model: role.model,
          reasoning_effort: role.reasoning_effort,
          system_prompt: role.system_prompt,
          max_concurrent: role.max_concurrent,
          position: role.position
        }

        changeset = Role.changeset(%Role{}, attrs)

        case Repo.insert(changeset) do
          {:ok, copied} -> copied
          {:error, cs} -> Repo.rollback(cs)
        end
      end)
    end)
  end
end
