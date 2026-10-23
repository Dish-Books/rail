defmodule RailWeb.Components.ScreenGrid do
  @moduledoc """
  Review's Screens item: how many screen states there are and the commit the latest shot was taken on, then a card
  of each state's one shot with its label and commit, and how many of the reader's comments on it are not sent. A
  card opens the state in the screen view, and is where focus goes back to when it closes.
  """
  use RailWeb, :html

  attr :task_id, :string, required: true
  attr :screens, :list, required: true, doc: "the screen states as `Rail.Pipeline.list_screens/1` reads them"
  attr :labels, :map, default: %{}, doc: "each commit on the branch to what made it"
  attr :unsent, :map, default: %{}, doc: "each state's key to how many of the reader's comments on it are not sent"
  attr :target, :any, required: true

  def screen_grid(assigns) do
    assigns =
      assign(assigns, :latest, if(assigns.screens != [], do: Enum.max_by(assigns.screens, & &1.taken_at, DateTime)))

    ~H"""
    <div
      id="review-screens"
      data-qa="review_screens"
      class="@container flex-1 min-w-0 min-h-0 flex flex-col overflow-y-auto"
    >
      <div class="h-12 shrink-0 flex items-center gap-2 px-5 border-b border-slate-200 dark:border-slate-700">
        <span class="text-sm font-bold text-slate-900 dark:text-slate-100">Screens</span>
        <span data-qa="review_screens_count" class="text-xs text-slate-500 dark:text-slate-400">
          {length(@screens)}
        </span>
        <span
          :if={@latest && @latest.commit}
          data-qa="review_screens_on"
          class="min-w-0 truncate text-xs text-slate-500 dark:text-slate-400"
        >
          · latest taken on {String.slice(@latest.commit, 0, 7)}
        </span>
      </div>

      <p
        :if={@screens == []}
        data-qa="review_screens_none"
        class="p-5 text-sm text-slate-500 dark:text-slate-400"
      >
        No screens yet. QA shoots every screen state the change affects each round, and they appear here.
      </p>

      <div :if={@screens != []} class="p-5">
        <div class="grid gap-3 grid-cols-1 @md:grid-cols-2 @3xl:grid-cols-3">
          <button
            :for={screen <- @screens}
            type="button"
            id={"screen-#{screen.key}"}
            data-qa="screen_card"
            phx-click="open_screen"
            phx-value-key={screen.key}
            phx-target={@target}
            class="min-w-0 text-left rounded-xl border p-2 border-slate-200 dark:border-slate-700 hover:border-slate-400 dark:hover:border-slate-500 bg-white dark:bg-slate-900 cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
          >
            <span class="relative block">
              <img
                src={
                  ~p"/tasks/#{@task_id}/screens/#{screen.key}?#{[at: DateTime.to_unix(screen.taken_at, :microsecond)]}"
                }
                alt={screen.label}
                loading="lazy"
                class="block w-full aspect-[16/10] object-cover object-top rounded-lg border border-slate-200 dark:border-slate-700 bg-slate-100 dark:bg-slate-800"
              />
              <span
                :if={@unsent[screen.key]}
                data-qa="screen_card_unsent"
                class="absolute top-2 left-2 inline-flex items-center gap-1 rounded-full bg-amber-100 dark:bg-amber-950 px-2 py-0.5 text-[11px] font-semibold text-amber-800 dark:text-amber-300 ring-1 ring-amber-300/40"
              >
                <.icon name="pi-chat-text-fill" class="size-3" />{@unsent[screen.key]} not sent
              </span>
            </span>
            <span class="mt-2 block truncate text-[12.5px] font-semibold text-slate-900 dark:text-slate-100">
              {screen.label}
            </span>
            <span class="mt-0.5 flex items-center gap-1.5 min-w-0 text-[11px] text-slate-500 dark:text-slate-400">
              <span :if={screen.commit} class="shrink-0 font-mono">{String.slice(screen.commit, 0, 7)}</span>
              <span :if={@labels[screen.commit]} class="min-w-0 truncate">{@labels[screen.commit]}</span>
            </span>
          </button>
        </div>
      </div>
    </div>
    """
  end
end
