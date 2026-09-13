defmodule Rail.Projects.Schemas.Project do
  @moduledoc false
  use Rail.Schema

  alias Rail.Git
  alias Rail.Linear.Client, as: Linear
  alias Rail.Projects.Schemas.LinearWorkspace

  @primary_key {:id, UXID, autogenerate: true, prefix: "prj"}
  schema "projects" do
    field :name, :string
    field :github_repo, :string
    field :github_installation_id, :integer
    field :default_branch, :string
    field :linear_team_key, :string
    field :linear_team_id, :string
    field :linear_state_ids, :map, default: %{}
    field :clone_path, :string
    field :active, :boolean, default: true

    has_one :linear_workspace, LinearWorkspace, on_replace: :update

    timestamps()
  end

  @fields [
    :name,
    :github_repo,
    :github_installation_id,
    :default_branch,
    :linear_team_key,
    :linear_state_ids,
    :clone_path,
    :active
  ]

  @required_fields [
    :name,
    :github_repo,
    :github_installation_id,
    :default_branch,
    :linear_team_key,
    :clone_path
  ]

  def changeset(project, attrs) do
    project
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> validate_change(:clone_path, &validate_clone_path/2)
    |> cast_assoc(:linear_workspace)
    |> unique_constraint(:github_repo)
    |> put_linear_team_id()
  end

  # Every worktree is added from this checkout, so it has to be the root of one.
  defp validate_clone_path(:clone_path, path) do
    if Git.git_repo?(path), do: [], else: [clone_path: "is not a git repository"]
  end

  # People know a Linear team by its key; Linear's API wants its id, and the ids
  # of its workflow states. Both are looked up as the row is written, and only
  # when the key or the workspace it is read through changed, so a form being
  # filled in never calls Linear. With no workspace to ask through there is
  # nothing to look up yet.
  defp put_linear_team_id(%Ecto.Changeset{valid?: true} = changeset) do
    if changed?(changeset, :linear_team_key) or changed?(changeset, :linear_workspace) do
      prepare_changes(changeset, &look_up_linear_team_id/1)
    else
      changeset
    end
  end

  defp put_linear_team_id(changeset), do: changeset

  defp look_up_linear_team_id(changeset) do
    case Linear.team(apply_changes(changeset)) do
      {:ok, %{"teams" => %{"nodes" => [%{"id" => team_id} = team]}}} ->
        changeset
        |> put_change(:linear_team_id, team_id)
        |> put_change(:linear_state_ids, linear_state_ids(team))

      {:error, :no_workspace_token} ->
        put_change(changeset, :linear_team_id, nil)

      {:ok, _no_team} ->
        changeset |> add_error(:linear_team_key, "no Linear team has this key") |> changeset.repo.rollback()

      {:error, _reason} ->
        changeset |> add_error(:linear_team_key, "could not be checked with Linear") |> changeset.repo.rollback()
    end
  end

  # A team can have several states of one type; Rail moves issues into the first,
  # which is written last so it wins.
  defp linear_state_ids(team) do
    (get_in(team, ["states", "nodes"]) || [])
    |> Enum.sort_by(& &1["position"], :desc)
    |> Enum.flat_map(fn state ->
      case state_key(state["type"]) do
        key when is_binary(key) -> [{key, state["id"]}]
        nil -> []
      end
    end)
    |> Map.new()
  end

  defp state_key("triage"), do: "triage"
  defp state_key("backlog"), do: "backlog"
  defp state_key("unstarted"), do: "todo"
  defp state_key("started"), do: "in_progress"
  defp state_key("completed"), do: "done"
  defp state_key("canceled"), do: "canceled"
  defp state_key(_other), do: nil
end
