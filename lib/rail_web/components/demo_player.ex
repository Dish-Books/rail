defmodule RailWeb.Components.DemoPlayer do
  @moduledoc """
  Review's Demo item: the video, sized so it and the caption bar under it always fit and its column never scrolls,
  beside a walkthrough that scrolls on its own, follows playback and seeks the player. A stale demo offers Re-record,
  unless the task's workflow turned the demo off.
  """
  use RailWeb, :html

  alias Rail.Pipeline.Schemas.DemoBeat

  attr :task, :any, required: true
  attr :demo, :any, default: nil
  attr :beats, :list, required: true
  attr :recorded, :boolean, required: true
  attr :recording, :boolean, required: true

  attr :stale, :map,
    default: nil,
    doc: "`%{commit:, behind:}` when commits came after the recording; `behind` is nil when the branch lost it"

  attr :rerecordable, :boolean, default: false, doc: "the Review lead is idle and can be asked to record again"
  attr :off, :boolean, default: false, doc: "the task's workflow turned the demo off"
  attr :target, :any, default: nil

  def demo_player(assigns) do
    ~H"""
    <div
      id="review-demo"
      data-qa="review_demo"
      class="flex-1 min-w-0 min-h-0 flex flex-col"
    >
      <div class="h-12 shrink-0 flex items-center gap-2 px-5 border-b border-slate-200 dark:border-slate-700">
        <span class="text-sm font-bold text-slate-900 dark:text-slate-100">Demo</span>
        <span
          data-qa="review_demo_header"
          class="min-w-0 truncate text-xs text-slate-500 dark:text-slate-400"
        >
          {header(@recording, @recorded, @demo, @beats)}
        </span>
      </div>

      <p
        :if={not @recorded and not @recording and not @off}
        data-qa="review_demo_none"
        class="p-5 text-sm text-slate-500 dark:text-slate-400"
      >
        No demo was recorded. A change with nothing on screen gets none, and the demo recorder's take appears here once it is saved.
      </p>
      <p
        :if={not @recorded and not @recording and @off}
        id="review-demo-off"
        data-qa="review_demo_off"
        class="p-5 text-sm text-slate-500 dark:text-slate-400"
      >
        The demo is off for this workflow, so Review records none.
      </p>

      <%!-- The walkthrough scrolls on its own, so the video stays in view while it is read. --%>
      <div :if={@recorded or @recording} class="flex-1 min-h-0 p-5">
        <div class="h-full flex flex-col @4xl:flex-row-reverse gap-4 min-h-0">
          <div
            :if={@recorded}
            id="demo-player"
            data-qa="demo_player"
            class="flex-1 min-h-0 min-w-0 flex flex-col gap-3"
          >
            <div
              :if={@stale && not @recording}
              id="demo-stale"
              data-qa="demo_stale"
              class="shrink-0 flex flex-wrap items-center gap-x-3 gap-y-2 rounded-lg border border-slate-300 dark:border-slate-600 bg-slate-50 dark:bg-slate-800/60 px-3 py-2"
            >
              <.icon
                name="pi-clock-counter-clockwise"
                class="size-4 shrink-0 text-slate-500 dark:text-slate-300"
              />
              <p class="min-w-0 flex-1 text-[12.5px] text-slate-700 dark:text-slate-200">
                Recorded on
                <button
                  :if={@stale.behind}
                  type="button"
                  phx-click="open_diff"
                  phx-value-commit={@stale.commit}
                  phx-target={@target}
                  title={"Open #{String.slice(@stale.commit, 0, 7)} in Diff"}
                  class="font-mono text-blue-600 dark:text-blue-400 hover:underline cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
                >
                  {String.slice(@stale.commit, 0, 7)}
                </button><span :if={is_nil(@stale.behind)} class="font-mono">{String.slice(@stale.commit, 0, 7)}</span>{if @stale.behind,
                  do: ", #{commits(@stale.behind)} ago",
                  else: ", which the branch no longer has"}; may be out of date
              </p>
              <button
                :if={not @off}
                type="button"
                id="demo-rerecord"
                data-qa="demo_rerecord"
                phx-click="record_demo"
                phx-target={@target}
                disabled={not @rerecordable}
                title={
                  if not @rerecordable, do: "The Review lead is working; Re-record once it stops"
                }
                class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg border border-slate-300 dark:border-slate-600 text-xs font-semibold text-slate-700 dark:text-slate-200 hover:bg-slate-50 dark:hover:bg-slate-800 cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
              >
                <.icon name="pi-record-fill" class="size-3.5 text-red-500" />Re-record
              </button>
            </div>

            <div :if={@demo} class="shrink-0 space-y-1.5">
              <h2
                :if={@demo.title}
                data-qa="demo_title"
                class="text-base font-bold text-slate-900 dark:text-slate-100 wrap-anywhere"
              >
                {@demo.title}
              </h2>
              <p
                data-qa="demo_summary"
                class="text-sm text-slate-600 dark:text-slate-300 leading-relaxed wrap-anywhere"
              >
                {@demo.summary}
              </p>
            </div>

            <p
              :if={@demo && @demo.not_shown}
              data-qa="demo_not_shown"
              class="shrink-0 rounded-lg border border-amber-200 bg-amber-50 dark:border-amber-900 dark:bg-amber-950 p-3 text-xs text-amber-800 dark:text-amber-300 wrap-anywhere"
            >
              Not shown: {@demo.not_shown}
            </p>

            <%!-- As wide as the column allows while the video and a one-line caption bar fit the height left. --%>
            <div class="flex-1 min-h-0 [container-type:size]">
              <div
                id="demo-video-frame"
                phx-hook="DemoCaptions"
                phx-update="ignore"
                data-beats={Jason.encode!(Enum.map(@beats, &%{at_ms: &1.at_ms, text: &1.text}))}
                class="mx-auto w-[min(100cqw,calc((100cqh_-_3.25rem_-_2px)*16/9))] overflow-hidden rounded-xl border border-slate-200 dark:border-slate-700"
              >
                <video
                  id="demo-video"
                  data-qa="demo_video"
                  controls
                  preload="metadata"
                  data-src={~p"/tasks/#{@task.id}/demo/video"}
                  class="block w-full aspect-video bg-slate-900"
                />
                <p
                  id="demo-caption"
                  data-qa="demo_caption"
                  class="min-h-[3.25rem] flex items-center justify-center px-4 py-3 border-t border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-800/60 text-center text-sm font-medium text-slate-900 dark:text-slate-100"
                >
                </p>
              </div>
            </div>
          </div>

          <div
            id="demo-beats"
            data-qa="demo_beats"
            class={[
              "min-h-0 overflow-y-auto @4xl:flex-none @4xl:w-[280px] @4xl:max-h-none",
              if(@recorded, do: "max-h-[33%] shrink-0", else: "flex-1")
            ]}
          >
            <p class="px-2.5 pb-2 text-[10.5px] font-extrabold uppercase tracking-[0.14em] text-slate-400 dark:text-slate-500">
              {if @recording, do: "Narrated so far", else: "Walkthrough"}
            </p>
            <p
              :if={@beats == []}
              data-qa="demo_no_beats"
              class="px-2.5 text-xs text-slate-500 dark:text-slate-400"
            >
              Nothing narrated yet.
            </p>
            <div class="space-y-1">
              <button
                :for={beat <- @beats}
                type="button"
                id={"demo-beat-#{beat.at_ms}"}
                data-qa="demo_beat"
                data-at-ms={beat.at_ms}
                class="w-full rounded-lg px-2.5 py-2 text-left cursor-pointer hover:bg-slate-100 dark:hover:bg-slate-800 aria-current:bg-blue-50 dark:aria-current:bg-blue-950 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
              >
                <span class="block font-mono text-[10.5px] text-slate-400 dark:text-slate-500">{DemoBeat.stamp(
                  beat
                )}</span>
                <span class="block text-[13px] text-slate-900 dark:text-slate-100 leading-snug wrap-anywhere">{beat.text}</span>
                <span
                  :if={beat.criterion}
                  data-qa="demo_beat_criterion"
                  class="mt-1 block text-[11px] italic text-slate-500 dark:text-slate-400 leading-snug wrap-anywhere"
                >
                  {beat.criterion}
                </span>
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp commits(1), do: "1 commit"
  defp commits(count), do: "#{count} commits"

  defp header(true, _recorded, _demo, [_one]), do: "Recording · 1 beat said so far"
  defp header(true, _recorded, _demo, beats), do: "Recording · #{length(beats)} beats said so far"

  defp header(false, false, _demo, _beats), do: "None recorded"

  defp header(false, true, %{commit: commit}, _beats) when is_binary(commit),
    do: "Recorded on #{String.slice(commit, 0, 7)}"

  defp header(false, true, _demo, _beats), do: "Recorded"
end
