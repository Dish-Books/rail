defmodule Rail.Roles.Actions.ImportRoles do
  @moduledoc false

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role

  def import_roles(_scope, project_or_id, roles_data, opts \\ []) do
    project_id = extract_project_id(project_or_id)

    case parse_roles_data(roles_data) do
      {:ok, items} when is_list(items) ->
        execute_import(project_id, items, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_project_id(%Project{id: id}), do: id
  defp extract_project_id(id) when is_binary(id), do: id
  defp extract_project_id(_other), do: nil

  defp parse_roles_data(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, parsed} -> parse_roles_data(parsed)
      {:error, _err} -> {:error, :invalid_json}
    end
  end

  defp parse_roles_data(%{"roles" => roles}) when is_list(roles), do: {:ok, roles}
  defp parse_roles_data(%{roles: roles}) when is_list(roles), do: {:ok, roles}
  defp parse_roles_data(data) when is_list(data), do: {:ok, data}
  defp parse_roles_data(_other), do: {:error, :invalid_roles_data}

  defp execute_import(nil, _items, _opts), do: {:error, :project_not_found}

  defp execute_import(project_id, items, opts) do
    replace_all = Keyword.get(opts, :replace_all, false)

    Repo.transaction(fn ->
      if replace_all do
        Repo.delete_all(from(r in Role, where: r.project_id == ^project_id))
      end

      Enum.map(items, fn item ->
        stage_val = Map.get(item, "stage") || Map.get(item, :stage)

        if stage_val && not replace_all do
          unbind_stage(project_id, stage_val)
        end

        changeset = Role.changeset(%Role{}, item, project_id)

        case Repo.insert(changeset) do
          {:ok, role} -> role
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    end)
  end

  defp unbind_stage(project_id, stage_val) when is_atom(stage_val) do
    Repo.update_all(from(r in Role, where: r.project_id == ^project_id and r.stage == ^stage_val), set: [stage: nil])
  end

  defp unbind_stage(project_id, stage_val) when is_binary(stage_val) do
    case Task.cast_stage(stage_val) do
      {:ok, stage_atom} ->
        Repo.update_all(from(r in Role, where: r.project_id == ^project_id and r.stage == ^stage_atom),
          set: [stage: nil]
        )

      :error ->
        :ok
    end
  end

  defp unbind_stage(_project_id, _stage_val), do: :ok
end
