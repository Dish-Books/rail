defmodule Rail.Pipeline.Schemas.CoderabbitReview do
  @moduledoc """
  One review a person asked CodeRabbit for on a task's pull request, and where it got to. Each row is one review spent
  from the hourly allowance, so the task page counts them.

  `external_id` is the GitHub id of the comment that asked for it. `command` is `full` for a pull request's first review
  and `incremental` after, which reads only the commits since.
  """
  use Rail.Schema

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Users.Schemas.User

  @statuses [:requested, :reviewing, :done, :skipped, :rate_limited, :failed, :timed_out]
  @pending [:requested, :reviewing]

  @primary_key {:id, UXID, autogenerate: true, prefix: "crv"}
  schema "coderabbit_reviews" do
    field :pr_number, :integer
    field :round, :integer
    field :head_sha, :string
    field :command, Ecto.Enum, values: [:full, :incremental]
    field :external_id, :integer
    field :status, Ecto.Enum, values: @statuses, default: :requested
    field :comment_count, :integer
    field :finished_at, :utc_datetime_usec

    belongs_to :project, Project
    belongs_to :task, Task
    belongs_to :requested_by, User

    timestamps()
  end

  @doc """
  Builds a changeset for a review asked for on `task` at `head_sha` by `user`, before GitHub has the comment.
  """
  def request_changeset(%Task{} = task, %User{} = user, attrs) do
    %__MODULE__{project_id: task.project_id, task_id: task.id, pr_number: task.pr_number, requested_by_id: user.id}
    |> cast(attrs, [:round, :head_sha, :command])
    |> validate_required([:round, :head_sha, :command])
    |> validate_number(:round, greater_than: 0)
  end

  @doc """
  Builds a changeset moving the review to `status`. Every status past reviewing is final and stamps `finished_at`.
  """
  def status_changeset(%__MODULE__{} = review, status, attrs \\ %{}) when status in @statuses do
    finished_at = if status in @pending, do: nil, else: DateTime.utc_now()

    review
    |> cast(attrs, [:external_id, :comment_count])
    |> change(status: status, finished_at: finished_at)
  end

  @doc "True while CodeRabbit has not answered the review yet."
  def pending?(%__MODULE__{status: status}), do: status in @pending

  def pending_statuses, do: @pending

  def status_label(%__MODULE__{status: :requested}), do: "Asked"
  def status_label(%__MODULE__{status: :reviewing}), do: "Reviewing"
  def status_label(%__MODULE__{status: :done}), do: "Done"
  def status_label(%__MODULE__{status: :skipped}), do: "Skipped by CodeRabbit"
  def status_label(%__MODULE__{status: :rate_limited}), do: "Rate limited"
  def status_label(%__MODULE__{status: :failed}), do: "Failed"
  def status_label(%__MODULE__{status: :timed_out}), do: "No answer"
end
