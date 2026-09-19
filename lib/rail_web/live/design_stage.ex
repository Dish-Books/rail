defmodule RailWeb.Live.DesignStage do
  @moduledoc """
  The designer's three options, the pick between them, and the approval of the
  one the human refined.

  The options are compared one at a time: a tab per option across the top, the
  selected option's live page at full width below them, and under it what the
  option is good at, what it costs and what it assumed. The page is what the
  designer wrote, updated as the conversation changes it. Once an option is
  picked the tabs go, what is left is the pick alone, and approving it moves to
  the header alongside every other action on the task.
  """
  use RailWeb, :live_component

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task

  @impl true
  def update(assigns, socket) do
    design = Pipeline.read_design(assigns.task)

    socket =
      socket
      |> assign(assigns)
      |> assign(:design, design)
      |> assign_new(:error, fn -> nil end)
      |> assign_new(:selected_key, fn -> nil end)

    {:ok, assign(socket, :selected_key, selected_key(design, socket.assigns.selected_key))}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :option, shown_option(assigns.design, assigns.selected_key))

    ~H"""
    <div id="design-stage" data-qa="design-stage" class="contents">
      <.task_layout task={@task} run={@run} title={@task.issue.title}>
        <:tabs>{render_slot(@tabs)}</:tabs>

        <:actions>
          {render_slot(@actions)}

          <a
            :if={@design != nil and @design.picked != nil and @option != nil and @option.html != nil}
            id={"open-design-#{@option.key}"}
            href={~p"/tasks/#{@task.id}/design/#{@option.key}"}
            target="_blank"
            rel="noopener"
            class="inline-flex items-center gap-1.5 px-4 py-2 rounded-lg text-sm font-semibold border border-slate-300 dark:border-slate-600 text-slate-900 dark:text-slate-100 hover:bg-slate-50 dark:hover:bg-slate-800"
          >
            Open <.icon name="pi-arrow-up-right" class="size-4" />
          </a>

          <button
            :if={@approvable and @design != nil and @design.picked != nil and @option != nil}
            type="button"
            id="approve-design"
            data-qa="approve_design"
            phx-click="approve"
            phx-target={@myself}
            class="px-4 py-2 rounded-lg text-sm font-semibold bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 cursor-pointer shadow-xs"
          >
            Approve design
          </button>
        </:actions>

        <:alerts :if={@error}>
          <p id="design-error" data-qa="design_error" class="text-xs text-red-600 dark:text-red-500">
            {@error}
          </p>
        </:alerts>

        <.design_pending :if={@option == nil} running={Run.running?(@run)} />

        <div
          :if={@option != nil}
          id="design-options"
          data-qa="design_options"
          class={[
            "@container flex flex-col gap-6",
            @design.picked == nil &&
              "rounded-2xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900/60 p-4 sm:p-6"
          ]}
        >
          <div
            :if={@design.picked == nil}
            role="tablist"
            aria-label="Design options"
            class="grid grid-cols-3 gap-2 @2xl:gap-3"
          >
            <button
              :for={option <- @design.options}
              type="button"
              role="tab"
              id={"design-tab-#{option.key}"}
              data-qa="design_tab"
              aria-selected={to_string(option.key == @option.key)}
              phx-click="select"
              phx-value-key={option.key}
              phx-target={@myself}
              class={[
                "flex items-center gap-3 min-w-0 p-2 @2xl:p-3 rounded-xl border text-left transition-colors cursor-pointer",
                option.key == @option.key &&
                  "border-slate-400 bg-slate-100 dark:border-slate-500 dark:bg-slate-800",
                option.key != @option.key &&
                  "border-slate-200 dark:border-slate-700 hover:bg-slate-50 dark:hover:bg-slate-800/50"
              ]}
            >
              <img
                :if={option.screenshot_version}
                src={
                  ~p"/tasks/#{@task.id}/design/#{option.key}/screenshot?v=#{option.screenshot_version}"
                }
                alt=""
                class="hidden @2xl:block w-20 shrink-0 aspect-video rounded-md object-cover object-top border border-slate-200 dark:border-slate-700 bg-white"
              />
              <span
                :if={option.screenshot_version == nil}
                class="hidden @2xl:block w-20 shrink-0 aspect-video rounded-md border border-dashed border-slate-300 dark:border-slate-700"
              />
              <span class="min-w-0">
                <span class="block text-sm font-semibold text-slate-900 dark:text-slate-100 truncate">
                  {option.title}
                </span>
                <span class="block font-mono text-xs text-slate-500 dark:text-slate-400 truncate">
                  {option.key}
                </span>
              </span>
            </button>
          </div>

          <div
            id={"design-option-#{@option.key}"}
            data-qa="design_option"
            class="flex flex-col gap-6"
          >
            <.design_frame option={@option} />

            <div class="flex flex-col gap-6">
              <div class="flex flex-col gap-5 min-w-0">
                <div>
                  <p
                    :if={@design.picked != nil}
                    class="mb-2 inline-flex items-center gap-1.5 text-xs font-semibold text-emerald-600 dark:text-emerald-400"
                  >
                    <.icon name="pi-check-circle" class="size-4" /> Picked
                  </p>
                  <h2
                    id="design-option-title"
                    class="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100"
                  >
                    {@option.title}
                  </h2>
                  <p
                    :if={@option.summary != ""}
                    class="mt-2 text-sm leading-relaxed text-slate-600 dark:text-slate-300 select-text"
                  >
                    {@option.summary}
                  </p>
                </div>
              </div>

              <div
                :if={@option.good_at != [] or @option.costs != [] or @option.assumptions != ""}
                class="flex flex-col gap-5 min-w-0"
              >
                <.tradeoffs
                  :if={@option.good_at != []}
                  id="design-good-at"
                  label="Good at"
                  items={@option.good_at}
                  sign="+"
                  sign_class="text-emerald-600 dark:text-emerald-400"
                />

                <.tradeoffs
                  :if={@option.costs != []}
                  id="design-costs"
                  label="Costs"
                  items={@option.costs}
                  sign="−"
                  sign_class="text-rose-600 dark:text-rose-400"
                />

                <p
                  :if={@option.assumptions != ""}
                  id="design-assumptions"
                  class="rounded-lg border border-slate-200 dark:border-slate-700 border-l-2 border-l-amber-400 dark:border-l-amber-400 bg-slate-50 dark:bg-slate-800/40 px-4 py-3 text-sm leading-relaxed text-slate-600 dark:text-slate-300 select-text"
                >
                  {@option.assumptions}
                </p>
              </div>

              <div :if={@design.picked == nil} class="flex items-stretch gap-3">
                <button
                  :if={@approvable}
                  type="button"
                  id={"pick-design-#{@option.key}"}
                  data-qa="pick_design"
                  phx-click="pick"
                  phx-value-key={@option.key}
                  phx-target={@myself}
                  class="flex-1 px-4 py-2.5 rounded-lg text-sm font-semibold bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 cursor-pointer shadow-xs"
                >
                  Use this design
                </button>

                <a
                  :if={@option.html != nil}
                  id={"open-design-#{@option.key}"}
                  href={~p"/tasks/#{@task.id}/design/#{@option.key}"}
                  target="_blank"
                  rel="noopener"
                  class="inline-flex items-center gap-1.5 px-4 py-2.5 rounded-lg text-sm font-semibold border border-slate-300 dark:border-slate-600 text-slate-900 dark:text-slate-100 hover:bg-slate-50 dark:hover:bg-slate-800"
                >
                  Open <.icon name="pi-arrow-up-right" class="size-4" />
                </a>
              </div>
            </div>
          </div>
        </div>

        <:sidebar>{render_slot(@sidebar)}</:sidebar>
      </.task_layout>
    </div>
    """
  end

  @impl true
  def handle_event("select", %{"key" => key}, socket) do
    {:noreply, assign(socket, :selected_key, selected_key(socket.assigns.design, key))}
  end

  def handle_event("pick", %{"key" => key}, socket) do
    socket.assigns.run |> Pipeline.pick_design_option(key) |> respond(socket)
  end

  def handle_event("approve", _params, socket) do
    socket.assigns.run |> Pipeline.approve_design() |> respond(socket)
  end

  attr :running, :boolean, required: true

  # Nothing to pick from yet. While the designer works, the three empty frames say
  # what is coming and where; once it has stopped, the chat is where it resumes.
  defp design_pending(assigns) do
    ~H"""
    <div
      id="design-pending"
      data-qa="design_pending"
      class="flex flex-col items-center gap-10 py-10"
    >
      <div class="flex flex-col items-center text-center max-w-md">
        <div class="relative flex items-center justify-center size-14 rounded-2xl bg-blue-50 dark:bg-blue-950 text-blue-600 dark:text-blue-400 ring-1 ring-blue-100 dark:ring-blue-900">
          <span
            :if={@running}
            class="absolute inset-0 rounded-2xl ring-2 ring-blue-400/40 motion-safe:animate-ping"
          />
          <.icon name={if @running, do: "pi-palette", else: "pi-paint-brush"} class="size-7" />
        </div>

        <h2
          id="design-pending-title"
          class="mt-5 text-base font-semibold text-slate-900 dark:text-slate-100"
        >
          {if @running, do: "Designing three options", else: "No design options yet"}
        </h2>

        <p :if={@running} class="mt-2 text-sm leading-relaxed text-slate-500 dark:text-slate-400">
          The designer is reading the ticket and the screens it touches, then mocking up
          three different directions. They appear here once all three are ready.
        </p>

        <p :if={not @running} class="mt-2 text-sm leading-relaxed text-slate-500 dark:text-slate-400">
          The designer stopped before writing its options. Send it a message in the
          conversation to pick up where it left off.
        </p>
      </div>

      <div class="grid w-full grid-cols-1 xl:grid-cols-3 gap-6" aria-hidden="true">
        <div :for={_placeholder <- 1..3} class="flex flex-col gap-3">
          <div class={[
            "w-full aspect-video rounded-xl border border-dashed border-slate-300 dark:border-slate-700 bg-slate-50 dark:bg-slate-900",
            @running && "motion-safe:animate-pulse"
          ]} />
          <div class="space-y-2">
            <div class="h-3 w-1/3 rounded bg-slate-200 dark:bg-slate-800" />
            <div class="h-2.5 w-2/3 rounded bg-slate-100 dark:bg-slate-800/60" />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :items, :list, required: true
  attr :sign, :string, required: true
  attr :sign_class, :string, required: true

  defp tradeoffs(assigns) do
    ~H"""
    <div id={@id}>
      <h3 class="text-xs font-semibold uppercase tracking-wider text-slate-500 dark:text-slate-400">
        {@label}
      </h3>
      <ul class="mt-2 space-y-2">
        <li
          :for={item <- @items}
          class="flex gap-3 text-sm leading-relaxed text-slate-700 dark:text-slate-200 select-text"
        >
          <span class={["shrink-0 font-semibold", @sign_class]} aria-hidden="true">{@sign}</span>
          <span>{item}</span>
        </li>
      </ul>
    </div>
    """
  end

  attr :option, :map, required: true

  # The page is sandboxed without its origin: it can run the scripts a mockup
  # needs, and nothing of Rail's.
  defp design_frame(assigns) do
    ~H"""
    <div
      id={"design-frame-#{@option.key}"}
      phx-hook="DesignFrame"
      class="relative w-full aspect-video overflow-hidden rounded-xl border border-slate-200 dark:border-slate-700 bg-white"
    >
      <iframe
        :if={@option.html != nil}
        title={@option.title}
        sandbox="allow-scripts"
        srcdoc={@option.html}
        class="absolute top-0 left-0 w-full h-full border-0"
      />
      <p
        :if={@option.html == nil}
        class="absolute inset-0 flex items-center justify-center text-xs text-slate-400"
      >
        This option has no page yet.
      </p>
    </div>
    """
  end

  # The pick, once there is one; otherwise the option the human is looking at,
  # which stays put across refreshes while it still exists.
  defp selected_key(nil, _selected), do: nil
  defp selected_key(%{picked: picked}, _selected) when is_binary(picked), do: picked

  defp selected_key(%{options: options}, selected) do
    case Enum.find(options, &(&1.key == selected)) || List.first(options) do
      %{key: key} -> key
      nil -> nil
    end
  end

  defp shown_option(nil, _key), do: nil
  defp shown_option(%{options: options}, key), do: Enum.find(options, &(&1.key == key))

  defp respond({:ok, _run}, socket) do
    send(self(), :task_changed)
    {:noreply, assign(socket, :error, nil)}
  end

  defp respond({:error, reason}, socket), do: {:noreply, assign(socket, :error, message_for(reason))}

  defp message_for(:stage_running), do: "Something is still running on this task."
  defp message_for({:invalid_stage, stage}), do: "This task is at #{Task.stage_label(stage)}, not design."
  defp message_for(:already_picked), do: "A design has already been picked."
  defp message_for(:design_not_found), do: "The designer has not written any options yet."
  defp message_for(:option_not_found), do: "That design option no longer exists."
  defp message_for(:chat_unavailable), do: "The designer cannot be messaged yet."
  defp message_for(:nothing_picked), do: "Pick a design before approving it."
  defp message_for(:screenshot_missing), do: "The picked design has no screenshot yet."
  defp message_for(:stale_screenshot), do: "The screenshot is older than the design. Ask the designer to retake it."
  # coveralls-ignore-start (a refusal nobody has written a sentence for yet)
  defp message_for(reason), do: "Could not update the design: #{inspect(reason)}"
  # coveralls-ignore-stop
end
