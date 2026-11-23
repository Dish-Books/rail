defmodule Rail.Support.Actions.SendSupportMessage do
  @moduledoc false

  import Rail.Support.Utils.CalculateIntercomHtml
  import Rail.Support.Utils.MirrorIntercomConversation
  import Rail.Support.Utils.VerifyIntercomSender

  alias Rail.Intercom
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Support.Schemas.Conversation
  alias Rail.Users
  alias Rail.Users.Schemas.User

  @doc """
  Posts what the person wrote in Intercom as them, at any time: before a draft, while the agent drafts, or after
  the reply went out. The draft, what it forwards and the conversation's status stay as they are. Returns
  `{:ok, conversation}`, or `{:error, {:message_failed, reason}}` when Intercom did not take it.
  """
  def send_support_message(%Scope{user: %User{id: user_id}} = scope, %Conversation{id: id}, text) do
    conversation = Conversation |> Repo.get!(id) |> Repo.preload(:intercom_workspace)
    # Linking or unlinking in another tab counts at once.
    {:ok, user} = Users.get_user(id: user_id)
    text = if is_binary(text), do: text |> String.replace("\r\n", "\n") |> String.trim(), else: ""

    cond do
      not Scope.can_access_project?(scope, conversation.project_id) ->
        {:error, :not_found}

      text == "" ->
        {:error, :no_message}

      true ->
        with :ok <- verify_intercom_sender(user, conversation.intercom_workspace),
             {:ok, reply} <- post(user, conversation, text) do
          # Intercom answers with the conversation as it now stands, so the message shows at once.
          # An answer without it waits for Intercom's notice of the reply instead.
          with %{"updated_at" => updated_at} when is_integer(updated_at) <- reply do
            workspace = conversation.intercom_workspace
            {:ok, _mirrored} = mirror_intercom_conversation(workspace, Map.put(reply, "id", conversation.external_id), [])
          end

          Phoenix.PubSub.broadcast(Rail.PubSub, "support", {:support_changed, id})
          {:ok, Repo.get!(Conversation, id)}
        end
    end
  end

  defp post(%User{} = user, %Conversation{} = conversation, text) do
    case Intercom.reply(
           user.intercom_access_token,
           conversation.external_id,
           user.intercom_admin_id,
           calculate_intercom_html(text)
         ) do
      {:ok, reply} -> {:ok, reply}
      {:error, reason} -> {:error, {:message_failed, reason}}
    end
  end
end
