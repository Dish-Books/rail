defmodule Rail.Triage.Schemas.Thread do
  @moduledoc """
  A Slack thread in a project's connected channel, and where triage stands on it:
  being read (`:triaging`), waiting on a person to accept what it proposed
  (`:waiting`), or finished (`:done`).
  """
  use Rail.Schema

  alias Rail.Projects.Schemas.Project
  alias Rail.Projects.Schemas.SlackChannel
  alias Rail.Triage.Schemas.Correction
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Message
  alias Rail.Users.Schemas.User

  @statuses [:triaging, :waiting, :done]

  @primary_key {:id, UXID, autogenerate: true, prefix: "tth"}
  schema "triage_threads" do
    # The thread's parent message ts, which is how Slack names a thread.
    field :external_id, :string
    field :title, :string
    field :permalink, :string
    field :status, Ecto.Enum, values: @statuses, default: :triaging
    field :no_response_reason, :string
    field :error, :string
    # The lock a pass holds, and the MCP token it was given while it holds it.
    field :triage_started_at, :utc_datetime_usec
    field :mcp_token_hash, :binary, redact: true
    field :forced, :boolean, default: false
    field :dismissed_at, :utc_datetime_usec
    field :last_message_at, :utc_datetime_usec

    belongs_to :project, Project
    belongs_to :slack_channel, SlackChannel
    belongs_to :dismissed_by, User

    has_many :messages, Message
    has_many :items, Item
    has_many :corrections, Correction

    timestamps()
  end

  def changeset(%SlackChannel{id: channel_id, project_id: project_id}, attrs) do
    %__MODULE__{slack_channel_id: channel_id, project_id: project_id}
    |> cast(attrs, [:external_id, :last_message_at])
    |> validate_required([:external_id])
    |> unique_constraint([:slack_channel_id, :external_id])
  end

  def statuses, do: @statuses

  @doc """
  Where a pass writes the thread, the issues list and its result, outside any repository.
  """
  def scratch_path(%__MODULE__{id: id, project_id: project_id}) do
    root = Application.get_env(:rail, :scratch_root) || Path.join(File.cwd!(), "output")
    Path.join([root, project_id, "triage", id])
  end

  def worktree_path(%__MODULE__{id: id, project: %Project{clone_path: clone_path}}) do
    Path.join(clone_path, ".worktrees/triage-#{id}")
  end

  @doc """
  Whether `message` is one triage reads. A post made through Rail never is, and
  a bot's only where the channel opted in and the bot is not Rail's own, unless
  a person asked for the thread to be triaged anyway. Needs the channel and its
  workspace preloaded.
  """
  def triggering?(%__MODULE__{} = thread, %Message{} = message) do
    %SlackChannel{triage_bot_messages: bots?, slack_workspace: workspace} = thread.slack_channel

    cond do
      Message.via_rail?(message) -> false
      thread.forced or not message.from_bot -> true
      true -> bots? and message.author_external_id != workspace.bot_id
    end
  end

  def kind_counts(%__MODULE__{items: items}) do
    Map.merge(%{bug: 0, feature_request: 0}, Enum.frequencies_by(items, & &1.kind))
  end

  def to_accept_count(%__MODULE__{items: items}), do: items |> Enum.map(&Item.pending_proposals/1) |> Enum.sum()

  @doc """
  How a finished thread ended, for its row in the queue. Needs the items' users preloaded.
  """
  def outcome_label(%__MODULE__{dismissed_by: %User{} = user}), do: "Dismissed by #{name(user)}"

  def outcome_label(%__MODULE__{items: items}) do
    cond do
      creator = Enum.find_value(items, &user(&1.issue_created_by)) -> "Accepted by #{name(creator)}"
      poster = Enum.find_value(items, &user(&1.reply_posted_by)) -> "Replied by #{name(poster)}"
      true -> "Needed no response"
    end
  end

  def title_or_preview(%__MODULE__{title: title}) when is_binary(title) and title != "", do: title

  def title_or_preview(%__MODULE__{messages: [%Message{} = first | _rest]}) do
    case String.trim(first.text) do
      "" -> "Message from #{first.author_name}"
      text -> String.slice(text, 0, 140)
    end
  end

  def title_or_preview(%__MODULE__{}), do: "Slack thread"

  defp user(%User{} = user), do: user
  defp user(_none), do: nil

  defp name(%User{name: name}) when is_binary(name) and name != "", do: name
  defp name(%User{login: login}), do: login
end
