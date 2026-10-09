defmodule Rail.Tools.Schemas.ToolchainInstall do
  @moduledoc """
  One run of a project's toolchain command against a commit of its default
  branch, beside Rail rather than in a sandbox.
  """
  use Rail.Schema

  alias Rail.Projects.Schemas.Project

  @statuses [:queued, :installing, :finished, :failed]

  @primary_key {:id, UXID, autogenerate: true, prefix: "tci"}
  schema "toolchain_installs" do
    field :command, :string
    # The default branch's commit it was queued for; the command runs once for each.
    field :head_sha, :string
    field :status, Ecto.Enum, values: @statuses, default: :queued
    # The end of what the command wrote, kept when it failed.
    field :output, :string
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec

    belongs_to :project, Project

    timestamps()
  end

  @doc "Builds a changeset for a run of `project_id`'s toolchain command."
  def changeset(install, attrs, project_id) do
    install
    |> cast(attrs, [:command, :head_sha, :status, :output, :started_at, :ended_at])
    |> put_change(:project_id, project_id)
    |> validate_required([:project_id, :command, :head_sha, :status])
    |> foreign_key_constraint(:project_id)
  end

  @doc "Where the default branch is checked out for the command to run in."
  def checkout_path(%Project{clone_path: clone_path}), do: Path.join(clone_path, ".worktrees/toolchain")
end
