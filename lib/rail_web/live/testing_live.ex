defmodule RailWeb.TestingLive do
  @moduledoc false
  use RailWeb, :live_view

  import RailWeb.Utils.IssueRelative
  import RailWeb.Utils.RefuseImages

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Scope

  on_mount {RailWeb.UserAuth, {:require_tab, :testing}}

  @preload [
    :project,
    :owner_user,
    :workflow,
    :parent,
    :children,
    :links,
    task: [:rounds, runs: :role, parent_task: [children: :issue]],
    comments: [:author_user, replies: :author_user]
  ]

  # The usual longest gap between a double click's two clicks, so the second lands on the loading screen.
  @advance_ms 500

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Rail.PubSub, "issues")
      Phoenix.PubSub.subscribe(Rail.PubSub, "testing")
      Phoenix.PubSub.subscribe(Rail.PubSub, "cycles")
    end

    socket =
      socket
      |> assign(:page_title, "Testing")
      |> assign(:current_section, :testing)
      |> assign(:issue, nil)
      |> assign(:blockers, nil)
      |> assign(:cycles, nil)
      |> assign(:notice, nil)
      |> assign(:advancing, nil)
      |> assign(:notes_rev, 0)
      |> assign(:image_error, nil)
      |> assign(:image_scenario_id, nil)
      |> assign(:upload_targets, %{})
      |> assign(:add_rev, 0)
      |> assign(:reason_dialog, nil)
      |> assign(:writing_timer, nil)
      |> allow_upload(:testing_images,
        accept: [".png", ".jpg", ".jpeg", ".gif", ".webp"],
        max_entries: 10,
        max_file_size: 10_000_000,
        auto_upload: true,
        progress: &handle_progress/3
      )

    {:ok, socket}
  end

  # The open ticket is in the URL, so it can be linked to. A notice outlives only the patch its action made.
  def handle_params(params, _uri, socket) do
    notice = socket.assigns.notice

    socket =
      socket
      |> assign(:selected_id, params["id"])
      |> assign(:notice, if(notice && notice.for == params["id"], do: notice))
      |> assign(:advancing, nil)
      |> assign(:notes_rev, 0)
      |> load(:select)

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} {assigns}>
      <div id="testing-page" data-qa="testing-page" class="-m-6 h-[calc(100%+3rem)] flex min-h-0">
        <.testing_queue issues={@queue} selected_id={@issue && @issue.id} now={@now} />

        <section id="testing-ticket" class="flex-1 min-w-0 flex flex-col min-h-0">
          <div
            :if={@advancing}
            id="testing-advancing"
            class="flex-1 flex items-center justify-center gap-2 text-sm text-slate-500 dark:text-slate-400"
          >
            <.icon name="pi-circle-notch" class="size-4 motion-safe:animate-spin" />{@advancing.label}
          </div>

          <div
            :if={@issue && !@advancing}
            id="testing-bar"
            class="flex items-center gap-3 px-6 py-3 border-b border-slate-200 dark:border-slate-700 flex-wrap"
          >
            <span class="font-mono text-xs text-slate-500 dark:text-slate-400">{@issue.identifier}</span>
            <.testing_badge
              :if={@show_testing_state}
              id="testing-bar-state"
              state={@issue.testing_state}
            />
            <span
              :if={@issue.completed_at}
              class="inline-flex items-center gap-1 text-xs text-slate-500 dark:text-slate-400"
            >
              <.icon name="pi-check-circle-fill" class="size-3.5 text-indigo-400" />
              Done {format_age(DateTime.diff(@now, @issue.completed_at))} ago
            </span>
            <.link
              navigate={~p"/issues/#{@issue.identifier}"}
              id="testing-open-issue"
              class="inline-flex items-center gap-1 text-xs text-slate-500 dark:text-slate-400 hover:underline"
            >
              <.icon name="pi-arrow-square-out" class="size-3.5" />Open issue
            </.link>
            <div :if={@in_queue} class="ml-auto flex items-center gap-2">
              <.button
                id="testing-send-to-triage"
                phx-click="send_to_triage"
                phx-value-issue_id={@issue.id}
                data-no-repeat
                disabled={!@can_send}
                title={@send_title}
              >
                <.icon name="pi-tray" class="size-4" />Send to triage
              </.button>
              <.button
                id="testing-mark-tested"
                variant="success"
                phx-click="mark_tested"
                phx-value-issue_id={@issue.id}
                data-no-repeat
                disabled={!@can_mark}
                title={@mark_title}
              >
                <.icon name="pi-check-bold" class="size-4" />Mark tested
              </.button>
            </div>
          </div>

          <div :if={!@advancing} class="flex-1 overflow-y-auto px-6 py-5">
            <div class="max-w-5xl mx-auto space-y-6">
              <.notice :if={@notice} notice={@notice} issue={@issue} />

              <section :if={@issue} id="testing-scenarios" class="space-y-4">
                <%!-- One form, so each note's paste reaches the upload through its own form and every change reaches
                     save_testing. The upload input comes first while the ticket is editable: an upload reports through it. --%>
                <form id={"testing-form-#{@issue.id}"} phx-change="save_testing" class="space-y-4">
                  <.live_file_input
                    :if={@editable}
                    upload={@uploads.testing_images}
                    class="sr-only"
                  />
                  <input type="hidden" name="issue_id" value={@issue.id} />
                  <.testing_place issue={@issue} editable={@editable} locked={!@in_queue} />
                  <div class="border-t border-slate-200 dark:border-slate-800"></div>

                  <div
                    :if={@show_earlier_notes}
                    id="testing-earlier-notes"
                    class="rounded-xl bg-slate-50 dark:bg-slate-800/40 ring-1 ring-slate-200 dark:ring-slate-700 px-4 py-3 space-y-2"
                  >
                    <div class="flex items-center gap-2">
                      <span class="text-sm font-semibold text-slate-900 dark:text-slate-100">
                        Notes from before scenarios
                      </span>
                      <span class="inline-flex items-center gap-1 text-xs text-slate-500 dark:text-slate-400">
                        <.icon name="pi-lock-simple" class="size-3" />Read-only
                      </span>
                    </div>
                    <p
                      :if={@issue.testing_notes}
                      class="text-[13.5px] leading-relaxed whitespace-pre-wrap break-words text-slate-700 dark:text-slate-300"
                      phx-no-format
                    >{@issue.testing_notes}</p>
                    <div :if={@issue.testing_images != []} class="flex flex-wrap gap-2">
                      <.image_chip
                        :for={{image, index} <- Enum.with_index(@issue.testing_images)}
                        id={"testing-earlier-image-#{index}"}
                        name={image.name}
                        src={image.url}
                        removable={false}
                      />
                    </div>
                    <p :if={@in_queue} class="text-xs text-slate-500 dark:text-slate-400">
                      They go to triage with any failed scenarios. With no scenarios, Mark tested asks why there was nothing to test.
                    </p>
                  </div>

                  <div class="flex items-center gap-3">
                    <h2 class="text-sm font-semibold text-slate-900 dark:text-slate-100">
                      Test scenarios
                    </h2>
                    <span
                      :if={@in_queue and @issue.testing_scenarios != []}
                      id="testing-progress"
                      class="text-xs text-slate-500 dark:text-slate-400"
                    >
                      <span class="text-emerald-600 dark:text-emerald-300">{@progress.passed} passed</span>
                      · <span class="text-red-600 dark:text-red-300">{@progress.failed} failed</span>
                      · {@progress.open} left
                    </span>
                    <span
                      :if={!@in_queue}
                      id="testing-lock"
                      class="inline-flex items-center gap-1 text-xs text-slate-500 dark:text-slate-400"
                    >
                      <.icon name="pi-lock-simple" class="size-3" />{@lock_label}
                    </span>
                  </div>

                  <div
                    :if={@writing}
                    id="testing-writing"
                    class="rounded-xl border border-slate-200 dark:border-slate-700/80 bg-slate-50 dark:bg-slate-800/40 px-4 py-6 flex items-center gap-3 text-sm text-slate-600 dark:text-slate-300"
                  >
                    <.icon
                      name="pi-circle-notch"
                      class="size-4 shrink-0 motion-safe:animate-spin text-blue-500 dark:text-blue-400"
                    />
                    <div class="min-w-0">
                      <p class="font-semibold text-slate-800 dark:text-slate-200">
                        Writing scenarios…
                      </p>
                      <p class="mt-0.5 text-xs text-slate-500 dark:text-slate-400">
                        An agent is reading {@issue.identifier} and its merged pull request. You can test it once they are written.
                      </p>
                    </div>
                  </div>

                  <div
                    :if={@show_empty}
                    id="testing-scenarios-empty"
                    class="rounded-xl border border-dashed border-slate-300 dark:border-slate-700 px-5 py-8 text-center"
                  >
                    <.icon
                      name="pi-list-checks-fill"
                      class="size-8 text-slate-400 dark:text-slate-500"
                    />
                    <p class="mt-2 text-sm font-semibold text-slate-700 dark:text-slate-300">
                      No scenarios yet. Add the ones you want to check.
                    </p>
                    <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">
                      Mark tested asks why there was nothing to test.
                    </p>
                  </div>

                  <div
                    :if={@issue.no_scenarios_reason}
                    id="testing-no-scenarios-reason"
                    class="rounded-xl bg-slate-50 dark:bg-slate-800/40 ring-1 ring-slate-200 dark:ring-slate-700 px-4 py-3 space-y-1"
                  >
                    <p class="text-xs font-semibold text-slate-500 dark:text-slate-400">
                      Marked tested with no scenarios
                    </p>
                    <p
                      class="text-[13.5px] leading-relaxed whitespace-pre-wrap break-words text-slate-800 dark:text-slate-200"
                      phx-no-format
                    >{@issue.no_scenarios_reason}</p>
                  </div>

                  <ol
                    :if={@issue.testing_scenarios != []}
                    id="testing-scenario-list"
                    class="space-y-2"
                  >
                    <.testing_scenario
                      :for={{scenario, number} <- Enum.with_index(@issue.testing_scenarios, 1)}
                      issue_id={@issue.id}
                      scenario={scenario}
                      number={number}
                      editable={@editable}
                      upload_ref={@uploads.testing_images.ref}
                      uploading={
                        for entry <- @uploads.testing_images.entries,
                            @upload_targets[entry.ref] == scenario.id,
                            do: entry
                      }
                      notes_rev={@notes_rev}
                    />
                  </ol>
                </form>

                <%!-- One line, retyped in seconds, so a reconnect leaves it empty rather than send it per keystroke. --%>
                <form
                  :if={@in_queue}
                  id={"testing-add-scenario-#{@issue.id}-#{@add_rev}"}
                  phx-submit="add_scenario"
                  phx-auto-recover="ignore"
                  class={[
                    "flex items-center gap-2 rounded-xl border border-dashed border-slate-300 dark:border-slate-700 px-3 py-2 focus-within:border-blue-500",
                    @writing && "opacity-50"
                  ]}
                >
                  <input type="hidden" name="issue_id" value={@issue.id} />
                  <.icon name="pi-plus" class="size-4 text-slate-400 shrink-0" />
                  <label for="testing-new-scenario" class="sr-only">New scenario</label>
                  <input
                    id="testing-new-scenario"
                    name="title"
                    type="text"
                    maxlength="500"
                    disabled={@writing}
                    placeholder="Add a scenario and press Enter"
                    class="block w-full min-w-0 border-0 bg-transparent p-0 text-[13.5px] text-slate-900 dark:text-slate-100 placeholder-slate-400 dark:placeholder-slate-500 focus:outline-none focus:ring-0"
                  />
                </form>

                <p
                  :if={@image_error}
                  id="testing-image-error"
                  role="alert"
                  class="flex items-start gap-2 text-xs text-red-700 dark:text-red-300"
                >
                  <.icon
                    name="pi-warning-circle"
                    class="size-4 shrink-0 text-red-600 dark:text-red-400"
                  />
                  <span class="min-w-0 break-words">{@image_error}</span>
                </p>
                <p :if={@in_queue and !@writing} class="text-xs text-slate-500 dark:text-slate-400">
                  Send to triage opens a follow-up in Triage with every scenario's result, the failed ones' notes and pictures, where you tested and a link to {@issue.identifier}.
                </p>
              </section>

              <div :if={@issue} class="border-t border-slate-200 dark:border-slate-800"></div>

              <.issue_view
                :if={@issue}
                issue={@issue}
                current_scope={@current_scope}
                blockers={@blockers}
                cycles={@cycles}
                show_task={false}
                read_only
              />
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>

    <.tested_reason_dialog
      :if={@reason_dialog}
      issue_id={@reason_dialog.issue_id}
      identifier={@reason_dialog.identifier}
      error={@reason_dialog.error}
    />
    """
  end

  # A picture belongs to the scenario whose note had focus as it was picked or pasted, recorded as the upload starts.
  # One the form cannot take comes straight back out, with why.
  def handle_event("save_testing", %{"_target" => ["testing_images"]}, socket) do
    {socket, error} = refuse_images(socket, :testing_images)
    %{uploads: %{testing_images: upload}, upload_targets: targets, image_scenario_id: target} = socket.assigns
    targets = Map.new(upload.entries, &{&1.ref, Map.get(targets, &1.ref, target)})

    socket = socket |> assign(:upload_targets, targets) |> assign(:image_error, error)
    {:noreply, socket}
  end

  def handle_event("save_testing", %{"_target" => ["notes", scenario_id], "notes" => notes} = params, socket) do
    attrs = %{note: notes[scenario_id]}
    {:noreply, save(socket, params["issue_id"], &Issues.save_testing_scenario(&1, &2, scenario_id, attrs))}
  end

  def handle_event("save_testing", %{"_target" => ["testing_device"], "testing_device" => device} = params, socket) do
    {:noreply, save(socket, params["issue_id"], &Issues.save_testing_place(&1, &2, %{testing_device: device}))}
  end

  # Recovery on a disabled ticket names the device field and leaves its value out, as it does any disabled field.
  def handle_event("save_testing", _recovered_or_unknown, socket), do: {:noreply, socket}

  # The segmented control sends only its value, so a pick belongs to the ticket shown when it was made.
  def handle_event("save_place", params, %{assigns: %{issue: %Issue{id: issue_id}}} = socket) do
    attrs = Map.take(params, ["testing_environment", "testing_platform"])
    {:noreply, save(socket, issue_id, &Issues.save_testing_place(&1, &2, attrs))}
  end

  def handle_event("mark_scenario", %{"issue_id" => issue_id, "scenario_id" => scenario_id, "result" => result}, socket) do
    {:noreply, save(socket, issue_id, &Issues.save_testing_scenario(&1, &2, scenario_id, %{result: result}))}
  end

  def handle_event("remove_scenario", %{"issue_id" => issue_id, "scenario_id" => scenario_id}, socket) do
    {:noreply, save(socket, issue_id, &Issues.remove_testing_scenario(&1, &2, scenario_id))}
  end

  def handle_event("add_scenario", %{"issue_id" => issue_id, "title" => title}, socket) do
    socket = save(socket, issue_id, &Issues.add_testing_scenario(&1, &2, title))
    {:noreply, update(socket, :add_rev, &(&1 + 1))}
  end

  def handle_event("image_target", %{"scenario_id" => scenario_id}, socket),
    do: {:noreply, assign(socket, :image_scenario_id, scenario_id)}

  def handle_event("remove_testing_image", %{"issue_id" => issue_id, "scenario_id" => scenario_id, "url" => url}, socket) do
    {:noreply, save(socket, issue_id, &Issues.remove_testing_image(&1, &2, scenario_id, url))}
  end

  # Mark tested on a ticket in the queue with no scenarios asks for the reason first, and the dialog's submit comes back
  # with it. A ticket another tab finished falls through to the clause below and its notice.
  def handle_event(
        "mark_tested",
        %{"issue_id" => issue_id} = params,
        %{
          assigns: %{
            issue: %Issue{id: issue_id, testing_scenarios: []} = issue,
            advancing: nil,
            in_queue: true,
            writing: false
          }
        } = socket
      )
      when not is_map_key(params, "no_scenarios_reason") do
    {:noreply, assign(socket, :reason_dialog, %{issue_id: issue.id, identifier: issue.identifier, error: nil})}
  end

  # A second click arrives after the first moved the page on, so it names the ticket it was meant for.
  # While the loading screen shows, a click sent from the old buttons falls to the clause below.
  def handle_event(
        event,
        %{"issue_id" => issue_id} = params,
        %{assigns: %{issue: %Issue{id: issue_id} = issue, advancing: nil}} = socket
      )
      when event in ["mark_tested", "send_to_triage"] do
    %{current_scope: scope, queue: queue} = socket.assigns

    result =
      if event == "mark_tested",
        do: Issues.mark_issue_tested(scope, issue, Map.take(params, ["no_scenarios_reason"])),
        else: Issues.send_issue_to_triage(scope, issue)

    socket =
      case result do
        {:ok, finished} ->
          # The ticket after it in the queue, or the first other one when it was last or already gone.
          next =
            queue |> Enum.drop_while(&(&1.id != issue.id)) |> Enum.at(1) || Enum.find(queue, &(&1.id != issue.id))

          sent = if event == "send_to_triage", do: %{for: next && next.id, sent: finished, identifier: issue.identifier}
          label = if next, do: "Opening #{next.identifier}...", else: "Updating the queue..."
          # A double click's second click lands on this screen, not on the next ticket's buttons.
          advancing = %{from: issue.id, to: next, label: label}
          Process.send_after(self(), {:advance, advancing}, @advance_ms)

          socket |> assign(:notice, sent) |> assign(:advancing, advancing) |> assign(:reason_dialog, nil)

        # A reason left blank keeps the dialog open with why, and opens it when another tab took the last scenario.
        {:error, %Ecto.Changeset{} = changeset} ->
          dialog = %{issue_id: issue.id, identifier: issue.identifier, error: changeset_message(changeset)}
          assign(socket, :reason_dialog, dialog)

        {:error, reason} ->
          socket
          |> assign(:notice, %{for: socket.assigns.selected_id, reason: reason, identifier: issue.identifier})
          |> assign(:reason_dialog, nil)
          |> load()
      end

    {:noreply, socket}
  end

  def handle_event("close_tested_reason", _params, socket), do: {:noreply, assign(socket, :reason_dialog, nil)}

  # Leaving a note shows the note saved last, which another tester's save may have replaced.
  def handle_event("notes_blurred", _params, socket), do: {:noreply, update(socket, :notes_rev, &(&1 + 1))}

  def handle_event(event, _params, socket) when event in ["mark_tested", "send_to_triage"], do: {:noreply, socket}

  # A ticket reaching Done joins the queue, and one leaving it drops out, from whatever wrote it. The open ticket is
  # read again when it or a relative changed, and blockers only when it or a blocker did.
  def handle_info({event, changed_id}, socket) when event in [:issue_changed, :issue_created] do
    %{issue: issue, blockers: blockers} = socket.assigns
    blocker_ids = for %{issue: %Issue{id: id}} <- (blockers && blockers.blocked_by ++ blockers.blocks) || [], do: id

    socket =
      cond do
        is_nil(issue) -> load(socket)
        issue_relative?(issue, blockers, changed_id) -> load(socket)
        true -> load_queue(socket)
      end

    socket =
      if issue != nil and (changed_id == issue.id or changed_id in blocker_ids), do: read_blockers(socket), else: socket

    {:noreply, socket}
  end

  def handle_info({:issue_relations_changed, ids}, %{assigns: %{issue: %Issue{id: issue_id}}} = socket) do
    socket = if issue_id in ids, do: read_blockers(socket), else: socket
    {:noreply, socket}
  end

  def handle_info({event, issue_id}, %{assigns: %{issue: %Issue{id: issue_id}}} = socket)
      when event in [:issue_comments_changed, :testing_changed] do
    {:noreply, load(socket)}
  end

  # The two-hour wait ends with no write to broadcast it, so the page's own timer reads the ticket again.
  def handle_info({:writing_ended, issue_id}, socket) do
    socket =
      if match?({{^issue_id, _deadline}, _ref}, socket.assigns.writing_timer),
        do: assign(socket, :writing_timer, nil),
        else: socket

    socket = if match?(%Issue{id: ^issue_id}, socket.assigns.issue), do: load(socket), else: socket
    {:noreply, socket}
  end

  # Only the move its own action set off: a row opened since cleared it.
  def handle_info({:advance, advancing}, %{assigns: %{advancing: advancing}} = socket) do
    {:noreply, push_patch(socket, to: if(advancing.to, do: ~p"/testing/#{advancing.to.id}", else: ~p"/testing"))}
  end

  def handle_info({:cycles_changed, project_id}, %{assigns: %{issue: %Issue{project_id: project_id}}} = socket) do
    socket = socket |> load() |> read_cycles()
    {:noreply, socket}
  end

  # The navigation hook, the issue dialog, other tickets' notes and comments, other projects' cycles and a move a row
  # click cancelled say things this page has no use for.
  def handle_info(_message, socket), do: {:noreply, socket}

  # An answer read for a ticket the page no longer shows is dropped.
  def handle_async(:blockers, {:ok, {issue_id, blockers}}, %{assigns: %{issue: %Issue{id: issue_id}}} = socket) do
    {:noreply, assign(socket, :blockers, blockers)}
  end

  def handle_async(:blockers, _stale_or_failed, socket), do: {:noreply, socket}

  # The picture shows from the browser's copy until the tracker holds it, then from the ticket.
  def handle_async({:testing_image, ref, name}, result, socket) do
    socket = socket |> cancel_upload(:testing_images, ref) |> update(:upload_targets, &Map.delete(&1, ref))

    # A stored picture's ticket is read again on the broadcast its save sent, so only a refusal is this clause's.
    socket =
      case result do
        {:ok, {:ok, _saved}} ->
          socket

        {:ok, {:error, :testing_finished}} ->
          assign(socket, :image_error, "#{name} was not added: testing on this ticket has finished.")

        {:ok, {:error, :writing_scenarios}} ->
          assign(socket, :image_error, "#{name} was not added: Rail is still writing scenarios.")

        _failed ->
          assign(socket, :image_error, "Couldn't add #{name}. Try adding it again.")
      end

    {:noreply, socket}
  end

  # Kept until the tracker has it, so its preview stays on its scenario meanwhile. One started on a ticket the page has
  # moved on from has no scenario left to go to.
  def handle_progress(:testing_images, %{done?: true} = entry, socket) do
    %{issue: issue, current_scope: scope, upload_targets: targets} = socket.assigns
    name = entry.client_name

    case targets[entry.ref] do
      "" <> scenario_id ->
        data = consume_uploaded_entry(socket, entry, fn %{path: path} -> {:postpone, File.read!(path)} end)

        {:noreply,
         start_async(socket, {:testing_image, entry.ref, name}, fn ->
           Issues.add_testing_image(scope, issue, scenario_id, name, data)
         end)}

      nil ->
        socket =
          socket
          |> cancel_upload(:testing_images, entry.ref)
          |> assign(:image_error, "Couldn't add #{name}. Try adding it again.")

        {:noreply, socket}
    end
  end

  def handle_progress(:testing_images, _entry, socket), do: {:noreply, socket}

  attr :notice, :map, required: true
  attr :issue, :any, required: true

  defp notice(%{notice: %{sent: created}} = assigns) do
    assigns = assign(assigns, :created, created)

    ~H"""
    <div id="testing-notice" class={notice_class()}>
      <.icon name="pi-tray-fill" class="size-4 text-slate-400 mt-0.5" />
      <span>
        {@notice.identifier} sent to triage as <.link
          navigate={~p"/issues/#{@created.identifier}"}
          id="testing-notice-created"
          class="font-mono font-semibold underline underline-offset-2"
        >{@created.identifier}</.link>.
      </span>
    </div>
    """
  end

  defp notice(%{notice: %{reason: :testing_finished}} = assigns) do
    assigns = assign(assigns, :finished, finished_label(assigns.issue))

    ~H"""
    <div id="testing-notice" class={notice_class()}>
      <.icon name="pi-info-fill" class="size-4 text-slate-400 mt-0.5" />
      <span>
        <span class="font-semibold">{@notice.identifier} {@finished}.</span> Nothing was changed.
      </span>
    </div>
    """
  end

  defp notice(%{notice: %{reason: :no_failed_scenarios}} = assigns) do
    ~H"""
    <div id="testing-notice" class={notice_class()}>
      <.icon name="pi-info-fill" class="size-4 text-slate-400 mt-0.5" />
      <span>Mark a scenario Failed to send this to triage.</span>
    </div>
    """
  end

  defp notice(%{notice: %{reason: :scenarios_open}} = assigns) do
    ~H"""
    <div id="testing-notice" class={notice_class()}>
      <.icon name="pi-info-fill" class="size-4 text-slate-400 mt-0.5" />
      <span>Mark tested is for when every scenario passed.</span>
    </div>
    """
  end

  defp notice(%{notice: %{reason: :writing_scenarios}} = assigns) do
    ~H"""
    <div id="testing-notice" class={notice_class()}>
      <.icon name="pi-info-fill" class="size-4 text-slate-400 mt-0.5" />
      <span>Rail is still writing scenarios for {@notice.identifier}. Nothing was changed.</span>
    </div>
    """
  end

  defp notice(assigns) do
    ~H"""
    <div
      id="testing-notice"
      class="rounded-xl border border-red-300 dark:border-red-800 bg-red-50 dark:bg-red-950/30 px-4 py-3 flex items-start gap-2.5 text-[13px] text-red-800 dark:text-red-200 break-words"
    >
      <.icon name="pi-warning-circle" class="size-4 mt-0.5" />
      <span>That did not work: {inspect(@notice.reason)}</span>
    </div>
    """
  end

  defp notice_class,
    do:
      "rounded-xl border border-slate-300 dark:border-slate-600 bg-slate-50 dark:bg-slate-800/60 px-4 py-3 flex items-start gap-2.5 text-[13px] text-slate-800 dark:text-slate-200 break-words"

  defp changeset_message(%Ecto.Changeset{errors: [{_field, {message, _opts}} | _rest]}), do: message

  # A save the debounce flushed as another row opened still belongs to the ticket it was typed on.
  defp save(socket, issue_id, action) do
    %{issue: shown, queue: queue, current_scope: scope} = socket.assigns
    shown? = match?(%Issue{id: ^issue_id}, shown)
    issue = if shown?, do: shown, else: Enum.find(queue, &(&1.id == issue_id))

    case {issue && action.(scope, issue), shown?} do
      {{:ok, saved}, true} ->
        testing = %{
          shown
          | testing_scenarios: saved.testing_scenarios,
            testing_environment: saved.testing_environment,
            testing_platform: saved.testing_platform,
            testing_device: saved.testing_device,
            testing_state: saved.testing_state
        }

        socket |> assign(:issue, testing) |> assign(:image_error, nil) |> assign_issue_flags()

      {{:error, %Ecto.Changeset{}}, _shown} ->
        socket

      {{:error, reason}, _shown} ->
        socket
        |> assign(:notice, %{for: socket.assigns.selected_id, reason: reason, identifier: issue.identifier})
        |> load()

      {_saved_elsewhere_or_unknown, _shown} ->
        socket
    end
  end

  defp finished_label(%Issue{state: :done, testing_state: :tested}), do: "was already marked tested"
  defp finished_label(%Issue{state: :done, testing_state: :sent_to_triage}), do: "was already sent to triage"
  defp finished_label(_moved_or_gone), do: "is no longer in Done"

  # Shown only out of the queue, where a Done ticket is Tested or Sent to triage.
  defp lock_label(%Issue{state: :done}), do: "Testing finished"
  defp lock_label(_not_done), do: "Not in Done"

  # The ticket the URL names, else the one already open, else the first in the queue. It stays open once it leaves the
  # queue; only a patch, which selects again, moves on from it.
  defp load(socket, mode \\ :keep) do
    socket = load_queue(socket)
    %{queue: queue, selected_id: selected_id, current_scope: scope, issue: shown} = socket.assigns
    open_id = if mode == :keep and shown, do: shown.id
    id = selected_id || open_id || (List.first(queue) && List.first(queue).id)

    # A ticket in a project the user cannot open is one that does not exist, as far as they can tell.
    issue =
      with id when is_binary(id) <- id,
           {:ok, issue} <- Issues.get_issue(id, preload: @preload),
           true <- Scope.can_access_project?(scope, issue.project_id) do
        issue
      else
        _not_found -> nil
      end

    same? = issue != nil and shown != nil and issue.id == shown.id
    socket = socket |> assign(:issue, issue) |> assign_issue_flags()

    # A picture or a reason started on another ticket, or on one testing has finished, has nowhere left to go.
    socket =
      if same? and socket.assigns.in_queue,
        do: socket,
        else: socket |> assign(:upload_targets, %{}) |> assign(:image_scenario_id, nil) |> assign(:reason_dialog, nil)

    socket = if same?, do: socket, else: socket |> assign(:blockers, nil) |> read_blockers() |> read_cycles()
    schedule_writing_end(socket)
  end

  # One timer per ticket and wait, so a ticket asked for again after a later merge gets a timer of its own.
  defp schedule_writing_end(%{assigns: %{issue: %Issue{id: id} = issue, writing: true, writing_timer: timer}} = socket) do
    deadline = Issue.calculate_writing_deadline(issue)

    if connected?(socket) and not match?({{^id, ^deadline}, _ref}, timer) do
      if timer, do: Process.cancel_timer(elem(timer, 1))
      wait = max(DateTime.diff(deadline, DateTime.utc_now(), :millisecond), 0) + 1_000
      assign(socket, :writing_timer, {{id, deadline}, Process.send_after(self(), {:writing_ended, id}, wait)})
    else
      socket
    end
  end

  defp schedule_writing_end(socket), do: socket

  defp load_queue(socket) do
    %{issues: queue} = Issues.list_issues(project_id: socket.assigns.project_filter, testing: true, preload: [:project])

    socket
    |> assign(:now, DateTime.utc_now())
    |> assign(:queue, queue)
  end

  defp assign_issue_flags(%{assigns: %{issue: issue}} = socket) do
    in_queue = issue != nil and Issue.in_testing_queue?(issue)
    writing = issue != nil and Issue.writing_scenarios?(issue)

    socket
    |> assign(:in_queue, in_queue)
    |> assign(:writing, writing)
    |> assign(:editable, in_queue and not writing)
    |> assign(:progress, issue && Issue.calculate_testing_progress(issue))
    |> assign(:can_send, in_queue and not writing and Issue.can_send_to_triage?(issue))
    |> assign(:can_mark, in_queue and not writing and Issue.can_mark_tested?(issue))
    |> assign(:send_title, send_title(issue, writing))
    |> assign(:mark_title, mark_title(issue, writing))
    |> assign(:show_empty, in_queue and not writing and issue.testing_scenarios == [])
    |> assign(:show_earlier_notes, earlier_notes?(issue))
    |> assign(:show_testing_state, issue != nil and issue.state == :done)
    |> assign(:lock_label, issue && lock_label(issue))
  end

  defp earlier_notes?(%Issue{testing_notes: notes, testing_images: images}),
    do: String.trim(notes || "") != "" or images != []

  defp earlier_notes?(nil), do: false

  defp send_title(_issue, true), do: "Rail is writing scenarios for this ticket"
  defp send_title(nil, false), do: nil

  defp send_title(%Issue{} = issue, false),
    do: if(Issue.can_send_to_triage?(issue), do: nil, else: "Mark a scenario Failed to send this to triage")

  defp mark_title(_issue, true), do: "Rail is writing scenarios for this ticket"
  defp mark_title(nil, false), do: nil

  defp mark_title(%Issue{} = issue, false),
    do: if(Issue.can_mark_tested?(issue), do: nil, else: "Mark tested is for when every scenario passed")

  # Read once connected and only when the open ticket or a blocker changes, so a testing save never reads them.
  defp read_blockers(%{assigns: %{issue: %Issue{} = issue}} = socket) do
    if connected?(socket) do
      start_async(socket, :blockers, fn ->
        {issue.id, Map.get(Issues.get_blockers([issue]), issue.id, %{blocked_by: [], blocks: []})}
      end)
    else
      socket
    end
  end

  defp read_blockers(socket), do: socket

  defp read_cycles(%{assigns: %{issue: %Issue{project: project}}} = socket) do
    {:ok, %{cycles: cycles}} = Issues.get_cycles(project)
    assign(socket, :cycles, cycles)
  end

  defp read_cycles(socket), do: assign(socket, :cycles, nil)
end
