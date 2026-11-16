defmodule Rail.Pipeline.Schemas.Preview do
  @moduledoc """
  A task's pull request as deployed outside Rail, at the address its project's template gives it.

  `status` is `:deploying` until the deployment answers with the task's head commit, `:live` while it does, and `:gone`
  once the task has no worktree. `live_sha` is the commit last seen live, kept while a later push deploys. `seeded_at` says the Review lead was asked to set up demo examples
  on it, which happens once per task.
  """
  use Rail.Schema

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project

  @primary_key {:id, UXID, autogenerate: true, prefix: "prv"}
  schema "previews" do
    field :url, :string
    field :status, Ecto.Enum, values: [:deploying, :live, :gone]
    field :live_sha, :string
    field :checked_at, :utc_datetime_usec
    field :live_at, :utc_datetime_usec
    field :seeded_at, :utc_datetime_usec

    belongs_to :task, Task

    timestamps()
  end

  def changeset(preview, attrs) do
    preview
    |> cast(attrs, [:task_id, :url, :status, :live_sha, :checked_at, :live_at, :seeded_at])
    |> validate_required([:task_id, :url, :status])
    |> unique_constraint(:task_id)
    |> foreign_key_constraint(:task_id)
  end

  @doc "The browser session a task's preview is shown in on its page."
  def browser_name, do: "app"

  @doc "The address of pull request `number` under `project`'s template, without a trailing slash."
  def url(%Project{preview_url_template: "" <> template}, number) when is_integer(number),
    do: template |> String.replace("{pr_number}", Integer.to_string(number)) |> String.trim_trailing("/")

  @doc "Where the App item opens `preview`: its project's login path on it."
  def login_url(%__MODULE__{url: url}, %Project{preview_login_path: path}), do: url <> (path || "/")

  @doc "The name `project`'s Review lead finds the database of pull request `number` by, or nil."
  def database(%Project{preview_database: "" <> name}, number) when is_integer(number),
    do: String.replace(name, "{pr_number}", Integer.to_string(number))

  def database(%Project{}, _number), do: nil

  @doc "The Cloudflare Access service token `project` reaches its previews with, or nil."
  def access(%Project{preview_access_client_id: "" <> id, preview_access_client_secret: "" <> secret}),
    do: %{client_id: id, client_secret: secret}

  def access(%Project{}), do: nil

  @doc "True while the deployment serves the task's head commit."
  def live?(%__MODULE__{status: :live}), do: true
  def live?(_none_or_not_live), do: false
end
