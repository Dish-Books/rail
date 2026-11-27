defmodule Rail.Projects.Schemas.Project do
  @moduledoc false
  use Rail.Schema

  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.SlackChannel
  alias Rail.Projects.Schemas.SlackWorkspace
  alias Rail.Tools
  alias Rail.Users.Schemas.User

  @primary_key {:id, UXID, autogenerate: true, prefix: "prj"}
  schema "projects" do
    field :name, :string
    field :github_repo, :string
    field :github_installation_id, :integer
    # What its issues are named by, as `<key>-<number>`. Once issues exist it stays as it is.
    field :key, :string
    field :default_branch, :string
    field :clone_path, :string
    field :active, :boolean, default: true
    # Run once in each new worktree, from its root, before any agent works there.
    field :worktree_setup_script, :string
    # Run beside Rail, outside any sandbox, in a checkout of the default branch each time it moves.
    field :toolchain_command, :string
    # The image its sandboxes run, built by the project's own CI with its toolchain and build cache; nil for Rail's.
    field :sandbox_image, :string
    # Run on every commit the engineer finishes, before it is pushed or reviewed.
    field :ci_command, :string
    field :ci_timeout_minutes, :integer, default: 30
    # What each CI run's sandbox holds, whatever the role whose run started it reserves.
    field :ci_reserved_cpus, :integer, default: 1
    # Run from the worktree root in each agent's sandbox that opens a browser; prints a magic link and an email.
    field :account_seed_command, :string
    # Files nobody sees in the app: a later round that changed only these gets no QA or demo. Globs, from the root.
    field :qa_skip_paths, {:array, :string},
      default: [
        "**/*_test.exs",
        "**/test/**",
        "**/*.test.{ts,tsx,js}",
        "**/*Tests.swift",
        "**/src/androidTest/**",
        "**/*.md"
      ]

    # Whose MCP connections a triage pass uses; a pass whose role names any it cannot reach fails.
    belongs_to :triage_user, User
    # Where Rail tells the team a backend lost its sign-in. It is not a `slack_channels` row, so triage never reads it.
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
    :key,
    :default_branch,
    :clone_path,
    :active,
    :worktree_setup_script,
    :toolchain_command,
    :sandbox_image,
    :ci_command,
    :ci_timeout_minutes,
    :ci_reserved_cpus,
    :account_seed_command,
    :qa_skip_paths,
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
    :clone_path,
    :ci_reserved_cpus
  ]

  def changeset(project, attrs) do
    project
    |> cast(lines(attrs), @fields)
    |> validate_required(@required_fields)
    |> validate_format(:key, ~r/^[a-z0-9][a-z0-9_-]*$/i, message: "use letters, digits, - and _")
    |> validate_length(:key, max: 20)
    |> unique_constraint(:key)
    |> lock_key_once_issues_exist()
    |> validate_change(:clone_path, &validate_clone_path/2)
    |> validate_change(:worktree_setup_script, &validate_worktree_setup_script/2)
    |> validate_format(:sandbox_image, ~r/\A[a-z0-9][a-z0-9._\/:@-]*\z/, message: "must be an image reference")
    |> validate_number(:ci_timeout_minutes, greater_than: 0, message: "must be at least a minute")
    |> validate_number(:ci_reserved_cpus, greater_than: 0, message: "must be at least 1 CPU")
    |> validate_ci_capacity()
    |> foreign_key_constraint(:triage_user_id)
    |> validate_learnings_channel()
    |> foreign_key_constraint(:learnings_slack_workspace_id)
    |> unique_constraint(:github_repo)
    |> cast_assoc(:slack_channels)
  end

  # The form edits the globs one to a line.
  defp lines(%{"qa_skip_paths" => text} = attrs) when is_binary(text) do
    %{attrs | "qa_skip_paths" => text |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))}
  end

  defp lines(attrs), do: attrs

  # As a role's is: the machine is only asked when the number changes, and one it
  # cannot be asked about is left to the line, which refuses what never fits.
  defp validate_ci_capacity(%Ecto.Changeset{valid?: true} = changeset) do
    with true <- changed?(changeset, :ci_reserved_cpus),
         {:ok, %{cpus: cpus}} <- Tools.get_sandbox_capacity(),
         needs_cpus when needs_cpus > cpus <- get_field(changeset, :ci_reserved_cpus) do
      machine_cpus = if cpus == 1, do: "1 CPU", else: "#{cpus} CPUs"

      add_error(
        changeset,
        :ci_reserved_cpus,
        "This machine has #{machine_cpus} to reserve, so CI that needs #{needs_cpus} could never start."
      )
    else
      _unchanged_unknown_or_fits -> changeset
    end
  end

  defp validate_ci_capacity(changeset), do: changeset

  # Issues keep the identifiers they were made with, so the key may not move under them.
  defp lock_key_once_issues_exist(%Ecto.Changeset{data: %{id: id}} = changeset) when is_binary(id) do
    if changed?(changeset, :key) do
      prepare_changes(changeset, fn prepared ->
        if prepared.repo.exists?(from i in Issue, where: i.project_id == ^id) do
          prepared
          |> add_error(:key, "cannot change once the project has issues")
          |> prepared.repo.rollback()
        else
          prepared
        end
      end)
    else
      changeset
    end
  end

  defp lock_key_once_issues_exist(changeset), do: changeset

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
end
