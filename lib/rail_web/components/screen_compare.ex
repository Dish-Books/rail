defmodule RailWeb.Components.ScreenCompare do
  @moduledoc """
  Review's Screens item: a header row with how many screen states there are and the commit the latest was
  taken on, then a grid of each state's latest shot with its commit, label and how many earlier. A state
  opened sets its latest shot beside an earlier commit's, picked from a list, with the findings citing it.
  """
  use RailWeb, :html

  attr :task_id, :string, required: true
  attr :screens, :list, required: true, doc: "the screen states as `Rail.Pipeline.list_screens/1` reads them"
  attr :labels, :map, default: %{}, doc: "each commit on the branch to what made it"
  attr :open, :string, default: nil, doc: "the key of the state opened"
  attr :earlier, :integer, default: nil, doc: "the index of the earlier shot set beside the latest"
  attr :target, :any, required: true

  def screen_compare(assigns) do
    assigns =
      assigns
      |> assign(:latest, latest(assigns.screens))
      |> assign(:opened, Enum.find(assigns.screens, &(&1.key == assigns.open)))

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
          · latest taken on {short(@latest.commit)}
        </span>
      </div>

      <p
        :if={@screens == []}
        data-qa="review_screens_none"
        class="p-5 text-sm text-slate-500 dark:text-slate-400"
      >
        No screens yet. The explorers shoot every screen state the change affects each round, and they appear here.
      </p>

      <div :if={@screens != [] and is_nil(@opened)} class="p-5">
        <div class="grid gap-3 grid-cols-1 @md:grid-cols-2 @3xl:grid-cols-3">
          <button
            :for={screen <- @screens}
            type="button"
            id={"screen-#{screen.key}"}
            data-qa="screen_card"
            aria-current="false"
            phx-click="open_screen"
            phx-value-key={screen.key}
            phx-target={@target}
            class="min-w-0 text-left rounded-xl border p-2 border-slate-200 dark:border-slate-700 hover:border-slate-400 dark:hover:border-slate-500 bg-white dark:bg-slate-900 cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
          >
            <.shot task_id={@task_id} screen={screen} shot={List.last(screen.shots)} />
            <span class="mt-2 block truncate text-[12.5px] font-semibold text-slate-900 dark:text-slate-100">
              {screen.label}
            </span>
            <span class="mt-0.5 flex items-center gap-1.5 min-w-0 text-[11px] text-slate-500 dark:text-slate-400">
              <.commit commit={List.last(screen.shots).commit} labels={@labels} />
              <span :if={length(screen.shots) > 1} class="ml-auto shrink-0">
                {length(screen.shots) - 1} earlier
              </span>
            </span>
          </button>
        </div>
      </div>

      <div
        :if={@opened}
        id={"screen-open-#{@opened.key}"}
        data-qa="screen_open"
        phx-window-keydown="close_screen"
        phx-key="Escape"
        phx-target={@target}
        class="p-5 flex flex-col gap-3 min-h-0"
      >
        <div class="flex flex-wrap items-center gap-x-3 gap-y-2 min-w-0">
          <p class="min-w-0 truncate text-sm font-bold text-slate-900 dark:text-slate-100">
            {@opened.label}
          </p>
          <button
            :for={finding <- @opened.findings}
            type="button"
            data-qa="screen_finding"
            phx-click="open_finding"
            phx-value-key={finding.key}
            phx-target={@target}
            class="min-w-0 inline-flex items-center gap-1 text-[11.5px] font-semibold text-blue-600 dark:text-blue-400 hover:underline cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
          >
            <.icon name="pi-warning-circle" class="size-[13px] shrink-0" /><span class="truncate">{finding.title}</span>
          </button>
          <button
            type="button"
            id="screen-close"
            data-qa="screen_close"
            phx-click="close_screen"
            phx-target={@target}
            class="ml-auto inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg border border-slate-300 dark:border-slate-600 text-xs font-semibold text-slate-700 dark:text-slate-200 hover:bg-slate-50 dark:hover:bg-slate-800 cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
          >
            Close
          </button>
        </div>

        <div class="grid grid-cols-1 @3xl:grid-cols-2 gap-3">
          <figure
            :if={@earlier && Enum.at(@opened.shots, @earlier)}
            data-qa="screen_earlier"
            class="min-w-0"
          >
            <figcaption class="mb-1.5 flex items-center gap-2 min-w-0 text-[11.5px] text-slate-500 dark:text-slate-400">
              <span class="shrink-0 font-semibold text-slate-700 dark:text-slate-200">Earlier</span>
              <form
                id="screen-earlier-form"
                phx-change="pick_earlier"
                phx-target={@target}
                class="min-w-0"
              >
                <select
                  name="index"
                  aria-label="Earlier shot"
                  class="min-w-0 max-w-full rounded-md border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-800 px-1.5 py-0.5 font-mono text-[11px] text-slate-700 dark:text-slate-200"
                >
                  <option
                    :for={shot <- Enum.drop(@opened.shots, -1)}
                    value={shot.index}
                    selected={shot.index == @earlier}
                  >
                    {option(shot, @labels)}
                  </option>
                </select>
              </form>
              <.local_time
                id={"screen-earlier-at-#{@earlier}"}
                at={Enum.at(@opened.shots, @earlier).taken_at}
                class="truncate"
              />
            </figcaption>
            <.shot task_id={@task_id} screen={@opened} shot={Enum.at(@opened.shots, @earlier)} />
          </figure>

          <figure data-qa="screen_latest" class="min-w-0">
            <figcaption class="mb-1.5 flex items-center gap-2 min-w-0 text-[11.5px] text-slate-500 dark:text-slate-400">
              <span class="shrink-0 font-semibold text-slate-700 dark:text-slate-200">Latest</span>
              <.commit commit={List.last(@opened.shots).commit} labels={@labels} />
              <.local_time
                id="screen-latest-at"
                at={List.last(@opened.shots).taken_at}
                class="truncate"
              />
            </figcaption>
            <.shot task_id={@task_id} screen={@opened} shot={List.last(@opened.shots)} />
          </figure>
        </div>

        <p :if={is_nil(@earlier)} class="text-xs text-slate-500 dark:text-slate-400">
          No earlier shot: this state was taken on one commit so far.
        </p>
      </div>
    </div>
    """
  end

  attr :task_id, :string, required: true
  attr :screen, :map, required: true
  attr :shot, :map, required: true

  defp shot(assigns) do
    ~H"""
    <img
      src={~p"/tasks/#{@task_id}/screens/#{@screen.key}/#{@shot.index}"}
      alt={@screen.label}
      loading="lazy"
      class="block w-full aspect-[16/10] object-cover object-top rounded-lg border border-slate-200 dark:border-slate-700 bg-slate-100 dark:bg-slate-800"
    />
    """
  end

  attr :commit, :string, default: nil
  attr :labels, :map, required: true

  defp commit(assigns) do
    ~H"""
    <span :if={@commit} class="shrink-0 font-mono">{short(@commit)}</span>
    <span :if={@labels[@commit]} class="min-w-0 truncate">{@labels[@commit]}</span>
    """
  end

  defp latest([]), do: nil
  defp latest(screens), do: screens |> Enum.map(&List.last(&1.shots)) |> Enum.max_by(& &1.taken_at, DateTime)

  defp option(%{commit: commit}, labels) when is_binary(commit),
    do: Enum.join(Enum.filter([short(commit), labels[commit]], & &1), " ")

  defp option(shot, _labels), do: "Shot #{shot.index + 1}"

  defp short(commit), do: String.slice(commit, 0, 7)
end
