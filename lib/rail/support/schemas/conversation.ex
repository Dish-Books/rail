defmodule Rail.Support.Schemas.Conversation do
  @moduledoc """
  An Intercom conversation in a connected workspace, waiting on support or done, and the
  draft the agent keeps for it: one reply, the items it would forward, and a chat.
  """
  use Rail.Schema

  alias Rail.Projects.Schemas.Project
  alias Rail.Support.Schemas.ChatMessage
  alias Rail.Support.Schemas.IntercomWorkspace
  alias Rail.Support.Schemas.Item
  alias Rail.Support.Schemas.Message
  alias Rail.Users.Schemas.User

  @statuses [:waiting, :done]

  @primary_key {:id, UXID, autogenerate: true, prefix: "scv"}
  schema "support_conversations" do
    field :external_id, :string
    field :title, :string
    field :customer_name, :string
    field :customer_email, :string
    field :status, Ecto.Enum, values: @statuses, default: :waiting
    field :done_at, :utc_datetime_usec
    field :last_message_at, :utc_datetime_usec
    # Intercom's own `updated_at`, so an older read never overwrites a newer one.
    field :intercom_updated_at, :utc_datetime_usec
    field :reply_text, :string
    field :drafting_since, :utc_datetime_usec
    # The lock a pass holds, and the MCP token it was given while it holds it.
    field :agent_started_at, :utc_datetime_usec
    field :mcp_token_hash, :binary, redact: true
    field :agent_error, :string
    field :drafted_at, :utc_datetime_usec
    field :reply_posted_at, :utc_datetime_usec
    field :send_started_at, :utc_datetime_usec
    field :send_error, :string

    belongs_to :project, Project
    belongs_to :intercom_workspace, IntercomWorkspace
    belongs_to :reply_posted_by, User
    belongs_to :done_by, User
    has_many :messages, Message
    has_many :items, Item
    has_many :chat_messages, ChatMessage

    timestamps()
  end

  def statuses, do: @statuses

  @doc """
  The reply as the person edits it. Refused while a pass works on it or once it is posted.
  """
  def draft_changeset(conversation, attrs), do: cast(conversation, attrs, [:reply_text])

  @doc """
  Mark done: the only way a conversation reaches Done in Rail.
  """
  def done_changeset(conversation, user_id),
    do: change(conversation, status: :done, done_at: DateTime.utc_now(), done_by_id: user_id)

  @doc """
  Where a conversation the import meets for the first time starts: Done when Intercom already closed it.
  """
  def calculate_first_status("closed"), do: :done
  def calculate_first_status(_open_or_snoozed), do: :waiting

  @doc """
  Whether a customer message newer than the Mark done takes a Done conversation back to Waiting.
  """
  def reopened?(%__MODULE__{status: :done, done_at: %DateTime{} = done_at}, %DateTime{} = last_customer_at),
    do: DateTime.after?(last_customer_at, done_at)

  def reopened?(%__MODULE__{}, _last_customer_at), do: false

  def drafting?(%__MODULE__{drafting_since: since}), do: is_struct(since, DateTime)

  @doc """
  The items Send forwards: not already tracked and not forwarded yet. Needs the items preloaded.
  """
  def to_forward(%__MODULE__{items: items}), do: Enum.filter(items, &Item.forwardable?/1)

  def send_label(%__MODULE__{reply_posted_at: %DateTime{}} = conversation),
    do: "Forward #{length(to_forward(conversation))} to dev"

  def send_label(%__MODULE__{} = conversation) do
    case length(to_forward(conversation)) do
      0 -> "Send reply"
      count -> "Send reply & forward #{count} to dev"
    end
  end

  def title_or_preview(%__MODULE__{title: title}) when is_binary(title) and title != "", do: title

  def title_or_preview(%__MODULE__{messages: [%Message{text: text} | _rest]}) when is_binary(text) and text != "",
    do: String.slice(text, 0, 140)

  def title_or_preview(%__MODULE__{customer_name: name}), do: "Conversation with #{name || "a customer"}"

  @doc """
  Where a pass writes the conversation, the draft and its result, outside any repository.
  """
  def scratch_path(%__MODULE__{id: id, project_id: project_id}) do
    root = Application.get_env(:rail, :scratch_root) || Path.join(File.cwd!(), "output")
    Path.join([root, project_id, "support", id])
  end

  def worktree_path(%__MODULE__{id: id, project: %Project{clone_path: clone_path}}),
    do: Path.join(clone_path, ".worktrees/support-#{id}")
end
