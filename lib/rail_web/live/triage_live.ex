defmodule RailWeb.TriageLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Projects
  alias Rail.Scope
  alias Rail.Triage
  alias Rail.Triage.Schemas.ChatMessage
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread
  alias Rail.Users.Schemas.User

  on_mount {RailWeb.UserAuth, {:require_tab, :triage}}

  @filters ["waiting", "triaging", "done"]

  @errors %{
    slack_not_linked: "Connect Slack to post as yourself.",
    slack_other_workspace: "Your Slack account is in another workspace than this thread.",
    triaging: "The agent is still working on this thread.",
    already_sending: "This thread is being sent.",
    already_sent: "This reply is already posted.",
    closed: "This ticket was already sent.",
    gone: "The agent removed this card.",
    dismissed: "This thread was dismissed. Write in the chat to bring it back.",
    nothing_to_send: "There is nothing to send.",
    forwarded: "Support already answered this conversation.",
    not_found: "This thread is no longer here."
  }

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Rail.PubSub, "triage")
      Phoenix.PubSub.subscribe(Rail.PubSub, "projects")
      Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")
    end

    socket =
      socket
      |> assign(:page_title, "Triage")
      |> assign(:current_section, :triage)
      |> assign(:show_slack_link_prompt, not Scope.slack_linked?(socket.assigns.current_scope))

    {:ok, socket}
  end

  # Which thread is open and which status the queue shows are in the URL, so either can be linked to.
  def handle_params(params, _uri, socket) do
    filter = if params["filter"] in @filters, do: String.to_existing_atom(params["filter"]), else: :waiting

    socket =
      socket
      |> assign(:filter, filter)
      |> assign(:selected_id, params["id"])
      |> assign(:thread, nil)
      |> assign(:panel, "chat")
      |> assign(:error, nil)
      |> assign(:chat_form, Ecto.Changeset.change(%ChatMessage{}))
      |> assign(:open_image, nil)
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
      support_count={@support_count}
      current_project_id={@current_project_id}
      projects={@projects}
      theme={@theme}
      show_project_switcher={@show_project_switcher}
      lost_backends={@lost_backends}
    >
      <div id="triage-page" data-qa="triage-page" class="-m-6 h-[calc(100%+3rem)] flex min-h-0">
        <.triage_queue
          threads={@threads}
          counts={@counts}
          filter={@filter}
          selected_id={@thread && @thread.id}
          channel_names={@channel_names}
          now={@now}
        />

        <section
          :if={@thread}
          id={"triage-draft-column-#{@thread.id}"}
          class="flex-1 min-w-[320px] flex flex-col min-h-0 border-r border-slate-200 dark:border-slate-700"
        >
          <div class="px-6 py-3 border-b border-slate-200 dark:border-slate-700">
            <div class="flex items-center gap-2 min-w-0 text-xs text-slate-500 dark:text-slate-400">
              <.project_badge project={@thread.project} />
              <span id="triage-source" class="font-mono truncate">{@source_line}</span>
            </div>
            <h2
              id="triage-thread-title"
              title={Thread.title_or_preview(@thread)}
              class="mt-1 text-lg font-bold leading-snug truncate text-slate-900 dark:text-slate-100"
            >
              {Thread.title_or_preview(@thread)}
            </h2>
          </div>
          <div class="flex-1 overflow-y-auto px-6 py-4 space-y-4">
            <.triage_reply thread={@thread} author_name={@author_name} locked={@locked} />
            <p
              :if={@thread.items != []}
              id="triage-tickets-line"
              class="text-[11px] font-extrabold uppercase tracking-wider text-slate-500 dark:text-slate-400"
            >
              {@tickets_line}
            </p>
            <.triage_ticket :for={item <- @thread.items} item={item} locked={@locked} />
          </div>
          <.triage_send_bar thread={@thread} slack_linked={!@show_slack_link_prompt} error={@error} />
        </section>

        <.agent_chat
          :if={@thread && @panel == "chat"}
          id="triage-chat"
          key={@thread.id}
          lines={@thread.chat_messages}
          running={@running}
          form={@chat_form}
          empty="The agent reads the thread, the code and the tickets. Ask it to change the reply or the tickets, or why it reached a verdict."
          placeholder="Ask the agent to change the reply or the tickets"
          gone_author="A teammate"
          class="w-[400px] max-xl:w-[260px] shrink-0"
        >
          <:header>
            <.segmented_control
              id="triage-panel"
              options={@panel_options}
              selected={@panel}
              event="show_panel"
              value_name="panel"
              aria-label="Right panel"
            />
          </:header>
        </.agent_chat>

        <aside
          :if={@thread && @panel == "thread"}
          id="triage-thread-panel"
          class="w-[400px] max-xl:w-[260px] shrink-0 flex flex-col min-h-0"
        >
          <div class="px-4 py-3 border-b border-slate-200 dark:border-slate-700 flex items-center gap-2">
            <.segmented_control
              id="triage-panel"
              options={@panel_options}
              selected={@panel}
              event="show_panel"
              value_name="panel"
              aria-label="Right panel"
            />
          </div>
          <.triage_thread thread={@thread} />
        </aside>
      </div>
    </Layouts.app>

    <.triage_image_view
      :if={@open_image}
      message_id={@open_image.message_id}
      image={@open_image.image}
      position={@open_image.position}
      count={@open_image.count}
    />
    """
  end

  def handle_event("filter", %{"filter" => filter}, socket) do
    {:noreply, push_patch(socket, to: ~p"/triage?#{[filter: filter]}")}
  end

  def handle_event("show_panel", %{"panel" => panel}, socket) when panel in ["chat", "thread"],
    do: {:noreply, assign(socket, :panel, panel)}

  def handle_event("update_reply", %{"thread" => attrs}, socket) do
    result = Triage.update_triage_reply(socket.assigns.current_scope, socket.assigns.thread, attrs)
    {:noreply, result(socket, result)}
  end

  def handle_event("update_item", %{"item_id" => item_id, "item" => attrs}, socket) do
    {:noreply, on_item(socket, item_id, &Triage.update_triage_item(socket.assigns.current_scope, &1, attrs))}
  end

  def handle_event("toggle_ignore", %{"item_id" => item_id}, socket) do
    scope = socket.assigns.current_scope
    {:noreply, on_item(socket, item_id, &Triage.update_triage_item(scope, &1, %{"ignored" => not &1.ignored}))}
  end

  # What is typed in the chat stays through the reloads broadcasts bring.
  def handle_event("chat_change", %{"chat_message" => attrs}, socket),
    do: {:noreply, assign(socket, :chat_form, Ecto.Changeset.change(%ChatMessage{}, text: attrs["text"]))}

  # A reconnect while the agent works recovers the disabled chat box with no text: nothing changed.
  def handle_event("chat_change", _params, socket), do: {:noreply, socket}

  def handle_event("chat", %{"chat_message" => attrs}, socket) do
    socket =
      case Triage.send_triage_chat(socket.assigns.current_scope, socket.assigns.thread, attrs) do
        {:ok, _line} ->
          socket |> assign(:chat_form, Ecto.Changeset.change(%ChatMessage{})) |> assign(:error, nil) |> load()

        {:error, %Ecto.Changeset{} = changeset} ->
          assign(socket, :chat_form, changeset)

        {:error, reason} ->
          socket |> assign(:error, error_message(reason)) |> load()
      end

    {:noreply, socket}
  end

  # A failure partway is saved on the thread, so every tab shows it; only a refusal is this page's own.
  def handle_event("send", _params, socket) do
    error =
      case Triage.send_triage_reply(socket.assigns.current_scope, socket.assigns.thread) do
        {:ok, _thread} -> nil
        {:error, {:not_created, _positions}} -> nil
        {:error, {:not_updated, _positions}} -> nil
        {:error, {:reply_failed, _reason}} -> nil
        {:error, reason} -> error_message(reason)
      end

    socket = socket |> assign(:error, error) |> load()
    {:noreply, socket}
  end

  def handle_event("dismiss_thread", _params, socket) do
    {:ok, _thread} = Triage.dismiss_triage_thread(socket.assigns.current_scope, socket.assigns.thread)
    {:noreply, load(socket)}
  end

  def handle_event("open_image", %{"message_id" => message_id, "file_id" => file_id}, socket) do
    {:noreply, assign(socket, :open_image, resolve_image(socket.assigns.thread, message_id, file_id, 0))}
  end

  def handle_event("step_image", %{"direction" => "next"}, socket), do: {:noreply, step_image(socket, 1)}
  def handle_event("step_image", %{"direction" => "previous"}, socket), do: {:noreply, step_image(socket, -1)}
  def handle_event("image_key", %{"key" => "ArrowRight"}, socket), do: {:noreply, step_image(socket, 1)}
  def handle_event("image_key", %{"key" => "ArrowLeft"}, socket), do: {:noreply, step_image(socket, -1)}
  def handle_event("image_key", _other_key, socket), do: {:noreply, socket}

  def handle_event("close_image", _params, socket), do: {:noreply, assign(socket, :open_image, nil)}

  # A refusal goes once what it described changed, such as another tab's Send ending or a pass finishing.
  def handle_info({:triage_changed, thread_id}, socket) do
    before = socket.assigns.thread
    socket = load(socket)
    now = socket.assigns.thread

    if match?(%Thread{id: ^thread_id}, before) and match?(%Thread{id: ^thread_id}, now) and
         refusal_basis(before) != refusal_basis(now),
       do: {:noreply, assign(socket, :error, nil)},
       else: {:noreply, socket}
  end

  # A project's name and its channels' switches show on the open thread.
  def handle_info({:project_changed, _project_id}, socket), do: {:noreply, load(socket)}

  # A task started from an issue page, or one changing stage, shows on the item that created its issue.
  def handle_info({:pipeline_changed, _task_id}, socket), do: {:noreply, load(socket)}

  # The navigation hook and the issue dialog broadcast things this page has no use for.
  def handle_info(_message, socket), do: {:noreply, socket}

  # A card a pass removed while its change was in flight is simply gone after the reload.
  defp on_item(socket, item_id, action) do
    case Enum.find(socket.assigns.thread.items, &(&1.id == item_id)) do
      %Item{} = item -> result(socket, action.(item))
      nil -> load(socket)
    end
  end

  defp result(socket, {:ok, _record}), do: socket |> assign(:error, nil) |> load()
  defp result(socket, {:error, reason}), do: socket |> assign(:error, error_message(reason)) |> load()

  defp refusal_basis(%Thread{} = thread), do: {thread.status, Thread.sending?(thread)}

  defp load(socket) do
    scope = socket.assigns.current_scope
    project_id = socket.assigns.current_project_id
    project_filter = socket.assigns.project_filter
    threads = Triage.list_triage_threads(project_id: project_filter, status: socket.assigns.filter, limit: 100)
    # The open thread stays open when a Send moves it to another status.
    open_id = socket.assigns.thread && socket.assigns.thread.id
    selected_id = socket.assigns.selected_id || open_id || (List.first(threads) && List.first(threads).id)

    thread =
      case selected_id && Triage.get_triage_thread(scope, selected_id) do
        {:ok, %Thread{} = thread} -> thread
        _none -> nil
      end

    open = socket.assigns.open_image
    user = scope.user

    socket
    |> assign(:now, DateTime.utc_now())
    |> assign(:threads, threads)
    |> assign(:counts, Triage.count_triage_threads(project_id: project_filter))
    |> assign(:triage_count, Triage.count_triage_threads(project_id: Scope.project_ids(scope)).waiting)
    |> assign(:channel_names, channel_names(socket.assigns.projects, project_id))
    |> assign(:author_name, user.slack_name || user.name || user.login)
    |> assign_thread(thread)
    |> assign(:open_image, open && resolve_image(thread, open.message_id, open.image.external_id, 0))
  end

  defp assign_thread(socket, nil), do: socket |> assign(:thread, nil) |> assign(:running, false) |> assign(:locked, false)

  defp assign_thread(socket, %Thread{} = thread) do
    running = thread.status == :triaging

    socket
    |> assign(:thread, thread)
    |> assign(:running, running)
    |> assign(:locked, running or is_struct(thread.dismissed_at, DateTime))
    |> assign(:panel_options, [{"chat", "Chat"}, {"thread", panel_label(thread)}])
    |> assign(:source_line, calculate_source_line(thread))
    |> assign(:tickets_line, calculate_tickets_line(thread))
  end

  defp step_image(%{assigns: %{open_image: %{message_id: message_id, image: image}}} = socket, step),
    do: assign(socket, :open_image, resolve_image(socket.assigns.thread, message_id, image.external_id, step))

  defp step_image(socket, _step), do: socket

  # Opening, stepping and every reload go through here: only files with an address count,
  # a step never leaves the message or runs past either end, and a file that is gone closes the view.
  defp resolve_image(nil, _message_id, _file_id, _step), do: nil

  defp resolve_image(%Thread{messages: messages}, message_id, file_id, step) do
    images =
      messages
      |> Enum.find(%Message{}, &(&1.id == message_id))
      |> Map.fetch!(:images)
      |> Enum.filter(&is_binary(&1.url))

    index = Enum.find_index(images, &(&1.external_id == file_id))
    index = if index && (index + step) in 0..(length(images) - 1)//1, do: index + step, else: index

    if index, do: %{message_id: message_id, image: Enum.at(images, index), position: index + 1, count: length(images)}
  end

  defp panel_label(%Thread{messages: messages} = thread),
    do: "#{if Thread.forwarded?(thread), do: "Conversation", else: "Thread"} · #{length(messages)}"

  # "#rail-feedback · Priya Raman, Marcus Lee", or "Intercom · forwarded by Jo Park".
  defp calculate_source_line(%Thread{forwarded_by: forwarded_by} = thread) when is_struct(forwarded_by, User),
    do: "#{Thread.source_label(thread)} · forwarded by #{forwarded_by.name || forwarded_by.login}"

  defp calculate_source_line(%Thread{support_conversation_id: id} = thread) when is_binary(id),
    do: "#{Thread.source_label(thread)} · forwarded by support"

  defp calculate_source_line(%Thread{messages: messages} = thread) do
    authors = messages |> Enum.reject(&Message.via_rail?/1) |> Enum.map(& &1.author_name) |> Enum.uniq()
    Enum.join([Thread.source_label(thread) | if(authors == [], do: [], else: [Enum.join(authors, ", ")])], " · ")
  end

  # "Tickets · 2 to create · 1 follow-up · 1 ignored"
  defp calculate_tickets_line(%Thread{items: items} = thread) do
    updates = length(Thread.to_update(thread))
    ignored = Enum.count(items, & &1.ignored)

    parts =
      Enum.reject(
        [
          "#{length(Thread.to_create(thread))} to create",
          updates > 0 && "#{updates} #{if updates == 1, do: "follow-up", else: "follow-ups"}",
          ignored > 0 && "#{ignored} ignored"
        ],
        &(&1 == false)
      )

    Enum.join(["Tickets" | parts], " · ")
  end

  defp channel_names(projects, project_id) do
    projects
    |> Enum.filter(&(is_nil(project_id) or &1.id == project_id))
    |> Projects.list_slack_channels()
    |> Enum.map(& &1.name)
  end

  defp error_message(%Ecto.Changeset{}), do: "That did not save."
  defp error_message(reason), do: Map.get_lazy(@errors, reason, fn -> "That did not work: #{inspect(reason)}" end)
end
