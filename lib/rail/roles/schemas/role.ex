defmodule Rail.Roles.Schemas.Role do
  @moduledoc """
  Schema for an agent role configured within a project.
  """
  use Rail.Schema

  alias Rail.Projects.Schemas.Project
  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend

  @canonical_stages [
    # Leads product, design and architect, which run inside it as subagents and are entered by no task.
    :plan,
    :product,
    :design,
    :architect,
    :engineer,
    # Leads review, QA, engineer and demo, which run inside it as subagents; a task at Review enters it.
    :review_lead,
    :review,
    :qa,
    :demo,
    :debugger,
    # Reads Slack threads rather than working a task, so no task ever enters it.
    :triage,
    # Distills what finished tasks taught and curates the rules daily; no task enters it either.
    :curator
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
    # The CLI the model runs on; the account is picked per conversation, never fixed on the role.
    field :cli, Ecto.Enum, values: Backend.names()
    field :reasoning_effort, Ecto.Enum, values: @reasoning_efforts
    field :system_prompt, :string
    # Set by Roles.get_role/1 and Roles.list_roles/1: the repo file the prompt was read from.
    field :prompt_path, :string, virtual: true
    field :max_concurrent, :integer, default: 1
    field :position, :integer, default: 0
    field :mcp_tools, {:array, :string}, default: []
    # What each of its sandboxes, and the setup and CI its runs start, holds while it runs.
    field :reserved_cpus, :integer, default: 1

    belongs_to :project, Project

    timestamps()
  end

  @cast_fields [
    :cli,
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
    :stage,
    :system_prompt
  ]

  @required_fields [
    :project_id,
    :name,
    :model,
    :system_prompt,
    :cli,
    :icon_name,
    :max_concurrent,
    :position,
    :reserved_cpus
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
    |> validate_capacity()
    |> unique_constraint(:stage, name: :roles_project_id_stage_index)
    |> foreign_key_constraint(:project_id)
  end

  @doc """
  How many sandboxes reserving what `role` does fit on a machine of `capacity` at
  once. Takes a role or a map of its `reserved_cpus`.
  """
  def fit_count(%{reserved_cpus: cpus}, %{cpus: total_cpus}) when is_integer(cpus) and cpus > 0, do: div(total_cpus, cpus)

  # The machine is only asked when the reservation changes, and one it cannot be
  # asked about is left to the line, which refuses what never fits.
  defp validate_capacity(%Ecto.Changeset{valid?: true} = changeset) do
    with true <- changed?(changeset, :reserved_cpus),
         {:ok, capacity} <- Tools.get_sandbox_capacity() do
      refuse_over_capacity(changeset, capacity)
    else
      _unchanged_or_unknown -> changeset
    end
  end

  defp validate_capacity(changeset), do: changeset

  defp refuse_over_capacity(changeset, %{cpus: cpus}) do
    role = if String.match?(get_field(changeset, :name), ~r/^[aeiou]/i), do: "an", else: "a"
    role = "#{role} #{get_field(changeset, :name)}"
    needs_cpus = get_field(changeset, :reserved_cpus)
    machine_cpus = if cpus == 1, do: "1 CPU", else: "#{cpus} CPUs"

    if needs_cpus > cpus,
      do:
        add_error(
          changeset,
          :reserved_cpus,
          "This machine has #{machine_cpus} to reserve, so #{role} that needs #{needs_cpus} could never start."
        ),
      else: changeset
  end
end
