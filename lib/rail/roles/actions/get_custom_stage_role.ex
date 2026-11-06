defmodule Rail.Roles.Actions.GetCustomStageRole do
  @moduledoc """
  The project role a workflow's custom stage runs as, one per stage name: made the first time a task on the project
  enters that stage, and given the Engineer role's backend, model and reasoning effort every time.
  """

  alias Rail.Repo
  alias Rail.Roles.Schemas.Role

  # Never the prompt a run is given: that is the issue's own copy of its workflow file's.
  @system_prompt "A custom stage of a workflow file. Each task gives it the prompt its file had when the task's issue was opened."

  @doc """
  Creates or refreshes `project_id`'s role for the custom stage `name` and returns `{:ok, role}`. Two tasks entering
  it at once both land on the one row.
  """
  def get_custom_stage_role(project_id, name) when is_binary(project_id) and is_binary(name) do
    engineer = Repo.get_by!(Role, project_id: project_id, stage: :engineer)

    %Role{project_id: project_id, custom_stage: name}
    |> Role.changeset(%{
      name: name,
      icon_name: "pi-clipboard-text",
      cli: engineer.cli,
      model: engineer.model,
      reasoning_effort: engineer.reasoning_effort,
      reserved_cpus: engineer.reserved_cpus,
      max_concurrent: engineer.max_concurrent,
      position: engineer.position,
      system_prompt: @system_prompt
    })
    |> Repo.insert(
      on_conflict: {:replace, [:cli, :model, :reasoning_effort, :reserved_cpus, :max_concurrent, :updated_at]},
      conflict_target: [:project_id, :custom_stage],
      returning: true
    )
  end
end
