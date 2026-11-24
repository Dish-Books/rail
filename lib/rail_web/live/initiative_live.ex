defmodule RailWeb.InitiativeLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Initiatives
  alias Rail.Initiatives.Schemas.Initiative
  alias Rail.Issues
  alias Rail.Issues.Schemas.Cycle
  alias Rail.Issues.Schemas.Issue

  # What a cycle view row reads, as `IssuesLive` preloads it.
  @ticket_preload [
    :project,
    :owner_user,
    :workflow,
    :children,
    :merged_task,
    parent: [:project, :owner_user, :workflow, :children, :task, :merged_task],
    task: [:rounds, runs: [:role, :questions], parent_task: [children: :issue]]
  ]

  on_mount {RailWeb.UserAuth, {:require_tab, :issues}}
  on_mount {RailWeb.UserAuth, :require_github}

  def mount(%{"id" => id}, _session, socket) do
    # "cycles" too: the nightly close moves tickets between cycles without a word on "issues".
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Rail.PubSub, "initiatives")
      Phoenix.PubSub.subscribe(Rail.PubSub, "issues")
      Phoenix.PubSub.subscribe(Rail.PubSub, "cycles")
    end

    socket =
      socket
      |> assign(:page_title, "Initiative")
      |> assign(:current_section, :initiatives)
      |> assign(:initiative, nil)
      |> assign(:notes_form, nil)
      |> assign(:details_form, nil)
      |> assign(:expanded_brief_ids, MapSet.new())
      |> assign(:show_delete, false)
      |> load(id)

    {:ok, socket}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

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
      <.initiative_page
        :if={@initiative}
        initiative={@initiative}
        current_scope={@current_scope}
        today={@today}
        groups={@groups}
        cycles_by_id={@cycles_by_id}
        canceled_count={@canceled_count}
        notes_form={@notes_form}
        details_form={@details_form}
        expanded_brief_ids={@expanded_brief_ids}
      />
    </Layouts.app>

    <.delete_dialog :if={@initiative && @show_delete} initiative={@initiative} />
    """
  end

  def handle_event("edit_notes", _params, socket),
    do: {:noreply, assign(socket, :notes_form, Initiative.changeset(socket.assigns.initiative, %{}))}

  # Kept as typed, so a reload from another tab's write draws the form with it.
  def handle_event("change_notes", %{"initiative" => %{"notes" => notes}}, socket),
    do: {:noreply, assign(socket, :notes_form, Initiative.changeset(socket.assigns.initiative, %{"notes" => notes}))}

  def handle_event("save_notes", %{"initiative" => %{"notes" => notes}}, socket),
    do: {:noreply, save(socket, %{"notes" => notes}, :notes_form)}

  def handle_event("cancel_notes", _params, socket), do: {:noreply, assign(socket, :notes_form, nil)}

  def handle_event("edit_details", _params, socket),
    do: {:noreply, assign(socket, :details_form, Initiative.changeset(socket.assigns.initiative, %{}))}

  def handle_event("change_details", %{"initiative" => params}, socket) do
    changeset = Initiative.changeset(socket.assigns.initiative, Map.take(params, ["name", "expected_on"]))
    {:noreply, assign(socket, :details_form, changeset)}
  end

  def handle_event("save_details", %{"initiative" => params}, socket),
    do: {:noreply, save(socket, Map.take(params, ["name", "expected_on"]), :details_form)}

  def handle_event("cancel_details", _params, socket), do: {:noreply, assign(socket, :details_form, nil)}

  # Deleted in another tab meanwhile: `load/2` finds nothing and sends the person back to Initiatives.
  def handle_event("create_brief", _params, socket) do
    %{current_scope: scope, initiative: initiative} = socket.assigns

    case Initiatives.create_update_brief(scope, initiative) do
      {:ok, _comment} -> {:noreply, load(socket, initiative.id)}
      {:error, :not_found} -> {:noreply, load(socket, initiative.id)}
    end
  end

  def handle_event("toggle_brief", %{"id" => id}, socket) do
    socket =
      update(socket, :expanded_brief_ids, fn ids ->
        if MapSet.member?(ids, id), do: MapSet.delete(ids, id), else: MapSet.put(ids, id)
      end)

    {:noreply, socket}
  end

  def handle_event("ask_delete", _params, socket), do: {:noreply, assign(socket, :show_delete, true)}
  def handle_event("cancel_delete", _params, socket), do: {:noreply, assign(socket, :show_delete, false)}

  # Gone already is as good as deleted. The page lets go of it, so its own broadcast does not read it as missing.
  def handle_event("delete", _params, socket) do
    Initiatives.delete_initiative(socket.assigns.current_scope, socket.assigns.initiative)
    socket = socket |> assign(:initiative, nil) |> push_navigate(to: ~p"/initiatives")
    {:noreply, socket}
  end

  # Another tab's write, a ticket joining or moving, a cycle closing: read again; an open form keeps its text.
  def handle_info({event, project_id}, %{assigns: %{initiative: %Initiative{project_id: project_id}}} = socket)
      when event in [:initiatives_changed, :cycles_changed], do: {:noreply, load(socket, socket.assigns.initiative.id)}

  def handle_info({event, _issue_id}, %{assigns: %{initiative: %Initiative{}}} = socket)
      when event in [:issue_changed, :issue_created], do: {:noreply, load(socket, socket.assigns.initiative.id)}

  def handle_info(_other, socket), do: {:noreply, socket}

  attr :initiative, Initiative, required: true
  attr :current_scope, :any, required: true
  attr :today, Date, required: true
  attr :groups, :list, required: true
  attr :cycles_by_id, :map, required: true
  attr :canceled_count, :integer, required: true
  attr :notes_form, :any, required: true
  attr :details_form, :any, required: true
  attr :expanded_brief_ids, :any, required: true

  defp initiative_page(assigns) do
    initiative = assigns.initiative
    due = Initiative.calculate_due(initiative, assigns.today)

    assigns =
      assigns
      |> assign(:percent, Initiative.calculate_percent(initiative))
      |> assign(:comments, initiative.comments)
      |> assign(:newest_brief, List.first(initiative.comments))
      |> assign(:show_notes_form, assigns.notes_form != nil)
      |> assign(:show_notes, assigns.notes_form == nil and String.trim(initiative.notes) != "")
      |> assign(:show_no_notes, assigns.notes_form == nil and String.trim(initiative.notes) == "")
      |> assign(:show_details_form, assigns.details_form != nil)
      |> assign(:details_errors, form_errors(assigns.details_form))
      |> assign(:show_due, due != nil)
      |> assign(:late, match?({:late, _days}, due))
      |> assign(:due_text, due_text(initiative, assigns.today))

    ~H"""
    <div id="initiative-page" class="max-w-6xl mx-auto space-y-6">
      <nav
        class="flex items-center gap-2 text-xs text-slate-500 dark:text-slate-400"
        aria-label="Breadcrumb"
      >
        <.link
          navigate={~p"/initiatives"}
          id="initiative-breadcrumb"
          class="hover:text-slate-900 dark:hover:text-slate-100 rounded focus-visible:outline-2 focus-visible:outline-blue-500"
        >
          Initiatives
        </.link>
        <.icon name="pi-caret-right" class="h-3 w-3" />
        <.project_badge project={@initiative.project} />
      </nav>

      <div class="flex flex-col lg:flex-row gap-10">
        <article class="flex-1 min-w-0 space-y-8">
          <h1
            id="initiative-name"
            class="text-2xl font-semibold tracking-tight text-slate-900 dark:text-slate-100 break-words"
          >
            {@initiative.name}
          </h1>

          <section class="space-y-2" aria-labelledby="initiative-notes-title">
            <div class="flex items-center gap-2">
              <h2
                id="initiative-notes-title"
                class="text-sm font-semibold text-slate-900 dark:text-slate-100"
              >
                Notes
              </h2>
              <button
                :if={!@show_notes_form}
                type="button"
                id="edit-notes"
                phx-click="edit_notes"
                class="ml-auto inline-flex items-center gap-1 px-2 py-1 rounded-lg text-xs font-semibold text-slate-500 dark:text-slate-400 hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer focus-visible:outline-2 focus-visible:outline-blue-500"
              >
                <.icon name="pi-pencil-simple" class="h-3.5 w-3.5" />Edit
              </button>
            </div>
            <div :if={@show_notes} id="initiative-notes" class="break-words">
              <.markdown content={@initiative.notes} />
            </div>
            <p
              :if={@show_no_notes}
              id="initiative-no-notes"
              class="text-sm text-slate-500 dark:text-slate-400"
            >
              No notes yet.
            </p>
            <%!-- A reconnect draws the form away: the hook pushes edit_notes and gives the textarea back what was typed. --%>
            <.form
              :if={@show_notes_form}
              for={@notes_form}
              id="notes-form"
              phx-change="change_notes"
              phx-submit="save_notes"
              phx-hook="CommentBox"
              data-reopen={Jason.encode!(%{event: "edit_notes"})}
              class="space-y-2"
            >
              <label for="initiative-notes-input" class="sr-only">Notes</label>
              <%!-- Ignored once drawn, so a reload from another tab's write leaves what is typed. --%>
              <textarea
                id="initiative-notes-input"
                name="initiative[notes]"
                rows="16"
                phx-update="ignore"
                phx-mounted={JS.focus()}
                class="w-full rounded-lg border border-slate-300 dark:border-slate-600 bg-white dark:bg-slate-950/60 px-3 py-2 font-mono text-[13px] leading-relaxed text-slate-900 dark:text-slate-100 focus:outline-none focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
              >{Ecto.Changeset.get_field(@notes_form, :notes)}</textarea>
              <div class="flex items-center gap-2">
                <button
                  type="submit"
                  id="save-notes"
                  phx-disable-with="Saving..."
                  class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-blue-600 dark:bg-blue-500 text-white text-xs font-semibold hover:opacity-90 shadow-xs cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
                >
                  <.icon name="pi-check" class="h-4 w-4" />Save notes
                </button>
                <button
                  type="button"
                  id="cancel-notes"
                  phx-click="cancel_notes"
                  class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg border border-slate-300 dark:border-slate-600 bg-slate-100 dark:bg-slate-700 text-xs font-semibold hover:bg-slate-200 dark:hover:bg-slate-600 cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
                >
                  <.icon name="pi-x" class="h-3.5 w-3.5" />Cancel
                </button>
                <span class="ml-auto text-xs text-slate-500 dark:text-slate-400">Markdown</span>
              </div>
            </.form>
          </section>

          <section class="space-y-3" aria-labelledby="initiative-tickets-title">
            <div class="flex items-center gap-2">
              <h2
                id="initiative-tickets-title"
                class="text-sm font-semibold text-slate-900 dark:text-slate-100"
              >
                Tickets
              </h2>
              <span id="initiative-ticket-total" class="text-xs text-slate-500 dark:text-slate-400">
                {length(@initiative.issues)}
              </span>
              <span
                :if={@groups != []}
                class="ml-auto text-xs text-slate-500 dark:text-slate-400 text-right"
              >
                Add one from an issue's Initiative menu
              </span>
            </div>
            <p
              :if={@groups == []}
              id="initiative-no-tickets"
              class="rounded-xl border border-dashed border-slate-300 dark:border-slate-700 px-4 py-6 text-sm text-center text-slate-500 dark:text-slate-400"
            >
              No tickets yet. Add one from an issue's Initiative menu.
            </p>
            <div
              :if={@groups != []}
              id="initiative-tickets"
              class="rounded-xl border border-slate-200 dark:border-slate-700 overflow-hidden"
            >
              <section :for={group <- @groups} id={"tickets-#{group.key}"} aria-label={group.label}>
                <div class="flex items-center gap-2.5 h-10 px-4 bg-slate-50 dark:bg-slate-800/60 border-b border-slate-200 dark:border-slate-700">
                  <.status_icon state={group.state} />
                  <h3 class="min-w-0 truncate text-[13px] font-semibold text-slate-900 dark:text-slate-100">
                    {group.label}
                  </h3>
                  <span class="shrink-0 text-xs text-slate-500 dark:text-slate-400">
                    {group.count} {if group.count == 1, do: "issue", else: "issues"}
                  </span>
                  <span
                    class="shrink-0 inline-flex items-center gap-1 text-xs text-slate-500 dark:text-slate-400"
                    title={"#{group.points} points"}
                  >
                    <.icon name="pi-triangle" class="h-3 w-3" />{group.points}
                  </span>
                  <span
                    :if={group.state == :canceled}
                    class="truncate text-xs text-slate-500 dark:text-slate-400"
                  >
                    · not counted in progress
                  </span>
                </div>
                <div class="divide-y divide-slate-200 dark:divide-slate-800 border-b border-slate-200 dark:border-slate-700">
                  <%= for row <- group.rows do %>
                    <.issue_card
                      issue={row.issue}
                      current_scope={@current_scope}
                      row_key={row.key}
                      dimmed={row.dimmed}
                      cycle={@cycles_by_id[row.issue.cycle_id]}
                    />
                    <.issue_card
                      :for={sub <- row.sub_issues}
                      issue={sub.issue}
                      current_scope={@current_scope}
                      row_key={sub.key}
                      nested
                      cycle={@cycles_by_id[sub.issue.cycle_id]}
                    />
                  <% end %>
                </div>
              </section>
            </div>
          </section>

          <section class="space-y-3 pb-10" aria-labelledby="initiative-briefs-title">
            <div class="flex items-center gap-2">
              <h2
                id="initiative-briefs-title"
                class="text-sm font-semibold text-slate-900 dark:text-slate-100"
              >
                Update briefs
              </h2>
              <span class="text-xs text-slate-500 dark:text-slate-400">{length(@comments)}</span>
            </div>
            <p
              :if={@comments == []}
              id="initiative-no-briefs"
              class="rounded-xl border border-dashed border-slate-300 dark:border-slate-700 px-4 py-6 text-sm text-center text-slate-500 dark:text-slate-400"
            >
              No update briefs yet. The first one lists every ticket done so far.
            </p>
            <.brief
              :for={comment <- @comments}
              comment={comment}
              folded={
                comment != @newest_brief and not MapSet.member?(@expanded_brief_ids, comment.id)
              }
              foldable={comment != @newest_brief}
            />
          </section>
        </article>

        <aside class="w-full lg:w-72 shrink-0 space-y-6 text-sm">
          <section class="space-y-3" aria-labelledby="initiative-progress-title">
            <h2
              id="initiative-progress-title"
              class="text-xs font-medium text-slate-500 dark:text-slate-400"
            >
              Progress
            </h2>
            <div class="flex items-baseline gap-2">
              <span
                id="initiative-percent"
                class="text-2xl font-semibold text-slate-900 dark:text-slate-100"
              >
                {@percent}%
              </span>
              <span class="text-xs text-slate-500 dark:text-slate-400">done</span>
            </div>
            <.progress_bar percent={@percent} class="h-2" />
            <p id="initiative-counts" class="text-xs text-slate-500 dark:text-slate-400">
              <span class="font-semibold text-slate-700 dark:text-slate-200">
                {@initiative.done_count} of {@initiative.ticket_count} tickets
              </span>
              <span :if={@canceled_count > 0}>· {@canceled_count} canceled not counted</span>
            </p>
          </section>

          <section class="space-y-2" aria-labelledby="initiative-properties-title">
            <h2
              id="initiative-properties-title"
              class="text-xs font-medium text-slate-500 dark:text-slate-400"
            >
              Properties
            </h2>
            <div :if={!@show_details_form} class="space-y-1">
              <button
                type="button"
                id="initiative-expected"
                phx-click="edit_details"
                title="Change the expected date"
                class="-mx-2 w-full flex items-center gap-2.5 px-2 py-1 rounded-lg text-left hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer focus-visible:outline-2 focus-visible:outline-blue-500"
              >
                <.icon :if={!@late} name="pi-calendar-blank" class="h-4 w-4 shrink-0 text-slate-400" />
                <.icon
                  :if={@late}
                  name="pi-warning-circle"
                  class="h-4 w-4 shrink-0 text-red-600 dark:text-red-400"
                />
                <span :if={!@show_due} class="text-slate-400 dark:text-slate-500">No expected date</span>
                <span :if={@show_due} class="text-slate-900 dark:text-slate-100">
                  {Calendar.strftime(@initiative.expected_on, "%b %-d, %Y")}
                </span>
                <span :if={@show_due and !@late} class="text-xs text-slate-500 dark:text-slate-400">
                  {@due_text}
                </span>
                <span :if={@late} class="text-xs font-semibold text-red-600 dark:text-red-400">
                  {@due_text}
                </span>
              </button>
              <div class="-mx-2 flex items-center gap-2.5 px-2 py-1 min-w-0">
                <.icon name="pi-folder" class="h-4 w-4 shrink-0 text-slate-400" />
                <span id="initiative-project" class="truncate text-slate-900 dark:text-slate-100">
                  {@initiative.project.name}
                </span>
              </div>
              <button
                type="button"
                id="rename-initiative"
                phx-click="edit_details"
                class="-mx-2 w-full flex items-center gap-2.5 px-2 py-1 rounded-lg text-left text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer focus-visible:outline-2 focus-visible:outline-blue-500"
              >
                <.icon name="pi-text-aa" class="h-4 w-4 shrink-0 text-slate-400" />Rename
              </button>
            </div>
            <.form
              :if={@show_details_form}
              for={@details_form}
              id="details-form"
              phx-change="change_details"
              phx-submit="save_details"
              phx-window-keydown="cancel_details"
              phx-key="Escape"
              class="space-y-3"
            >
              <.input
                id="initiative-name-input"
                name="initiative[name]"
                label="Name"
                size="small"
                value={Ecto.Changeset.get_field(@details_form, :name)}
                errors={List.wrap(@details_errors[:name])}
                maxlength="200"
                autocomplete="off"
                phx-mounted={JS.focus()}
                container_class="space-y-1"
              />
              <.input
                id="initiative-expected-input"
                name="initiative[expected_on]"
                type="date"
                label="Expected date (optional)"
                size="small"
                value={Ecto.Changeset.get_field(@details_form, :expected_on)}
                errors={List.wrap(@details_errors[:expected_on])}
                container_class="space-y-1"
              />
              <div class="flex gap-2">
                <button
                  type="submit"
                  id="save-details"
                  phx-disable-with="Saving..."
                  class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-blue-600 dark:bg-blue-500 text-white text-xs font-semibold hover:opacity-90 shadow-xs cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
                >
                  <.icon name="pi-check" class="h-4 w-4" />Save
                </button>
                <button
                  type="button"
                  id="cancel-details"
                  phx-click="cancel_details"
                  class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg border border-slate-300 dark:border-slate-600 bg-slate-100 dark:bg-slate-700 text-xs font-semibold hover:bg-slate-200 dark:hover:bg-slate-600 cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
                >
                  <.icon name="pi-x" class="h-3.5 w-3.5" />Cancel
                </button>
              </div>
            </.form>
          </section>

          <section class="space-y-3" aria-labelledby="initiative-update-title">
            <h2
              id="initiative-update-title"
              class="text-xs font-medium text-slate-500 dark:text-slate-400"
            >
              Update
            </h2>
            <button
              type="button"
              id="create-brief"
              phx-click="create_brief"
              phx-disable-with="Posting..."
              class="w-full inline-flex items-center justify-center gap-1.5 px-3 py-1.5 rounded-lg bg-blue-600 dark:bg-blue-500 text-white text-xs font-semibold hover:opacity-90 shadow-xs cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
            >
              <.icon name="pi-megaphone-fill" class="h-4 w-4" />Create update brief
            </button>
            <p id="create-brief-hint" class="text-xs text-slate-500 dark:text-slate-400">
              <span :if={@newest_brief}>
                Posts where it stands as Markdown, listing what is done since
                <.local_time id={"since-#{@newest_brief.id}"} at={@newest_brief.inserted_at} />.
              </span>
              <span :if={!@newest_brief}>Posts where it stands as Markdown, listing every ticket done so far.</span>
            </p>
          </section>

          <section class="pt-2 border-t border-slate-200 dark:border-slate-700">
            <button
              type="button"
              id="delete-initiative"
              phx-click="ask_delete"
              class="inline-flex items-center gap-1.5 px-2.5 py-1.5 rounded-lg text-xs font-semibold text-red-600 dark:text-red-400 hover:bg-red-500/10 cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-red-500"
            >
              <.icon name="pi-trash" class="h-3.5 w-3.5" />Delete initiative
            </button>
          </section>
        </aside>
      </div>
    </div>
    """
  end

  attr :comment, :any, required: true
  attr :folded, :boolean, required: true
  attr :foldable, :boolean, required: true

  defp brief(assigns) do
    author = assigns.comment.author_user

    assigns =
      assigns
      |> assign(:author, author)
      |> assign(:author_name, if(author, do: author.name || author.login, else: "Rail"))

    ~H"""
    <article
      id={"brief-#{@comment.id}"}
      class="rounded-xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-800/40"
    >
      <header class="flex items-center gap-2.5 px-4 py-2.5 border-b border-slate-200 dark:border-slate-700 min-w-0">
        <.assignee user={@author} />
        <span class="shrink-0 text-sm font-medium text-slate-900 dark:text-slate-100">
          {@author_name}
        </span>
        <span class="min-w-0 truncate text-xs text-slate-500 dark:text-slate-400">
          posted an update brief ·
          <.local_time id={"brief-time-#{@comment.id}"} at={@comment.inserted_at} />
        </span>
        <button
          type="button"
          id={"copy-brief-#{@comment.id}"}
          phx-hook="CopyText"
          data-copy-text={@comment.body}
          title="Copy the brief's Markdown"
          class="group ml-auto shrink-0 inline-flex items-center gap-1.5 h-7 px-2.5 rounded-lg border border-slate-300 dark:border-slate-600 bg-slate-100 dark:bg-slate-700 text-xs font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-200 dark:hover:bg-slate-600 cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
        >
          <.icon name="pi-copy" class="h-3.5 w-3.5 group-data-[copied=true]:hidden" />
          <.icon
            name="pi-check"
            class="h-3.5 w-3.5 text-green-600 hidden group-data-[copied=true]:inline-block"
          />
          <span class="group-data-[copied=true]:hidden">Copy</span>
          <span class="hidden group-data-[copied=true]:inline">Copied</span>
        </button>
      </header>
      <div class="px-4 py-3">
        <div class={["relative break-words", @folded && "max-h-40 overflow-hidden"]}>
          <.markdown content={@comment.body} />
          <div
            :if={@folded}
            class="absolute inset-x-0 bottom-0 h-10 bg-gradient-to-t from-white dark:from-slate-900 to-transparent"
          >
          </div>
        </div>
        <button
          :if={@foldable}
          type="button"
          id={"toggle-brief-#{@comment.id}"}
          phx-click="toggle_brief"
          phx-value-id={@comment.id}
          aria-expanded={to_string(!@folded)}
          class="mt-2 text-xs font-semibold text-blue-600 dark:text-blue-400 hover:underline cursor-pointer rounded focus-visible:outline-2 focus-visible:outline-blue-500"
        >
          <span :if={@folded}>Show all</span>
          <span :if={!@folded}>Show less</span>
        </button>
      </div>
    </article>
    """
  end

  attr :initiative, Initiative, required: true

  defp delete_dialog(assigns) do
    assigns = assign(assigns, :ticket_count, length(assigns.initiative.issues))

    ~H"""
    <div
      id="delete-initiative-dialog"
      class="fixed inset-0 z-50 flex items-start justify-center pt-40 p-4 bg-slate-950/70"
      phx-window-keydown="cancel_delete"
      phx-key="Escape"
    >
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="delete-initiative-title"
        class="w-full max-w-[440px] rounded-xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900 shadow-xl p-5 space-y-4"
      >
        <h2
          id="delete-initiative-title"
          class="text-base font-semibold text-slate-900 dark:text-slate-100 break-words"
        >
          Delete {@initiative.name}?
        </h2>
        <p class="text-sm text-slate-600 dark:text-slate-300">
          Its notes and update briefs go with it.
          <span :if={@ticket_count == 0}>It has no tickets.</span>
          <span :if={@ticket_count == 1}>Its 1 ticket stays where it is, with no initiative.</span>
          <span :if={@ticket_count > 1}>
            Its {@ticket_count} tickets stay where they are, with no initiative.
          </span>
        </p>
        <div class="flex justify-end gap-2">
          <button
            type="button"
            id="cancel-delete"
            phx-click="cancel_delete"
            phx-mounted={JS.focus()}
            class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg border border-slate-300 dark:border-slate-600 bg-slate-100 dark:bg-slate-700 text-xs font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-200 dark:hover:bg-slate-600 cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
          >
            <.icon name="pi-x" class="h-3.5 w-3.5" />Cancel
          </button>
          <button
            type="button"
            id="confirm-delete"
            phx-click="delete"
            phx-disable-with="Deleting..."
            class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-red-600 text-white text-xs font-semibold hover:bg-red-500 cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-red-500"
          >
            <.icon name="pi-trash" class="h-3.5 w-3.5" />Delete initiative
          </button>
        </div>
      </div>
    </div>
    """
  end

  # Deleted, or out of the person's projects: back to the list, as `IssueLive` does for an issue.
  defp load(socket, id) do
    case Initiatives.get_initiative(socket.assigns.current_scope, id, preload: @ticket_preload) do
      {:ok, initiative} ->
        socket
        |> assign(:initiative, initiative)
        |> assign(:page_title, initiative.name)
        |> assign(:today, Date.utc_today())
        |> assign_groups(initiative)
        |> assign(:canceled_count, Enum.count(initiative.issues, &(&1.state == :canceled)))

      {:error, :not_found} ->
        socket
        |> assign(:initiative, nil)
        |> put_flash(:error, "Initiative not found")
        |> push_navigate(to: ~p"/initiatives")
    end
  end

  # Grouped as the cycle view groups them, from the same statuses, each row with its cycle's chip. A parent the group
  # does not hold is not drawn as context: its sub-issues stand as rows of their own.
  defp assign_groups(socket, %Initiative{project: project, issues: issues}) do
    {:ok, %{cycles: cycles, statuses: statuses}} = Issues.get_cycles(project)

    groups =
      for group <- Issue.calculate_status_groups(issues, statuses, %{project.id => Cycle.default_estimate()}),
          do: %{group | rows: Enum.flat_map(group.rows, &own_rows/1)}

    socket
    |> assign(:cycles_by_id, Map.new(cycles, &{&1.id, &1}))
    |> assign(:groups, groups)
  end

  defp own_rows(%{dimmed: true, sub_issues: sub_issues}),
    do: Enum.map(sub_issues, &%{issue: &1.issue, key: &1.key, dimmed: false, sub_issues: []})

  defp own_rows(row), do: [row]

  defp save(socket, attrs, form_key) do
    case Initiatives.update_initiative(socket.assigns.current_scope, socket.assigns.initiative, attrs) do
      {:ok, _initiative} -> socket |> assign(form_key, nil) |> load(socket.assigns.initiative.id)
      {:error, %Ecto.Changeset{} = changeset} -> assign(socket, form_key, changeset)
      {:error, :not_found} -> load(socket, socket.assigns.initiative.id)
    end
  end

  defp due_text(initiative, today) do
    case Initiative.calculate_due_text(initiative, today) do
      text when is_binary(text) -> String.capitalize(text)
      nil -> nil
    end
  end

  # A changeset a form opened with shows no errors until it is submitted.
  defp form_errors(%Ecto.Changeset{action: nil}), do: %{}

  defp form_errors(%Ecto.Changeset{errors: errors}),
    do: Map.new(errors, fn {field, {message, _opts}} -> {field, message} end)

  defp form_errors(nil), do: %{}
end
