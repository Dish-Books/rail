defmodule Rail.Roles.Schemas.Role do
  @moduledoc """
  Schema for an agent role configured within a project.
  """
  use Rail.Schema

  alias Rail.Projects.Schemas.Project
  alias Rail.Tools.Schemas.Backend

  @canonical_stages [
    :product,
    :design,
    :architect,
    :engineer,
    :review,
    :qa,
    :qa_lead,
    :demo,
    :debugger
  ]
  @allowed_stages @canonical_stages ++ [:ready_to_merge, :merged]

  # Phosphor classes are emitted by the Tailwind plugin only for names it finds as
  # literals in scanned source, so an icon that lives solely in the database would
  # render as an empty span. Keep in sync with the `@source inline(...)` safelist in
  # assets/css/app.css.
  @icon_names [
    "pi-arrows-split",
    "pi-book-open",
    "pi-brain",
    "pi-bug",
    "pi-chat-text-fill",
    "pi-check-square-fill",
    "pi-clipboard-text",
    "pi-code",
    "pi-compass-tool",
    "pi-cube",
    "pi-detective",
    "pi-eye",
    "pi-flask",
    "pi-gear",
    "pi-globe-hemisphere-west",
    "pi-lightbulb",
    "pi-magnifying-glass",
    "pi-paint-brush",
    "pi-palette",
    "pi-pen-nib",
    "pi-robot",
    "pi-rocket-launch",
    "pi-ruler",
    "pi-seal-check-fill",
    "pi-shield-check",
    "pi-terminal-window",
    "pi-test-tube",
    "pi-users-three",
    "pi-video-camera",
    "pi-wrench"
  ]
  @default_icon_name "pi-robot"

  @reasoning_efforts [:low, :medium, :high]

  @primary_key {:id, UXID, autogenerate: true, prefix: "rol"}
  schema "roles" do
    field :stage, Ecto.Enum, values: @allowed_stages
    field :name, :string
    field :description, :string
    field :icon_name, :string, default: @default_icon_name
    field :model, :string
    field :reasoning_effort, Ecto.Enum, values: @reasoning_efforts
    field :system_prompt, :string
    field :max_concurrent, :integer, default: 1
    field :position, :integer, default: 0

    belongs_to :backend, Backend, type: UXID
    belongs_to :project, Project, type: UXID

    timestamps()
  end

  @cast_fields [
    :stage,
    :name,
    :description,
    :icon_name,
    :backend_id,
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
    :backend_id,
    :icon_name,
    :max_concurrent,
    :position
  ]

  @doc "Returns the list of canonical pipeline stages for agent roles."
  def canonical_stages, do: @canonical_stages
  def stages, do: @allowed_stages
  def reasoning_efforts, do: @reasoning_efforts

  @doc "Returns the Phosphor icon classes a role may be assigned."
  def icon_names, do: @icon_names

  def default_icon_name, do: @default_icon_name

  def changeset(role, attrs, project_id \\ nil) do
    role
    |> cast(attrs, @cast_fields)
    |> maybe_put_project_id(project_id)
    |> validate_required(@required_fields)
    |> validate_inclusion(:icon_name, @icon_names)
    |> validate_number(:max_concurrent, greater_than_or_equal_to: 1)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> unique_constraint(:stage, name: :roles_project_id_stage_index)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:backend_id)
  end

  defp maybe_put_project_id(changeset, nil), do: changeset
  defp maybe_put_project_id(changeset, project_id), do: put_change(changeset, :project_id, project_id)
end
