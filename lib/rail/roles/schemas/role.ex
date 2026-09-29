defmodule Rail.Roles.Schemas.Role do
  @moduledoc """
  Schema for an agent role configured within a project.
  """
  use Rail.Schema

  alias Rail.Projects.Schemas.Project
  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend

  @canonical_stages [
    :product,
    :design,
    :architect,
    :engineer,
    :review,
    :qa,
    :demo,
    :debugger,
    # Reads Slack threads rather than working a task, so no task ever enters it.
    :triage
  ]

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
    field :stage, Ecto.Enum, values: @canonical_stages
    field :name, :string
    field :description, :string
    field :icon_name, :string, default: @default_icon_name
    field :model, :string
    field :reasoning_effort, Ecto.Enum, values: @reasoning_efforts
    field :system_prompt, :string
    field :max_concurrent, :integer, default: 1
    field :position, :integer, default: 0
    field :mcp_tools, {:array, :string}, default: []
    # What each of its sandboxes, and the setup and CI its runs start, holds while it runs.
    field :reserved_cpus, :integer, default: 1
    field :reserved_memory_gb, :integer, default: 2

    belongs_to :backend, Backend
    belongs_to :project, Project

    timestamps()
  end

  @cast_fields [
    :backend_id,
    :description,
    :icon_name,
    :max_concurrent,
    :mcp_tools,
    :model,
    :name,
    :position,
    :project_id,
    :reasoning_effort,
    :reserved_cpus,
    :reserved_memory_gb,
    :stage,
    :system_prompt
  ]

  @required_fields [
    :project_id,
    :name,
    :model,
    :system_prompt,
    :backend_id,
    :icon_name,
    :max_concurrent,
    :position,
    :reserved_cpus,
    :reserved_memory_gb
  ]

  @doc "Returns the list of canonical pipeline stages for agent roles."
  def canonical_stages, do: @canonical_stages

  @doc """
  Builds a changeset for a role.

  A reservation larger than the machine can ever free is refused: a sandbox waits
  for its whole reservation, so one that never fits would wait in line forever.
  """
  def changeset(role, attrs) do
    role
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:icon_name, @icon_names)
    |> validate_number(:max_concurrent, greater_than_or_equal_to: 1)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_number(:reserved_cpus, greater_than_or_equal_to: 1)
    |> validate_number(:reserved_memory_gb, greater_than_or_equal_to: 1)
    |> validate_capacity()
    |> unique_constraint(:stage, name: :roles_project_id_stage_index)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:backend_id)
  end

  @doc """
  How many sandboxes reserving what `role` does fit on a machine of `capacity` at
  once, and which resource runs out first. Takes a role or a map of the two fields.
  """
  def fit_count(%{reserved_cpus: cpus, reserved_memory_gb: memory_gb}, %{cpus: total_cpus, memory_gb: total_memory_gb})
      when is_integer(cpus) and cpus > 0 and is_integer(memory_gb) and memory_gb > 0 do
    by_cpus = div(total_cpus, cpus)
    by_memory = div(total_memory_gb, memory_gb)

    if by_memory < by_cpus,
      do: %{count: by_memory, limited_by: :memory},
      else: %{count: by_cpus, limited_by: :cpus}
  end

  # The machine is only asked when the reservation changes, and one it cannot be
  # asked about is left to the line, which refuses what never fits.
  defp validate_capacity(%Ecto.Changeset{valid?: true} = changeset) do
    with true <- changed?(changeset, :reserved_cpus) or changed?(changeset, :reserved_memory_gb),
         {:ok, capacity} <- Tools.get_sandbox_capacity() do
      refuse_over_capacity(changeset, capacity)
    else
      _unchanged_or_unknown -> changeset
    end
  end

  defp validate_capacity(changeset), do: changeset

  defp refuse_over_capacity(changeset, %{cpus: cpus, memory_gb: memory_gb}) do
    role = if String.match?(get_field(changeset, :name), ~r/^[aeiou]/i), do: "an", else: "a"
    role = "#{role} #{get_field(changeset, :name)}"
    needs_cpus = get_field(changeset, :reserved_cpus)
    needs_memory = get_field(changeset, :reserved_memory_gb)
    machine_cpus = if cpus == 1, do: "1 CPU", else: "#{cpus} CPUs"

    changeset =
      if needs_cpus > cpus,
        do:
          add_error(
            changeset,
            :reserved_cpus,
            "This machine has #{machine_cpus} to reserve, so #{role} that needs #{needs_cpus} could never start."
          ),
        else: changeset

    if needs_memory > memory_gb,
      do:
        add_error(
          changeset,
          :reserved_memory_gb,
          "This machine has #{memory_gb} GB to reserve, so #{role} that needs #{needs_memory} GB could never start."
        ),
      else: changeset
  end
end
