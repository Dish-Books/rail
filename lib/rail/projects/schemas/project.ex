defmodule Rail.Projects.Schemas.Project do
  @moduledoc false
  use Rail.Schema

  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Linear.Client, as: Linear
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.SlackChannel
  alias Rail.Projects.Schemas.SlackWorkspace
  alias Rail.Users.Schemas.User

  @primary_key {:id, UXID, autogenerate: true, prefix: "prj"}
  schema "projects" do
    field :name, :string
    field :github_repo, :string
    field :github_installation_id, :integer
    # Where its issues live, and the key they are named by: a Linear project's team key, or the prefix a
    # GitHub project's issues are named `<key>#<number>` with. Fixed once there are any.
    field :tracker, Ecto.Enum, values: [:linear, :github], default: :linear
    field :key, :string
    field :default_branch, :string
    field :linear_team_id, :string
    field :linear_state_ids, :map, default: %{}
    field :clone_path, :string
    field :active, :boolean, default: true
    # Run once in each new worktree, from its root, before any agent works there.
    field :worktree_setup_script, :string
    # Run beside Rail, outside any sandbox, in a checkout of the default branch each time it moves.
    field :toolchain_command, :string
    # Run on every commit the engineer finishes, before it is pushed or reviewed.
    field :ci_command, :string
    field :ci_timeout_minutes, :integer, default: 30
    # Run from the worktree root in each agent's sandbox that opens a browser; prints a magic link and an email.
    field :account_seed_command, :string

    # Shared by every project on the same Linear workspace; each project is one team in it.
    belongs_to :linear_workspace, LinearWorkspace
    # Whose MCP connections a triage pass uses; a pass whose role names any it cannot reach fails.
    belongs_to :triage_user, User
    # Where the curator's digest posts. It is not a `slack_channels` row, so triage never reads it.
    belongs_to :learnings_slack_workspace, SlackWorkspace
    field :learnings_channel_external_id, :string

    # Its threads hang off each one, so a channel sent back with its `id` is updated, never recreated,
    # and only one left out is deleted. Params without `slack_channels` leave them alone.
    has_many :slack_channels, SlackChannel, on_replace: :delete

    timestamps()
  end

  @fields [
    :name,
    :github_repo,
    :github_installation_id,
    :tracker,
    :key,
    :default_branch,
    :linear_state_ids,
    :linear_workspace_id,
    :clone_path,
    :active,
    :worktree_setup_script,
    :toolchain_command,
    :ci_command,
    :ci_timeout_minutes,
    :account_seed_command,
    :triage_user_id,
    :learnings_slack_workspace_id,
    :learnings_channel_external_id
  ]

  @required_fields [
    :name,
    :github_repo,
    :github_installation_id,
    :key,
    :default_branch,
    :clone_path
  ]

  def changeset(project, attrs) do
    project
    |> cast(attrs, @fields)
    |> put_default_key()
    |> validate_required(@required_fields)
    |> validate_format(:key, ~r/^[a-z0-9][a-z0-9_-]*$/i, message: "use letters, digits, - and _")
    |> validate_length(:key, max: 20)
    |> unique_constraint(:key)
    |> lock_tracker_once_issues_exist()
    |> validate_change(:clone_path, &validate_clone_path/2)
    |> validate_change(:worktree_setup_script, &validate_worktree_setup_script/2)
    |> validate_number(:ci_timeout_minutes, greater_than: 0, message: "must be at least a minute")
    |> foreign_key_constraint(:linear_workspace_id)
    |> foreign_key_constraint(:triage_user_id)
    |> validate_learnings_channel()
    |> foreign_key_constraint(:learnings_slack_workspace_id)
    |> unique_constraint(:github_repo)
    |> cast_assoc(:slack_channels)
    |> put_linear_team_id()
  end

  # A GitHub project needs a key; the repo's name is the one people would pick anyway.
  defp put_default_key(changeset) do
    with :github <- get_field(changeset, :tracker),
         nil <- get_field(changeset, :key),
         repo when is_binary(repo) <- get_field(changeset, :github_repo),
         [_owner, name] <- String.split(repo, "/", parts: 2) do
      put_change(changeset, :key, name)
    else
      _keep -> changeset
    end
  end

  # Issues keep the tracker and identifiers they were made with, so neither may move under them.
  defp lock_tracker_once_issues_exist(%Ecto.Changeset{data: %{id: id}} = changeset) when is_binary(id) do
    if changed?(changeset, :tracker) or changed?(changeset, :key) do
      prepare_changes(changeset, fn prepared ->
        if prepared.repo.exists?(from i in Issue, where: i.project_id == ^id) do
          prepared
          |> add_error(:tracker, "cannot change once the project has issues")
          |> prepared.repo.rollback()
        else
          prepared
        end
      end)
    else
      changeset
    end
  end

  defp lock_tracker_once_issues_exist(changeset), do: changeset

  # A channel id means nothing without the workspace whose bot posts there.
  defp validate_learnings_channel(changeset) do
    if get_field(changeset, :learnings_channel_external_id),
      do: validate_required(changeset, [:learnings_slack_workspace_id]),
      else: changeset
  end

  # Every worktree is added from this checkout, so it has to be the root of one.
  defp validate_clone_path(:clone_path, path) do
    if Git.git_repo?(path), do: [], else: [clone_path: "is not a git repository"]
  end

  # It is run from inside the task's worktree, so it has to name a file in there.
  defp validate_worktree_setup_script(:worktree_setup_script, path) do
    if Path.type(path) == :relative and ".." not in Path.split(path),
      do: [],
      else: [worktree_setup_script: "must be a path inside the repository"]
  end

  # People know a Linear team by its key; Linear's API wants its id, and the ids
  # of its workflow states. Both are looked up as the row is written, and only
  # when the key, the tracker or the workspace it is read through changed, so a form being
  # filled in never calls Linear. With no workspace to ask through there is
  # nothing to look up yet.
  defp put_linear_team_id(%Ecto.Changeset{valid?: true} = changeset) do
    linear? = get_field(changeset, :tracker) == :linear

    if linear? and Enum.any?([:tracker, :key, :linear_workspace_id], &changed?(changeset, &1)) do
      prepare_changes(changeset, &look_up_linear_team_id/1)
    else
      changeset
    end
  end

  defp put_linear_team_id(changeset), do: changeset

  defp look_up_linear_team_id(changeset) do
    project = changeset |> apply_changes() |> changeset.repo.preload(:linear_workspace, force: true)

    case Linear.team(project) do
      {:ok, %{"teams" => %{"nodes" => [%{"id" => team_id} = team]}}} ->
        changeset
        |> put_change(:linear_team_id, team_id)
        |> put_change(:linear_state_ids, linear_state_ids(team))

      {:error, :no_workspace_token} ->
        put_change(changeset, :linear_team_id, nil)

      {:ok, _no_team} ->
        changeset |> add_error(:key, "no Linear team has this key") |> changeset.repo.rollback()

      {:error, _reason} ->
        changeset |> add_error(:key, "could not be checked with Linear") |> changeset.repo.rollback()
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
