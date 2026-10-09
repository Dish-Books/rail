defmodule RailWeb.Components.DemoPlayer do
  @moduledoc """
  Review's Demo item: a header row saying what the demo was recorded on, then the video with its caption
  bar beneath it, never over it, and the walkthrough beside it. Each beat seeks the player to the moment
  it was said, and one that proves an acceptance criterion quotes it.
  """
  use RailWeb, :html

  alias Rail.Pipeline.Schemas.DemoBeat

  attr :task, :any, required: true
  attr :demo, :any, default: nil
  attr :beats, :list, required: true
  attr :recorded, :boolean, required: true
  attr :recording, :boolean, required: true

  def demo_player(assigns) do
    ~H"""
    <div
      id="review-demo"
      data-qa="review_demo"
      class="flex-1 min-w-0 min-h-0 flex flex-col overflow-y-auto"
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
        :if={not @recorded and not @recording}
        data-qa="review_demo_none"
        class="p-5 text-sm text-slate-500 dark:text-slate-400"
      >
        No demo was recorded. A change with nothing on screen gets none, and the demo recorder's take appears here once it is saved.
      </p>

      <div :if={@recorded or @recording} class="p-5">
        <div class="flex flex-col @4xl:flex-row gap-4 min-h-0">
          <div :if={@recorded} id="demo-player" data-qa="demo_player" class="flex-1 min-w-0 space-y-3">
            <div :if={@demo} class="space-y-1.5">
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

            <div
              id="demo-video-frame"
              phx-hook="DemoCaptions"
              phx-update="ignore"
              data-beats={Jason.encode!(Enum.map(@beats, &%{at_ms: &1.at_ms, text: &1.text}))}
              class="overflow-hidden rounded-xl border border-slate-200 dark:border-slate-700"
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

            <p
              :if={@demo && @demo.not_shown}
              data-qa="demo_not_shown"
              class="rounded-lg border border-amber-200 bg-amber-50 dark:border-amber-900 dark:bg-amber-950 p-3 text-xs text-amber-800 dark:text-amber-300 wrap-anywhere"
            >
              Not shown: {@demo.not_shown}
            </p>
          </div>

          <div id="demo-beats" data-qa="demo_beats" class="@4xl:w-[280px] shrink-0">
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

  defp header(true, _recorded, _demo, [_one]), do: "Recording · 1 beat said so far"
  defp header(true, _recorded, _demo, beats), do: "Recording · #{length(beats)} beats said so far"

  defp header(false, false, _demo, _beats), do: "None recorded"

  defp header(false, true, %{commit: commit}, _beats) when is_binary(commit),
    do: "Recorded on #{String.slice(commit, 0, 7)}"

  defp header(false, true, _demo, _beats), do: "Recorded"
end
