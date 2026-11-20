defmodule Rail.Support.Actions.SendSupportReply do
  @moduledoc false

  import Ecto.Query

  alias Rail.Intercom
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Support.Schemas.Conversation
  alias Rail.Support.Schemas.Item
  alias Rail.Support.Schemas.Message
  alias Rail.Triage
  alias Rail.Triage.Schemas.Thread
  alias Rail.Users
  alias Rail.Users.Schemas.User

  @stale_after_minutes 2

  @doc """
  Posts the round's reply in Intercom as the person, once, then forwards the items not yet forwarded to
  triage. Returns `{:ok, conversation}`, `{:error, {:reply_failed, reason}}` before anything went out, or
  `{:error, {:forward_failed, reason}}` after the reply posted.
  """
  def send_support_reply(%Scope{user: %User{id: user_id}} = scope, %Conversation{id: id}) do
    conversation = Conversation |> Repo.get!(id) |> Repo.preload([:intercom_workspace, :items])
    # Linking or unlinking in another tab counts at once.
    {:ok, user} = Users.get_user(id: user_id)

    result =
      with :ok <- can_send(scope, user, conversation),
           {:ok, conversation} <- post_reply(user, conversation) do
        forward(%{scope | user: user}, conversation)
      end

    Phoenix.PubSub.broadcast(Rail.PubSub, "support", {:support_changed, id})
    result
  end

  defp can_send(%Scope{} = scope, %User{} = user, %Conversation{} = conversation) do
    cond do
      not Scope.can_access_project?(scope, conversation.project_id) -> {:error, :not_found}
      # Retrying only the forward posts nothing in Intercom, so it needs no link.
      is_struct(conversation.reply_posted_at, DateTime) -> :ok
      not Scope.intercom_linked?(Scope.for_user(user)) -> {:error, :intercom_not_linked}
      user.intercom_app_id != conversation.intercom_workspace.external_id -> {:error, :intercom_other_workspace}
      Conversation.drafting?(conversation) -> {:error, :drafting}
      true -> :ok
    end
  end

  defp post_reply(_user, %Conversation{reply_posted_at: %DateTime{}} = conversation), do: {:ok, conversation}

  defp post_reply(%User{} = user, %Conversation{reply_text: text} = conversation) when is_binary(text) and text != "" do
    with :ok <- claim(conversation),
         {:ok, _reply} <- deliver(user, conversation) do
      conversation =
        conversation
        |> Ecto.Changeset.change(
          reply_posted_at: DateTime.utc_now(),
          reply_posted_by_id: user.id,
          send_started_at: nil,
          send_error: nil
        )
        |> Repo.update!()

      {:ok, conversation}
    end
  end

  defp post_reply(_user, %Conversation{}), do: {:error, :no_reply}

  # A second click or tab finds the lock taken, or the reply already posted.
  defp claim(%Conversation{id: id}) do
    now = DateTime.utc_now()
    stale = DateTime.shift(now, minute: -@stale_after_minutes)

    query =
      from c in Conversation,
        where: c.id == ^id and is_nil(c.reply_posted_at) and (is_nil(c.send_started_at) or c.send_started_at < ^stale)

    case Repo.update_all(query, set: [send_started_at: now]) do
      {1, _claimed} -> :ok
      {0, _taken} -> {:error, :already_sent}
    end
  end

  defp deliver(%User{} = user, %Conversation{id: id} = conversation) do
    case Intercom.reply(
           user.intercom_access_token,
           conversation.external_id,
           user.intercom_admin_id,
           html(conversation.reply_text)
         ) do
      {:ok, reply} ->
        {:ok, reply}

      {:error, reason} ->
        Repo.update_all(from(c in Conversation, where: c.id == ^id), set: [send_started_at: nil])
        {:error, {:reply_failed, reason}}
    end
  end

  defp forward(%Scope{} = scope, %Conversation{id: id}) do
    result =
      try do
        Repo.transaction(fn ->
          locked = Repo.one!(from c in Conversation, where: c.id == ^id, lock: "FOR UPDATE")
          thread = forward_items(scope, locked)
          {locked |> Ecto.Changeset.change(send_error: nil) |> Repo.update!(), thread}
        end)
      catch
        # A forward that crashes still reaches Sentry, and the page still says the reply is out and the items are not.
        kind, reason ->
          record_forward_failed(id)
          Phoenix.PubSub.broadcast(Rail.PubSub, "support", {:support_changed, id})
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    case result do
      {:ok, {conversation, thread}} ->
        if thread, do: Phoenix.PubSub.broadcast(Rail.PubSub, "triage", {:triage_changed, thread.id})
        {:ok, conversation}

      {:error, reason} ->
        record_forward_failed(id)
        {:error, {:forward_failed, reason}}
    end
  end

  defp record_forward_failed(id) do
    Repo.update_all(from(c in Conversation, where: c.id == ^id),
      set: [send_error: "Posted the reply in Intercom, but could not forward to triage."]
    )
  end

  # Under the conversation's row lock, so two Sends never forward the same item.
  defp forward_items(%Scope{} = scope, %Conversation{id: id} = locked) do
    forwardable =
      from(i in Item,
        where: i.conversation_id == ^id and is_nil(i.existing_issue_id) and is_nil(i.forwarded_at),
        order_by: [asc: i.position, asc: i.id]
      )
      |> Repo.all()
      |> Enum.filter(&Item.forwardable?/1)

    locked =
      Repo.preload(locked, [:intercom_workspace, messages: from(m in Message, order_by: [asc: m.posted_at, asc: m.id])])

    with [_first | _rest] <- forwardable,
         {:ok, %Thread{} = thread} <- Triage.create_forwarded_thread(scope, locked, forwardable) do
      Repo.update_all(from(i in Item, where: i.id in ^Enum.map(forwardable, & &1.id)),
        set: [forwarded_at: DateTime.utc_now()]
      )

      thread
    else
      [] -> nil
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Intercom takes the body as HTML: a paragraph per blank-line break, a line break per newline.
  defp html(text) do
    text
    |> String.split(~r/\n{2,}/, trim: true)
    |> Enum.map_join(fn paragraph ->
      escaped = paragraph |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
      "<p>" <> String.replace(escaped, "\n", "<br>") <> "</p>"
    end)
  end
end
