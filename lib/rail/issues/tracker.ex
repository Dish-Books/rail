defmodule Rail.Issues.Tracker do
  @moduledoc """
  Where a project's issues live: Linear or GitHub Issues. Every tracker implements the same
  callbacks, so the actions work an issue without asking which one holds it.

  The implementations are `Rail.Issues.Tracker.Linear` and `Rail.Issues.Tracker.Github`, picked
  through `config :rail, :issue_trackers`; tests point it at a Mox mock of this behaviour.
  """

  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  @trackers %{linear: __MODULE__.Linear, github: __MODULE__.Github}

  @doc """
  Opens a ticket for `attrs` (`:title`, `:description`, `:state`, and optionally `:priority`,
  `:estimate`, `:owner_user_id` and `:parent`, the issue it is a sub-issue of) and returns the
  attributes Rail keeps for it, in that state. A tracker sends what it has a place for.
  """
  @callback create_issue(Scope.t(), Project.t(), map()) :: {:ok, map()} | {:error, term()}

  @doc """
  Sends `fields` of `issue` (its project and owner preloaded), as they now are, to the ticket.
  `previous_owner` is who owned it before, when the owner is among them.
  """
  @callback update_issue(Issue.t(), [atom()], User.t() | nil) :: :ok | {:error, term()}

  @doc """
  Moves the ticket to `:in_progress`, `:in_review` or `:done`, only if that is forward of where it is now.
  """
  @callback advance_issue(Issue.t(), :in_progress | :in_review | :done) :: :ok | {:error, term()}

  @doc """
  Comments `body` on the ticket, as an answer to `parent` when there is one, and keeps the comment.
  """
  @callback create_comment(Scope.t(), Issue.t(), String.t(), Comment.t() | nil) ::
              {:ok, Comment.t()} | {:error, term()}

  @doc """
  The identifier Rail keeps for what `identifier` names on `project`, or `:error` when it names nothing.
  """
  @callback canonical_identifier(Project.t(), String.t()) :: {:ok, String.t()} | :error

  @doc """
  The attributes of the ticket `identifier` names on `project`, fetched from the tracker.
  """
  @callback fetch_issue(Project.t(), String.t()) :: {:ok, map()} | {:error, :not_found | term()}

  @doc """
  Queues a full pull of `project`'s tickets and comments.
  """
  @callback sync_issues(Project.t()) :: {:ok, Oban.Job.t()} | {:error, term()}

  @doc """
  Prepares the tracker for `project` once it is saved, such as the labels it needs.
  """
  @callback set_up_project(Project.t()) :: :ok | {:error, term()}

  @doc """
  Stores a file where `target`'s tickets can link to it, returning its URL.
  """
  @callback upload_asset(Project.t() | LinearWorkspace.t(), String.t(), String.t(), binary()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  Fetches a file the tracker holds for `issue`, as `{:ok, content_type, body}`.
  """
  @callback get_asset(Issue.t(), String.t()) :: {:ok, String.t(), binary()} | {:error, term()}

  @doc """
  `:ok` when `user` can own a ticket here, or why not.
  """
  @callback check_assignable(User.t()) :: :ok | {:error, term()}

  @doc """
  The tracker module for a project, an issue, or a Linear workspace.
  """
  def tracker(%Project{tracker: tracker}), do: lookup(tracker)
  def tracker(%Issue{tracker: tracker}), do: lookup(tracker)
  def tracker(%LinearWorkspace{}), do: lookup(:linear)

  defp lookup(tracker), do: :rail |> Application.get_env(:issue_trackers, @trackers) |> Map.fetch!(tracker)
end
