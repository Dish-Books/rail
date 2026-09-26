defmodule RailWeb.TriageLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Projects
  alias Rail.Scope
  alias Rail.Triage
  alias Rail.Triage.Schemas.Correction
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Thread

  @filters ["waiting", "triaging", "done"]

  @errors %{
    slack_not_linked: "Connect Slack to post as yourself.",
    slack_other_workspace: "Your Slack account is in another workspace than this thread.",
    already_tracked: "An existing issue already tracks this.",
    already_created: "Someone already accepted this.",
    already_posted: "Someone already accepted this.",
    locked: "This item is being triaged again, so it cannot change yet.",
    needs_issue_link: "This reply links the issue, so create the issue first.",
    no_reply: "There is no reply to post.",
    settled: "This item is settled and closed to corrections."
  }

  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Rail.PubSub, "triage")

    socket =
      socket
      |> assign(:page_title, "Triage")
      |> assign(:current_section, :triage)
      |> assign(:show_slack_link_prompt, not Scope.slack_linked?(socket.assigns.current_scope))
      |> assign(:item_errors, %{})
      |> assign(:correction, Ecto.Changeset.change(%Correction{}))

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
      |> assign(:item_errors, %{})
      |> assign(:correction, Ecto.Changeset.change(%Correction{}))
      |> load()

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_section={@current_section}
      current_scope={@current_scope}
      is_rail_extended={@is_rail_extended}
      attention_count={@attention_count}
      triage_count={@triage_count}
      current_project_id={@current_project_id}
      projects={@projects}
      theme={@theme}
      show_project_switcher={@show_project_switcher}
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

        <.triage_thread
          :if={@thread}
          thread={@thread}
          current_user_id={@current_scope.user.id}
          correction={@correction}
        />

        <section :if={@thread} id="triage-items" class="flex-1 min-w-0 flex flex-col min-h-0">
          <div class="flex items-center gap-3 px-6 py-3 border-b border-slate-200 dark:border-slate-700">
            <span class="text-sm font-bold text-slate-900 dark:text-slate-100">
              {length(@thread.items)} {if length(@thread.items) == 1, do: "item", else: "items"}
            </span>
            <span class="inline-flex items-center gap-1 text-xs text-slate-500 dark:text-slate-400">
              <.icon name="pi-lock-simple" class="size-3" />
              Nothing reaches Slack or Linear until you accept it.
            </span>
            <.button
              :if={@show_dismiss}
              size="sm"
              phx-click="dismiss_thread"
              id="dismiss-thread-button"
              class="ml-auto"
            >
              Dismiss thread
            </.button>
          </div>

          <div class="flex-1 overflow-y-auto px-5 py-4 space-y-3">
            <div
              :if={@thread.error}
              id="triage-error"
              class="rounded-xl border border-red-300 dark:border-red-800 bg-red-50 dark:bg-red-950/30 px-5 py-4 space-y-2"
            >
              <p class="flex items-center gap-2 text-sm font-semibold text-red-800 dark:text-red-200">
                <.icon name="pi-warning-circle" class="size-4" />Triage did not finish
              </p>
              <p class="text-[13px] text-red-800 dark:text-red-200">{@thread.error}</p>
              <div class="flex justify-end">
                <.button size="sm" phx-click="retriage" id="triage-again-button">Triage again</.button>
              </div>
            </div>

            <div
              :if={@show_triaging}
              id="triage-running"
              class="flex items-center gap-2.5 px-4 py-2.5 rounded-xl border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/40 text-[12.5px]"
            >
              <span class="relative flex size-2">
                <span class="absolute inline-flex size-full rounded-full bg-blue-400 opacity-75 animate-ping"></span>
                <span class="relative size-2 rounded-full bg-blue-500"></span>
              </span>
              <span class="font-semibold text-slate-900 dark:text-slate-100">
                Rail is reading this thread against the code.
              </span>
            </div>

            <div
              :if={@show_no_response}
              id="triage-no-response"
              class="rounded-xl border border-slate-200 dark:border-slate-700 px-5 py-4 space-y-2"
            >
              <p class="flex items-center gap-2 text-sm font-semibold text-slate-900 dark:text-slate-100">
                <.icon name="pi-minus-circle" class="size-4 text-slate-400" />Needed no response
              </p>
              <p class="text-[13px] text-slate-700 dark:text-slate-300">
                Rail read this as: {@thread.no_response_reason}. It asks nothing of the product and reports nothing, so nothing was drafted and it never waited on you.
              </p>
              <div class="flex items-center gap-2 pt-1">
                <span class="text-xs text-slate-500 dark:text-slate-400">If Rail got this wrong:</span>
                <.button size="sm" phx-click="retriage" id="triage-anyway-button" class="ml-auto">
                  Triage anyway
                </.button>
              </div>
            </div>

            <.triage_item
              :for={item <- @thread.items}
              item={item}
              form={Map.fetch!(@item_forms, item.id)}
              slack_linked={!@show_slack_link_prompt}
              current_user_id={@current_scope.user.id}
              project_name={@thread.project.name}
              corrected_by={Map.get(@corrected_by, item.id)}
              error={Map.get(@item_errors, item.id)}
            />
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  def handle_event("filter", %{"filter" => filter}, socket) do
    {:noreply, push_patch(socket, to: ~p"/triage?#{[filter: filter]}")}
  end

  def handle_event("update_draft", %{"item_id" => item_id, "item" => attrs}, socket) do
    {:noreply, accept(socket, item_id, &Triage.update_triage_draft(socket.assigns.current_scope, &1, attrs))}
  end

  def handle_event("create_issue", %{"item_id" => item_id, "item" => attrs}, socket) do
    {:noreply, accept(socket, item_id, &Triage.create_triage_issue(socket.assigns.current_scope, &1, attrs))}
  end

  def handle_event("post_reply", %{"item_id" => item_id, "item" => attrs}, socket) do
    {:noreply, accept(socket, item_id, &Triage.post_triage_reply(socket.assigns.current_scope, &1, attrs))}
  end

  def handle_event("pick_correction", %{"item_id" => item_id} = params, socket) do
    correction = Ecto.Changeset.change(%Correction{}, item_id: item_id, assumption: params["assumption"])
    {:noreply, assign(socket, :correction, correction)}
  end

  def handle_event("change_correction", %{"correction" => attrs}, socket) do
    correction =
      Ecto.Changeset.change(%Correction{},
        item_id: attrs["item_id"],
        assumption: attrs["assumption"],
        text: attrs["text"]
      )

    {:noreply, assign(socket, :correction, correction)}
  end

  def handle_event("send_correction", %{"correction" => %{"item_id" => item_id} = attrs}, socket) do
    item = Enum.find(socket.assigns.thread.items, &(&1.id == item_id))

    case Triage.correct_triage_item(socket.assigns.current_scope, item, attrs) do
      {:ok, _correction} ->
        socket = socket |> assign(:correction, Ecto.Changeset.change(%Correction{})) |> load()
        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :correction, changeset)}

      {:error, reason} ->
        {:noreply, assign(socket, :item_errors, %{item_id => error_message(reason)})}
    end
  end

  def handle_event("dismiss_thread", _params, socket) do
    {:ok, _thread} = Triage.dismiss_triage_thread(socket.assigns.current_scope, socket.assigns.thread)
    {:noreply, load(socket)}
  end

  def handle_event("retriage", _params, socket) do
    {:ok, _thread} = Triage.retriage_thread(socket.assigns.current_scope, socket.assigns.thread)
    {:noreply, load(socket)}
  end

  def handle_info({:triage_changed, _thread_id}, socket), do: {:noreply, load(socket)}

  # The navigation hook and the issue dialog broadcast things this page has no use for.
  def handle_info(_message, socket), do: {:noreply, socket}

  defp accept(socket, item_id, action) do
    item = Enum.find(socket.assigns.thread.items, &(&1.id == item_id))

    case action.(item) do
      {:ok, _item} ->
        socket |> assign(:item_errors, Map.delete(socket.assigns.item_errors, item_id)) |> load()

      {:error, reason} ->
        assign(socket, :item_errors, Map.put(socket.assigns.item_errors, item_id, error_message(reason)))
    end
  end

  defp load(socket) do
    scope = socket.assigns.current_scope
    project_id = socket.assigns.current_project_id
    threads = Triage.list_triage_threads(project_id: project_id, status: socket.assigns.filter)
    # The open thread stays open when an accept moves it to another status.
    open_id = socket.assigns.thread && socket.assigns.thread.id
    selected_id = socket.assigns.selected_id || open_id || (List.first(threads) && List.first(threads).id)

    thread =
      case selected_id && Triage.get_triage_thread(scope, selected_id) do
        {:ok, %Thread{} = thread} -> thread
        _none -> nil
      end

    socket
    |> assign(:now, DateTime.utc_now())
    |> assign(:threads, threads)
    |> assign(:counts, Triage.count_triage_threads(project_id: project_id))
    |> assign(:triage_count, Triage.count_triage_threads([]).waiting)
    |> assign(:channel_names, channel_names(socket.assigns.projects, project_id))
    |> assign(:thread, thread)
    |> assign(:item_forms, item_forms(thread))
    |> assign(:corrected_by, corrected_by(thread, scope.user.id))
    |> assign(:show_dismiss, thread != nil and thread.status != :done)
    |> assign(:show_triaging, thread != nil and thread.status == :triaging and thread.items == [])
    |> assign(:show_no_response, show_no_response?(thread))
  end

  defp show_no_response?(%Thread{items: [], error: nil, no_response_reason: reason}), do: is_binary(reason)
  defp show_no_response?(_thread), do: false

  defp item_forms(nil), do: %{}
  defp item_forms(%Thread{items: items}), do: Map.new(items, &{&1.id, Item.draft_changeset(&1, %{}, nil)})

  defp corrected_by(nil, _user_id), do: %{}

  defp corrected_by(%Thread{corrections: corrections}, user_id) do
    Map.new(corrections, fn correction ->
      {correction.item_id, if(correction.user_id == user_id, do: "you", else: correction.user && correction.user.name)}
    end)
  end

  defp channel_names(projects, project_id) do
    projects
    |> Enum.filter(&(is_nil(project_id) or &1.id == project_id))
    |> Enum.flat_map(&Projects.list_slack_channels/1)
    |> Enum.map(& &1.name)
  end

  defp error_message(reason), do: Map.get_lazy(@errors, reason, fn -> "That did not work: #{inspect(reason)}" end)
end
