defmodule RailWeb.SupportLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Scope
  alias Rail.Support
  alias Rail.Support.Schemas.ChatMessage
  alias Rail.Users

  @filters ["waiting", "drafting", "done"]
  # An import broadcasts once per conversation, so an open page reloads at most once a second.
  @reload_after 1_000

  @errors %{
    intercom_not_linked: "Link your Intercom account to send this as yourself.",
    intercom_other_workspace: "Your Intercom account is in another workspace than this conversation.",
    drafting: "The agent is still working on the draft.",
    already_sent: "This reply is already being sent, or was sent.",
    no_reply: "There is no reply to send.",
    not_found: "This conversation is no longer here."
  }

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Rail.PubSub, "support")
      Phoenix.PubSub.subscribe(Rail.PubSub, "intercom_workspaces")
      Phoenix.PubSub.subscribe(Rail.PubSub, "users")
    end

    socket =
      socket
      |> assign(:page_title, "Support")
      |> assign(:current_section, :support)
      |> assign(:reload_scheduled, false)

    {:ok, socket}
  end

  # Which conversation is open and which filter the queue shows are in the URL, so either can be linked to.
  def handle_params(params, _uri, socket) do
    filter = if params["filter"] in @filters, do: String.to_existing_atom(params["filter"]), else: :waiting

    socket =
      socket
      |> assign(:filter, filter)
      |> assign(:selected_id, params["id"])
      |> assign(:conversation, nil)
      |> assign(:send_error, nil)
      |> assign(:chat_form, Ecto.Changeset.change(%ChatMessage{}))
      |> load()

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_section={@current_section}
      current_scope={@current_scope}
      attention_count={@attention_count}
      triage_count={@triage_count}
      current_project_id={@current_project_id}
      projects={@projects}
      theme={@theme}
      show_project_switcher={@show_project_switcher}
      lost_backends={@lost_backends}
    >
      <div id="support-page" data-qa="support-page" class="-m-6 h-[calc(100%+3rem)] flex min-h-0">
        <.support_queue
          conversations={@conversations}
          counts={@counts}
          filter={@filter}
          selected_id={@conversation && @conversation.id}
          workspace_names={@workspace_names}
          now={@now}
        />

        <div
          :if={@conversation}
          id={"support-column-#{@conversation.id}"}
          class="flex-1 min-w-[380px] flex flex-col min-h-0 border-r border-slate-200 dark:border-slate-700"
        >
          <.support_conversation conversation={@conversation} />
          <p
            :if={@send_error}
            id="support-send-failed"
            role="alert"
            class="px-4 py-2 text-xs text-red-600 dark:text-red-400 border-t border-slate-200 dark:border-slate-700"
          >
            {@send_error}
          </p>
          <.support_draft
            conversation={@conversation}
            linked={Scope.intercom_linked?(@current_scope)}
            author_name={@author_name}
          />
        </div>

        <.support_chat :if={@conversation} conversation={@conversation} form={@chat_form} />

        <section
          :if={!@conversation}
          id="support-no-conversation"
          class="flex-1 flex items-center justify-center text-sm text-slate-500 dark:text-slate-400"
        >
          Pick a conversation from the queue.
        </section>
      </div>
    </Layouts.app>
    """
  end

  def handle_event("filter", %{"filter" => filter}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/support?#{[filter: filter]}")}

  def handle_event("update_reply", %{"conversation" => attrs}, socket) do
    result = Support.update_support_draft(socket.assigns.current_scope, socket.assigns.conversation, attrs)
    {:noreply, result(socket, result)}
  end

  def handle_event("mark_done", _params, socket) do
    result = Support.mark_support_done(socket.assigns.current_scope, socket.assigns.conversation)
    {:noreply, result(socket, result)}
  end

  def handle_event("draft", _params, socket) do
    result = Support.draft_support_reply(socket.assigns.current_scope, socket.assigns.conversation)
    {:noreply, result(socket, result)}
  end

  # What is typed in the chat stays through the reloads broadcasts bring.
  def handle_event("chat_change", %{"chat_message" => attrs}, socket),
    do: {:noreply, assign(socket, :chat_form, Ecto.Changeset.change(%ChatMessage{}, text: attrs["text"]))}

  def handle_event("chat", %{"chat_message" => attrs}, socket) do
    socket =
      case Support.send_support_chat(socket.assigns.current_scope, socket.assigns.conversation, attrs) do
        {:ok, _message} ->
          socket |> assign(:chat_form, Ecto.Changeset.change(%ChatMessage{})) |> assign(:send_error, nil) |> load()

        {:error, %Ecto.Changeset{} = changeset} ->
          assign(socket, :chat_form, changeset)

        {:error, reason} ->
          socket |> assign(:send_error, Map.get(@errors, reason, "That did not reach the agent.")) |> load()
      end

    {:noreply, socket}
  end

  # A forward that failed after the reply posted is shown from the conversation itself.
  def handle_event("send", _params, socket) do
    send_error =
      case Support.send_support_reply(socket.assigns.current_scope, socket.assigns.conversation) do
        {:ok, _conversation} ->
          nil

        {:error, {:forward_failed, _reason}} ->
          nil

        {:error, {:reply_failed, _reason}} ->
          "Intercom did not take the reply, so nothing was sent or forwarded. Try again."

        {:error, reason} ->
          Map.get(@errors, reason, "Could not send.")
      end

    socket = socket |> assign(:send_error, send_error) |> load()
    {:noreply, socket}
  end

  # Linking or unlinking Intercom in another tab changes what Send can do here.
  def handle_info({:users_changed, id}, %{assigns: %{current_scope: %Scope{user: %{id: id}}}} = socket) do
    {:ok, user} = Users.get_user(id: id)
    socket = socket |> assign(:current_scope, Scope.for_user(user)) |> load()
    {:noreply, socket}
  end

  def handle_info({:support_changed, _conversation_id}, socket), do: {:noreply, schedule_reload(socket)}
  def handle_info({:intercom_workspace_changed, _workspace_id}, socket), do: {:noreply, schedule_reload(socket)}

  def handle_info(:reload, socket) do
    socket = socket |> assign(:reload_scheduled, false) |> load()
    {:noreply, socket}
  end

  # The navigation hook and other users' changes broadcast things this page has no use for.
  def handle_info(_message, socket), do: {:noreply, socket}

  defp result(socket, {:ok, _record}), do: socket |> assign(:send_error, nil) |> load()

  defp result(socket, {:error, reason}),
    do: socket |> assign(:send_error, Map.get(@errors, reason, "That did not save.")) |> load()

  defp schedule_reload(%{assigns: %{reload_scheduled: true}} = socket), do: socket

  defp schedule_reload(socket) do
    Process.send_after(self(), :reload, @reload_after)
    assign(socket, :reload_scheduled, true)
  end

  defp load(socket) do
    scope = socket.assigns.current_scope
    project_filter = socket.assigns.project_filter
    conversations = Support.list_support_conversations(project_id: project_filter, status: socket.assigns.filter)
    # The open conversation stays open when Send or Mark done moves it to another filter.
    open_id = socket.assigns.conversation && socket.assigns.conversation.id
    selected_id = socket.assigns.selected_id || open_id || (List.first(conversations) && List.first(conversations).id)

    conversation =
      case selected_id && Support.get_support_conversation(scope, selected_id) do
        {:ok, conversation} -> conversation
        _none -> nil
      end

    socket
    |> assign(:now, DateTime.utc_now())
    |> assign(:conversations, conversations)
    |> assign(:counts, Support.count_support_conversations(project_id: project_filter))
    |> assign(:workspace_names, Enum.map(Support.list_intercom_workspaces(project_id: project_filter), & &1.name))
    |> assign(:author_name, scope.user.intercom_name || scope.user.name || scope.user.login)
    |> assign(:conversation, conversation)
  end
end
