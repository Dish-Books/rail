defmodule Rail.Roles.Schemas.Role do
  @moduledoc """
  Schema for an agent role configured within a project.
  """
  use Rail.Schema

  alias Rail.Projects.Schemas.Project

  @canonical_stages [
    :product,
    :architect,
    :engineer,
    :review,
    :qa,
    :qa_lead,
    :demo,
    :debugger,
    :designer,
    :rebase
  ]
  @allowed_stages @canonical_stages ++ [:design, :ready_to_merge, :merged]

  @backends [:claude, :agy, :codex]
  @reasoning_efforts [:low, :medium, :high]

  @derive {LiveSync.Watch, subscription_key: :project_id, table: "roles"}
  @primary_key {:id, UXID, autogenerate: true, prefix: "rol"}
  schema "roles" do
    belongs_to :project, Project, type: UXID
    field :stage, Ecto.Enum, values: @allowed_stages
    field :name, :string
    field :description, :string
    field :icon_name, :string
    field :cli_backend, Ecto.Enum, values: @backends, default: :claude
    field :model, :string
    field :reasoning_effort, Ecto.Enum, values: @reasoning_efforts
    field :system_prompt, :string
    field :max_concurrent, :integer, default: 1
    field :position, :integer, default: 0

    timestamps()
  end

  @cast_fields [
    :stage,
    :name,
    :description,
    :icon_name,
    :cli_backend,
    :model,
    :reasoning_effort,
    :system_prompt,
    :max_concurrent,
    :position
  ]

  @required_fields [
    :project_id,
    :name,
    :model,
    :system_prompt,
    :cli_backend,
    :max_concurrent,
    :position
  ]

  @doc "Returns the list of canonical pipeline stages for agent roles."
  def canonical_stages, do: @canonical_stages
  def stages, do: @allowed_stages
  def backends, do: @backends
  def reasoning_efforts, do: @reasoning_efforts

  def changeset(role, attrs, project_id \\ nil) do
    role
    |> cast(attrs, @cast_fields)
    |> maybe_put_project_id(project_id)
    |> validate_required(@required_fields)
    |> validate_number(:max_concurrent, greater_than_or_equal_to: 1)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> unique_constraint(:stage, name: :roles_project_id_stage_index)
    |> foreign_key_constraint(:project_id)
  end

  def factory do
    id = System.unique_integer([:positive])

    %__MODULE__{
      project_id: UXID.generate!(prefix: "prj"),
      stage: :engineer,
      name: "Engineer #{id}",
      description: "Writes tested code for issue #{id}",
      icon_name: "pi-cpu",
      cli_backend: :claude,
      model: "claude-3-7-sonnet",
      reasoning_effort: :high,
      system_prompt: "You are an expert engineer.",
      max_concurrent: 1,
      position: 0
    }
  end

  defp maybe_put_project_id(changeset, nil), do: changeset
  defp maybe_put_project_id(changeset, project_id), do: put_change(changeset, :project_id, project_id)
end
