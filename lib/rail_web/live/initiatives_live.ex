defmodule RailWeb.InitiativesLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Initiatives
  alias Rail.Initiatives.Schemas.Initiative

  @sorts %{"expected" => :expected, "name" => :name, "progress" => :progress}
  @columns "grid grid-cols-[minmax(0,1fr)_120px_96px_170px] xl:grid-cols-[minmax(0,1fr)_200px_96px_170px] gap-6 items-center px-4"

  on_mount {RailWeb.UserAuth, {:require_tab, :issues}}
  on_mount {RailWeb.UserAuth, :require_github}

  def mount(_params, _session, socket) do
    # "issues" too: a ticket joining an initiative or changing status moves its progress.
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Rail.PubSub, "initiatives")
      Phoenix.PubSub.subscribe(Rail.PubSub, "issues")
    end

    # The navigation only selects a project it lists, so the selection is always one of these.
    project = Enum.find(socket.assigns.projects, &(&1.id == socket.assigns.current_project_id))

    socket =
      socket
      |> assign(:page_title, "Initiatives")
      |> assign(:current_section, :initiatives)
      |> assign(:current_project, project)
      |> assign(:project_options, for(p <- socket.assigns.projects, p.active, do: {"#{p.name} (#{p.key})", p.id}))
      |> assign(:columns, @columns)
      |> assign(:form, nil)

    {:ok, socket}
  end

  # The order is in the URL, so it survives a reload and can be linked to.
  def handle_params(params, _uri, socket) do
    socket = socket |> assign(:sort, Map.get(@sorts, params["sort"], :expected)) |> load_initiatives()
    {:noreply, socket}
  end

  def render(assigns) do
    assigns =
      assigns
      |> assign(:show_form, assigns.form != nil)
      |> assign(:show_project_select, is_nil(assigns.current_project))
      |> assign(:errors, form_errors(assigns.form))
      |> assign(:show_empty, assigns.initiatives == [])
      |> assign(:empty_scope, if(assigns.current_project, do: assigns.current_project.name, else: "your projects"))

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
      <div id="initiatives-view" class="space-y-6">
        <div class="flex items-center justify-between gap-4 flex-wrap">
          <div class="min-w-0">
            <h1 class="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100">
              Initiatives
            </h1>
            <p
              id="initiatives-subtitle"
              class="text-xs text-slate-500 dark:text-slate-400 mt-1 truncate"
            >
              {if @current_project, do: @current_project.name, else: "Initiatives across all projects"}
            </p>
          </div>
          <button
            :if={!@show_form}
            type="button"
            id="new-initiative-button"
            phx-click="open_new"
            class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-blue-600 dark:bg-blue-500 text-white text-xs font-semibold hover:opacity-90 shadow-xs cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
          >
            <.icon name="pi-plus-circle-fill" class="h-4 w-4" />New initiative
          </button>
        </div>

        <.form
          :if={@show_form}
          for={@form}
          id="new-initiative-form"
          phx-change="change_new"
          phx-submit="create"
          phx-window-keydown="cancel_new"
          phx-key="Escape"
          class="rounded-xl border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/40 p-4 flex flex-wrap items-start gap-3"
        >
          <.input
            id="new-initiative-name"
            name="initiative[name]"
            label="Name"
            size="small"
            value={Ecto.Changeset.get_field(@form, :name)}
            errors={List.wrap(@errors[:name])}
            maxlength="200"
            autocomplete="off"
            phx-mounted={JS.focus()}
            container_class="flex-1 min-w-[240px] space-y-1"
          />
          <.input
            :if={@show_project_select}
            id="new-initiative-project"
            name="initiative[project_id]"
            type="select"
            label="Project"
            size="small"
            options={@project_options}
            value={@form.params["project_id"]}
            container_class="w-52 space-y-1"
          />
          <.input
            id="new-initiative-expected"
            name="initiative[expected_on]"
            type="date"
            label="Expected date (optional)"
            size="small"
            value={Ecto.Changeset.get_field(@form, :expected_on)}
            errors={List.wrap(@errors[:expected_on])}
            container_class="w-48 space-y-1"
          />
          <div class="flex gap-2 self-end pb-px">
            <button
              type="submit"
              id="create-initiative"
              phx-disable-with="Creating..."
              class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-blue-600 dark:bg-blue-500 text-white text-xs font-semibold hover:opacity-90 shadow-xs cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
            >
              <.icon name="pi-plus-circle-fill" class="h-4 w-4" />Create initiative
            </button>
            <button
              type="button"
              id="cancel-new-initiative"
              phx-click="cancel_new"
              class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg border border-slate-300 dark:border-slate-600 bg-slate-100 dark:bg-slate-700 text-xs font-semibold hover:bg-slate-200 dark:hover:bg-slate-600 cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
            >
              <.icon name="pi-x" class="h-3.5 w-3.5" />Cancel
            </button>
          </div>
        </.form>

        <div
          :if={@show_empty}
          id="initiatives-empty"
          class="rounded-xl border border-dashed border-slate-300 dark:border-slate-700 px-6 py-16 text-center space-y-2"
        >
          <.icon name="pi-flag-banner" class="h-7 w-7 text-slate-400" />
          <p class="text-sm font-semibold text-slate-900 dark:text-slate-100 break-words">
            No initiatives in {@empty_scope} yet
          </p>
          <p class="text-xs text-slate-500 dark:text-slate-400">
            An initiative groups tickets across cycles, with notes, progress and update briefs.
          </p>
        </div>

        <div
          :if={!@show_empty}
          id="initiatives-list"
          class="rounded-xl border border-slate-200 dark:border-slate-700 overflow-x-auto"
        >
          <div class="min-w-[720px] divide-y divide-slate-200 dark:divide-slate-800">
            <div class={[
              @columns,
              "h-9 bg-slate-50 dark:bg-slate-800/60 text-xs font-medium text-slate-500 dark:text-slate-400"
            ]}>
              <.sort_header sort={@sort} by={:name} label="Name" />
              <.sort_header sort={@sort} by={:progress} label="Progress" />
              <span>Tickets</span>
              <.sort_header sort={@sort} by={:expected} label="Expected" />
            </div>
            <.link
              :for={initiative <- @initiatives}
              navigate={~p"/initiatives/#{initiative.id}"}
              id={"initiative-#{initiative.id}"}
              class={[
                @columns,
                "h-14 hover:bg-slate-50 dark:hover:bg-slate-800/60 focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-blue-500"
              ]}
            >
              <span class="min-w-0 flex items-center gap-2.5">
                <.project_badge project={initiative.project} />
                <.icon name="pi-flag-banner" class="h-4 w-4 shrink-0 text-slate-400" />
                <span
                  class="truncate text-sm font-medium text-slate-900 dark:text-slate-100"
                  title={initiative.name}
                >
                  {initiative.name}
                </span>
              </span>
              <span class="flex items-center gap-3">
                <.progress_bar percent={Initiative.calculate_percent(initiative)} />
                <span class="w-9 shrink-0 text-right text-xs font-semibold text-slate-900 dark:text-slate-100">
                  {Initiative.calculate_percent(initiative)}%
                </span>
              </span>
              <span class="text-xs text-slate-500 dark:text-slate-400 whitespace-nowrap">
                {initiative.done_count} of {initiative.ticket_count} tickets
              </span>
              <span><.due_label initiative={initiative} today={@today} /></span>
            </.link>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def handle_event("open_new", _params, socket) do
    socket = assign(socket, :form, Initiative.changeset(%Initiative{}, %{}))
    {:noreply, socket}
  end

  def handle_event("change_new", %{"initiative" => params}, socket),
    do: {:noreply, assign(socket, :form, Initiative.changeset(%Initiative{}, params))}

  def handle_event("cancel_new", _params, socket), do: {:noreply, assign(socket, :form, nil)}

  # With All projects, the form's select names one of the scope's projects; anything else is refused.
  def handle_event("create", %{"initiative" => params}, socket) do
    project =
      socket.assigns.current_project || Enum.find(socket.assigns.projects, &(&1.id == params["project_id"]))

    case project && Initiatives.create_initiative(socket.assigns.current_scope, project, params) do
      {:ok, initiative} -> {:noreply, push_navigate(socket, to: ~p"/initiatives/#{initiative.id}")}
      {:error, %Ecto.Changeset{} = changeset} -> {:noreply, assign(socket, :form, changeset)}
      _no_project -> {:noreply, socket}
    end
  end

  def handle_info({:initiatives_changed, _project_id}, socket), do: {:noreply, load_initiatives(socket)}

  def handle_info({event, _issue_id}, socket) when event in [:issue_changed, :issue_created],
    do: {:noreply, load_initiatives(socket)}

  def handle_info(_other, socket), do: {:noreply, socket}

  attr :sort, :atom, required: true
  attr :by, :atom, required: true
  attr :label, :string, required: true

  # Progress lists the most done first, the others ascend.
  defp sort_header(assigns) do
    assigns =
      assigns
      |> assign(:current, assigns.sort == assigns.by)
      |> assign(:direction, if(assigns.by == :progress, do: "descending", else: "ascending"))
      |> assign(:caret, if(assigns.by == :progress, do: "pi-caret-down", else: "pi-caret-up"))

    ~H"""
    <.link
      patch={~p"/initiatives?#{[sort: @by]}"}
      id={"sort-#{@by}"}
      aria-sort={@current && @direction}
      class={[
        "inline-flex items-center gap-1 rounded hover:text-slate-900 dark:hover:text-slate-200 focus-visible:outline-2 focus-visible:outline-blue-500",
        @current && "font-semibold text-slate-900 dark:text-slate-200"
      ]}
    >
      {@label}
      <.icon :if={@current} name={@caret} class="h-3 w-3" />
      <.icon :if={!@current} name="pi-caret-up-down" class="h-3 w-3 opacity-60" />
    </.link>
    """
  end

  defp load_initiatives(socket) do
    %{current_scope: scope, project_filter: filter, sort: sort} = socket.assigns

    socket
    |> assign(:today, Date.utc_today())
    |> assign(:initiatives, Initiatives.list_initiatives(scope, project_id: filter, sort: sort))
  end

  # A changeset the form opened with shows no errors until it is submitted.
  defp form_errors(%Ecto.Changeset{action: nil}), do: %{}

  defp form_errors(%Ecto.Changeset{errors: errors}),
    do: Map.new(errors, fn {field, {message, _opts}} -> {field, message} end)

  defp form_errors(nil), do: %{}
end
