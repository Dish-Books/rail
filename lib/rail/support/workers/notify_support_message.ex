defmodule Rail.Support.Workers.NotifySupportMessage do
  @moduledoc """
  Sends each teammate who turned support messages on one Slack direct message for a customer's message. The first job
  queues one job per person, so a message Slack refuses retries for that person alone.
  """
  use Oban.Worker, queue: :support, max_attempts: 3, unique: [period: :infinity]

  import Ecto.Query

  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Slack
  alias Rail.Support.Schemas.Conversation
  alias Rail.Support.Schemas.Message
  alias Rail.Users
  alias Rail.Users.Schemas.User

  @excerpt_length 200

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"conversation_id" => id, "external_id" => external_id, "user_id" => user_id}}) do
    with %Conversation{} = conversation <- Repo.get(Conversation, id),
         %Message{kind: :customer} = message <- Repo.get_by(Message, conversation_id: id, external_id: external_id),
         {:ok, %User{} = user} <- Users.get_user(id: user_id),
         true <- subscribed?(user, conversation.project_id),
         {:ok, workspace} <- Projects.get_slack_workspace(external_id: user.slack_team_id) do
      {:ok, _ts} = Slack.post_channel_message(workspace, user.slack_user_id, text(conversation, message))
      :ok
    else
      _gone_or_not_subscribed -> :ok
    end
  end

  def perform(%Oban.Job{args: %{"conversation_id" => id, "external_id" => external_id}}) do
    with %Conversation{project_id: project_id} <- Repo.get(Conversation, id) do
      {:ok, users} = Users.list_users(Scope.for_system())

      users
      |> Enum.filter(&subscribed?(&1, project_id))
      |> Enum.map(&new(%{"conversation_id" => id, "external_id" => external_id, "user_id" => &1.id}))
      |> Oban.insert_all()
    end

    :ok
  end

  # Read when each job runs, so turning it off, unlinking Slack, a role change or losing the project stops what was queued.
  defp subscribed?(%User{} = user, project_id) do
    scope = Scope.for_user(user)

    user.slack_support_notifications and is_nil(user.removed_at) and is_binary(user.slack_user_id) and
      is_binary(user.slack_team_id) and Users.can?(scope, :support, :view) and
      Scope.can_access_project?(scope, project_id)
  end

  defp text(%Conversation{} = conversation, %Message{} = message) do
    # The first message, as the Support queue preloads it, so an untitled conversation reads the same in both places.
    first = from(m in Message, order_by: [asc: m.posted_at, asc: m.id], limit: 1)
    title = conversation |> Repo.preload(messages: first) |> Conversation.title_or_preview()
    link = "<#{RailWeb.Endpoint.url()}/support/#{conversation.id}|#{escape(title)}>"

    case message.text |> String.split() |> Enum.join(" ") do
      "" -> link <> "\n>*#{escape(message.author_name)}* sent an attachment."
      said -> link <> "\n>*#{escape(message.author_name)}*: " <> escape(excerpt(said))
    end
  end

  defp excerpt(said) do
    if String.length(said) > @excerpt_length, do: String.slice(said, 0, @excerpt_length) <> "…", else: said
  end

  # Slack reads these three as markup in a message's text.
  defp escape(text),
    do: text |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;")
end
