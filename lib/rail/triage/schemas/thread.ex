defmodule Rail.Triage.Schemas.Thread do
  @moduledoc """
  A Slack thread in a project's connected channel, and where triage stands on it:
  being read (`:triaging`), waiting on a person to send its reply, tickets and
  follow-ups (`:waiting`), or finished (`:done`).
  """
  use Rail.Schema

  alias Rail.Projects.Schemas.Project
  alias Rail.Projects.Schemas.SlackChannel
  alias Rail.Support.Schemas.Conversation
  alias Rail.Triage.Schemas.ChatMessage
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Message
  alias Rail.Users.Schemas.User

  @statuses [:triaging, :waiting, :done]
  @send_stale_after_minutes 2

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
    field :dismissed_at, :utc_datetime_usec
    field :last_message_at, :utc_datetime_usec
    field :reply_text, :string
    field :reply_posted_at, :utc_datetime_usec
    # The lock a Send holds while it comments, creates and posts, and what the last one could not do.
    field :send_started_at, :utc_datetime_usec
    field :send_error, :string
    # When the last finished pass began, so a chat line sent during it still asks for another.
    field :chat_read_at, :utc_datetime_usec

    belongs_to :project, Project
    belongs_to :slack_channel, SlackChannel
    # Set on a thread a support person forwarded from Intercom, which has no channel.
    belongs_to :support_conversation, Conversation
    belongs_to :forwarded_by, User
    belongs_to :dismissed_by, User
    # Also the claim a Send takes before it posts, so the reply goes out once.
    belongs_to :reply_posted_by, User

    has_many :messages, Message
    has_many :items, Item
    has_many :chat_messages, ChatMessage

    timestamps()
  end

  def changeset(%SlackChannel{id: channel_id, project_id: project_id}, attrs) do
    %__MODULE__{slack_channel_id: channel_id, project_id: project_id}
    |> cast(attrs, [:external_id, :last_message_at])
    |> validate_required([:external_id])
    |> unique_constraint([:slack_channel_id, :external_id])
  end

  @doc """
  A thread a support person forwarded from Intercom: waiting, with no channel, and never triaged.
  """
  def forwarded_changeset(%Conversation{} = conversation, %User{id: user_id}, inbox_url) do
    now = DateTime.utc_now()

    change(
      %__MODULE__{
        project_id: conversation.project_id,
        support_conversation_id: conversation.id,
        forwarded_by_id: user_id,
        status: :waiting,
        last_message_at: now
      },
      external_id: "intercom:#{conversation.external_id}:#{DateTime.to_unix(now, :microsecond)}",
      title: conversation.title,
      permalink: inbox_url
    )
  end

  @doc """
  The reply as the person types it. Line breaks are stored as `\\n`, as the agent writes them, and an
  emptied reply stays "" so its box stays on the page to write a new one.
  """
  def reply_changeset(thread, attrs) do
    thread
    |> cast(attrs, [:reply_text], empty_values: [])
    |> update_change(:reply_text, &if(is_binary(&1), do: String.replace(&1, "\r\n", "\n"), else: &1))
  end

  def statuses, do: @statuses

  def reply_draft?(%__MODULE__{dismissed_at: nil, reply_posted_at: nil, reply_text: text}),
    do: is_binary(text) and String.trim(text) != ""

  def reply_draft?(%__MODULE__{}), do: false

  @doc """
  The tickets Send creates: titled, not ignored, not created, not sent. None on a dismissed thread. Needs the items preloaded.
  """
  def to_create(%__MODULE__{dismissed_at: %DateTime{}}), do: []
  def to_create(%__MODULE__{items: items}), do: Enum.filter(items, &Item.to_create?/1)

  @doc """
  The follow-ups Send adds to existing tickets. None on a dismissed thread. Needs the items preloaded.
  """
  def to_update(%__MODULE__{dismissed_at: %DateTime{}}), do: []
  def to_update(%__MODULE__{items: items}), do: Enum.filter(items, &Item.to_update?/1)

  @doc """
  The button's label, naming each part there is, such as "Send reply, create 2 tickets & update 1". Nil with nothing to send.
  """
  def send_label(%__MODULE__{} = thread) do
    creates = length(to_create(thread))
    updates = length(to_update(thread))

    parts =
      Enum.reject(
        [
          reply_draft?(thread) && "send reply",
          creates > 0 && "create #{creates} #{if creates == 1, do: "ticket", else: "tickets"}",
          updates > 0 && "update #{updates}"
        ],
        &(&1 == false)
      )

    case parts do
      [] -> nil
      [only] -> sentence(only)
      many -> sentence(Enum.join(Enum.drop(many, -1), ", ") <> " & " <> List.last(many))
    end
  end

  @doc """
  Whether a Send holds the thread. A lock a crash left behind stops counting after two minutes.
  """
  def sending?(%__MODULE__{send_started_at: %DateTime{} = at}),
    do: DateTime.after?(at, DateTime.shift(DateTime.utc_now(), minute: -@send_stale_after_minutes))

  def sending?(%__MODULE__{}), do: false

  def send_stale_after_minutes, do: @send_stale_after_minutes

  @doc """
  Whether a person wrote in the chat since the last finished pass began. Needs the chat preloaded.
  """
  def chat_owed?(%__MODULE__{chat_messages: lines, chat_read_at: read_at}),
    do: Enum.any?(lines, &(&1.author == :person and (is_nil(read_at) or DateTime.after?(&1.inserted_at, read_at))))

  @doc """
  Whether the round still waits on a person: a reply to post, a ticket to create or a follow-up to add.
  """
  def pending?(%__MODULE__{} = thread), do: is_binary(send_label(thread))

  def forwarded?(%__MODULE__{support_conversation_id: id}), do: is_binary(id)

  @doc """
  Where the thread came from, for the queue and the header. Needs the channel preloaded.
  """
  def source_label(%__MODULE__{support_conversation_id: id}) when is_binary(id), do: "Intercom"
  def source_label(%__MODULE__{slack_channel: %SlackChannel{name: name}}), do: "##{name}"

  def link_label(%__MODULE__{} = thread), do: if(forwarded?(thread), do: "Intercom conversation", else: "Slack thread")

  def external?(%__MODULE__{slack_channel: %SlackChannel{external: external}}), do: external
  def external?(%__MODULE__{}), do: false

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
  a bot's only where the channel opted in and the bot is not Rail's own. A forwarded
  thread has none. Needs the channel and its workspace preloaded.
  """
  def triggering?(%__MODULE__{slack_channel_id: nil}, %Message{}), do: false

  def triggering?(%__MODULE__{} = thread, %Message{} = message) do
    %SlackChannel{bot_triage_enabled: bots?, slack_workspace: workspace} = thread.slack_channel

    cond do
      Message.via_rail?(message) -> false
      not message.from_bot -> true
      true -> bots? and message.author_external_id != workspace.bot_id
    end
  end

  def kind_counts(%__MODULE__{items: items}) do
    Map.merge(%{bug: 0, feature_request: 0}, Enum.frequencies_by(items, & &1.kind))
  end

  def to_accept_count(%__MODULE__{} = thread),
    do: length(to_create(thread)) + length(to_update(thread)) + if(reply_draft?(thread), do: 1, else: 0)

  @doc """
  How a finished thread ended, for its row in the queue. Needs the reply's poster and the items' creators preloaded.
  """
  def outcome_label(%__MODULE__{dismissed_by: %User{} = user}), do: "Dismissed by #{name(user)}"

  def outcome_label(%__MODULE__{items: items} = thread) do
    cond do
      creator = Enum.find_value(items, &user(&1.issue_created_by)) -> "Accepted by #{name(creator)}"
      poster = user(thread.reply_posted_by) -> "Replied by #{name(poster)}"
      items != [] -> "Nothing sent"
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

  defp sentence(text), do: String.upcase(String.first(text)) <> String.slice(text, 1..-1//1)

  defp user(%User{} = user), do: user
  defp user(_none), do: nil

  defp name(%User{name: name}) when is_binary(name) and name != "", do: name
  defp name(%User{login: login}), do: login
end
