defmodule RailWeb.Components.DesignOption do
  @moduledoc """
  One design option as Plan saved it: its page scaled into a frame, then its title, summary, Open, Good at, Costs and
  assumptions, or, with no option, that the change has no screen. Comments, picking and approving are the caller's
  slots, so a caller that passes none of them gets the option read-only, its frame taking no comments.
  """
  use RailWeb, :html

  alias Rail.Pipeline.Schemas.Task

  attr :id, :string, required: true, doc: "the no-screen state's; an option is named by its key"
  attr :task, Task, required: true
  attr :option, :map, default: nil, doc: "an option from `read_design/1`, or nil when the change has no screen"
  attr :picked, :boolean, default: false

  attr :comments, :map,
    default: nil,
    doc: "`%{commenting:, draft:, markers:, user_id:}` while the frame takes comments, or nil when it takes none"

  slot :control, doc: "what turns commenting on, over the frame"
  slot :box, doc: "the comment box, inside the frame"
  slot :pick, doc: "what picks this option, before Open"
  slot :note, doc: "said after the no-screen sentence"

  def design_option(%{option: nil} = assigns) do
    ~H"""
    <div
      id={@id}
      data-qa={String.replace(@id, "-", "_")}
      class="flex flex-col items-center text-center max-w-md mx-auto py-14"
    >
      <div class="flex items-center justify-center size-14 rounded-2xl bg-slate-100 dark:bg-slate-800 text-slate-400 ring-1 ring-slate-200 dark:ring-slate-700">
        <.icon name="pi-minus-circle" class="size-7" />
      </div>
      <h2 class="mt-5 text-base font-semibold text-slate-900 dark:text-slate-100">
        No screen in this change
      </h2>
      <p class="mt-2 text-sm leading-relaxed text-slate-500 dark:text-slate-400">
        Nothing anyone sees changes, so there are no design options. {render_slot(@note)}
      </p>
    </div>
    """
  end

  def design_option(assigns) do
    assigns =
      assign(assigns, :on, assigns.comments || %{commenting: false, draft: nil, markers: [], user_id: nil})

    ~H"""
    <div id={"design-option-#{@option.key}"} data-qa="design_option" class="flex flex-col gap-6">
      <div class="flex flex-col gap-2.5">
        {render_slot(@control)}

        <div
          id={"design-frame-#{@option.key}"}
          phx-hook="DesignFrame"
          data-comments={to_string(@comments != nil)}
          data-commenting={to_string(@on.commenting)}
          data-selected={@on.draft && @on.draft.selector}
          data-draft={@on.draft && Jason.encode!(Map.delete(@on.draft, :body))}
          data-draft-body={@on.draft && @on.draft.body}
          data-markers={Jason.encode!(@on.markers)}
          data-version={@option.html_version}
          data-task-id={@comments && @task.id}
          data-user-id={@on.user_id}
          data-conversation={@comments && "#conversation-tab-root"}
          class={[
            "relative w-full aspect-video overflow-hidden rounded-xl border border-slate-200 dark:border-slate-700 bg-white",
            @on.commenting &&
              "ring-2 ring-blue-500 ring-offset-2 ring-offset-white dark:ring-offset-slate-900 cursor-crosshair"
          ]}
        >
          <iframe
            :if={@option.html != nil}
            id={"design-page-#{@option.key}-#{@option.html_version}"}
            title={@option.title}
            sandbox="allow-scripts"
            src={frame_src(@task, @option, @comments)}
            class="absolute top-0 left-0 w-full h-full border-0"
          />
          <p
            :if={@option.html == nil}
            class="absolute inset-0 flex items-center justify-center text-xs text-slate-400"
          >
            This option has no page yet.
          </p>

          {render_slot(@box)}
        </div>
      </div>

      <div>
        <p
          :if={@picked}
          class="mb-2 inline-flex items-center gap-1.5 text-xs font-semibold text-emerald-600 dark:text-emerald-400"
        >
          <.icon name="pi-check-circle" class="size-4" /> Picked
        </p>
        <h2
          id="design-option-title"
          class="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100 wrap-break-word"
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

      <div class="flex items-center gap-3">
        {render_slot(@pick)}

        <a
          :if={@option.html != nil}
          id={"open-design-#{@option.key}"}
          href={~p"/tasks/#{@task.id}/design/#{@option.key}?v=#{@option.html_version}"}
          target="_blank"
          rel="noopener"
          class="inline-flex items-center gap-1.5 px-4 py-2.5 rounded-lg text-sm font-semibold border border-slate-300 dark:border-slate-600 text-slate-900 dark:text-slate-100 hover:bg-slate-50 dark:hover:bg-slate-800"
        >
          Open <.icon name="pi-arrow-up-right" class="size-4" />
        </a>
      </div>

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
        class="rounded-lg border border-slate-200 dark:border-slate-700 border-l-2 border-l-amber-400 dark:border-l-amber-400 bg-slate-50 dark:bg-slate-800/40 px-4 py-3 text-sm leading-relaxed text-slate-600 dark:text-slate-300 select-text wrap-break-word"
      >
        {@option.assumptions}
      </p>
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
          class="flex gap-3 text-sm leading-relaxed text-slate-700 dark:text-slate-200 select-text wrap-break-word"
        >
          <span class={["shrink-0 font-semibold", @sign_class]} aria-hidden="true">{@sign}</span>
          <span class="min-w-0">{item}</span>
        </li>
      </ul>
    </div>
    """
  end

  # The overlay that picks elements and draws markers goes in only while the frame takes comments.
  defp frame_src(task, option, nil), do: ~p"/tasks/#{task.id}/design/#{option.key}?v=#{option.html_version}"

  defp frame_src(task, option, _comments),
    do: ~p"/tasks/#{task.id}/design/#{option.key}?v=#{option.html_version}&comments=1"
end
