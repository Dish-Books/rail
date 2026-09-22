defmodule RailWeb.Live.DemoStage do
  @moduledoc """
  The walkthrough a demo run recorded, watched the way the person it was made for
  will watch it.

  One video and a list of beats beside it. The beats are the captions the agent
  narrated, each stamped at the moment in the recording it belongs to: clicking
  one seeks there, and the one currently playing is the one highlighted. That
  list is also the answer to whether the ticket was covered, because a beat that
  proves an acceptance criterion quotes it.

  The caption is never drawn over the frame. It has a bar of its own underneath
  the video and the bar is always there, empty or not, so the layout does not
  move when a beat changes and nothing ever sits between the viewer and the
  application. That is the whole reason this stage exists - a recording with a
  caption over the bottom of it is a recording of most of the screen.

  While the recording is being made, the video does not exist yet, so what is
  shown instead is the browser it is being made from: the same live screencast
  the QA panel watches, with the beats landing underneath it as they are
  narrated. A recording that stalls stalls somewhere a person can see.

  A demo gates nothing and concludes nothing, so there is no button here and no
  verdict read off it. It is where a task stops, and what a person does with what
  they watched is not yet Rail's to carry.
  """
  use RailWeb, :live_component

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.DemoBeat
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task

  @impl true
  def update(assigns, socket) do
    {:ok, load(assign(socket, assigns))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="demo-stage" data-qa="demo-stage" class="contents">
      <.task_layout task={@task} run={@run} title={@task.issue.title} flush>
        <:tabs>{render_slot(@tabs)}</:tabs>

        <:actions>{render_slot(@actions)}</:actions>

        <div id="demo-stage-body" class="h-full flex flex-col min-h-0">
          <div class="flex-1 min-h-0 flex flex-col lg:flex-row">
            <.beat_list beats={@beats} running={@running} />

            <div class="flex-1 min-w-0 flex flex-col min-h-0">
              <.recording :if={@running} driving={@driving} />

              <.player :if={not @running and @recorded} task={@task} demo={@demo} beats={@beats} />

              <.nothing_recorded :if={not @running and not @recorded} run={@run} />
            </div>
          </div>
        </div>

        <:sidebar>{render_slot(@sidebar)}</:sidebar>
      </.task_layout>
    </div>
    """
  end

  attr :beats, :list, required: true
  attr :running, :boolean, required: true

  # What the walkthrough says, in order, whether or not there is a video yet.
  # Each row seeks the player rather than being a link to anything - the video is
  # the artifact and this is an index into it.
  defp beat_list(assigns) do
    ~H"""
    <div
      id="demo-beats"
      data-qa="demo_beats"
      class="w-full lg:w-[340px] shrink-0 flex flex-col min-h-0 border-b lg:border-b-0 lg:border-r border-slate-200 dark:border-slate-700"
    >
      <p class="shrink-0 px-4 py-3 text-[10.5px] font-extrabold uppercase tracking-[0.14em] text-slate-400 dark:text-slate-500">
        {if @running, do: "Narrated so far", else: "Walkthrough"}
      </p>

      <div class="flex-1 min-h-0 overflow-y-auto px-2 pb-3 space-y-1">
        <p
          :if={@beats == []}
          data-qa="demo_no_beats"
          class="px-2 py-3 text-xs text-slate-500 dark:text-slate-400"
        >
          Nothing narrated yet.
        </p>

        <button
          :for={beat <- @beats}
          type="button"
          id={"demo-beat-#{beat.at_ms}"}
          data-qa="demo_beat"
          data-at-ms={beat.at_ms}
          class="w-full rounded-lg px-2.5 py-2 text-left cursor-pointer hover:bg-slate-100 dark:hover:bg-slate-800 aria-current:bg-blue-50 dark:aria-current:bg-blue-950"
        >
          <span class="block font-mono text-[10.5px] text-slate-400 dark:text-slate-500">
            {DemoBeat.stamp(beat)}
          </span>
          <span class="block text-sm text-slate-900 dark:text-slate-100 leading-snug">
            {beat.text}
          </span>
          <span
            :if={beat.criterion}
            data-qa="demo_beat_criterion"
            class="mt-1 block text-[11px] italic text-slate-500 dark:text-slate-400 leading-snug"
          >
            {beat.criterion}
          </span>
        </button>
      </div>
    </div>
    """
  end

  attr :task, :any, required: true
  attr :demo, :any, required: true
  attr :beats, :list, required: true

  # The video, and under it the caption bar. Under it, never over it: the whole
  # frame is the application, and the words about it live outside the picture.
  defp player(assigns) do
    ~H"""
    <div
      id="demo-player"
      data-qa="demo_player"
      class="flex-1 min-h-0 overflow-y-auto flex flex-col gap-3.5 p-4"
    >
      <div :if={@demo} class="shrink-0 space-y-1.5">
        <h2
          :if={@demo.title}
          data-qa="demo_title"
          class="text-base font-bold text-slate-900 dark:text-slate-100"
        >
          {@demo.title}
        </h2>
        <p data-qa="demo_summary" class="text-sm text-slate-600 dark:text-slate-300 leading-relaxed">
          {@demo.summary}
        </p>
      </div>

      <div
        id="demo-video-frame"
        phx-hook="DemoCaptions"
        phx-update="ignore"
        data-beats={Jason.encode!(Enum.map(@beats, &%{at_ms: &1.at_ms, text: &1.text}))}
        class="shrink-0 overflow-hidden rounded-xl border border-slate-200 dark:border-slate-700"
      >
        <video
          id="demo-video"
          data-qa="demo_video"
          controls
          preload="metadata"
          src={~p"/tasks/#{@task.id}/demo/video"}
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
        class="shrink-0 rounded-lg border border-amber-200 bg-amber-50 dark:border-amber-900 dark:bg-amber-950 p-3 text-xs text-amber-800 dark:text-amber-300"
      >
        Not shown: {@demo.not_shown}
      </p>
    </div>
    """
  end

  attr :driving, :map, required: true

  # A recording in flight, which no spinner can show. What is being filmed, where
  # it is, and what Rail last did to it.
  defp recording(assigns) do
    ~H"""
    <div
      id="demo-running"
      data-qa="demo_running"
      class="flex-1 min-h-0 overflow-y-auto flex flex-col gap-3.5 p-4"
    >
      <p class="shrink-0 flex items-center gap-2.5 text-sm font-bold text-slate-900 dark:text-slate-100">
        <span class="relative flex size-2">
          <span class="absolute inline-flex size-full rounded-full bg-red-400 opacity-75 motion-safe:animate-ping" />
          <span class="relative inline-flex size-2 rounded-full bg-red-500" />
        </span>
        Recording
      </p>

      <div class="shrink-0 flex flex-col overflow-hidden rounded-xl border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-900">
        <div class="shrink-0 flex items-center gap-2.5 px-3 py-2 border-b border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-800/60">
          <span :for={_dot <- 1..3} class="size-2.5 rounded-full bg-slate-300 dark:bg-slate-600" />
          <span
            data-qa="demo_browser_url"
            class="flex-1 min-w-0 truncate rounded-md border border-slate-200 dark:border-slate-700 bg-slate-100 dark:bg-slate-900/70 px-2.5 py-1 font-mono text-[11px] text-slate-500 dark:text-slate-400"
          >
            {@driving.url || "about:blank"}
          </span>
          <span class="font-mono text-[11px] text-slate-400 dark:text-slate-500">1920 × 1080</span>
        </div>

        <div class="relative w-full aspect-video bg-slate-900">
          <img
            id="demo-screencast"
            data-qa="demo_screencast"
            phx-hook="BrowserScreencast"
            phx-update="ignore"
            src={@driving.frame && "data:image/jpeg;base64,#{@driving.frame}"}
            alt="What is being recorded"
            class="peer absolute inset-0 size-full object-contain"
          />

          <div
            :if={@driving.frame == nil}
            data-qa="demo_screencast_waiting"
            class="absolute inset-0 flex flex-col items-center justify-center gap-3 bg-slate-900 peer-data-[live=true]:hidden"
          >
            <span class="size-5 rounded-full border-2 border-slate-700 border-t-blue-500 motion-safe:animate-spin" />
            <span class="font-mono text-[11.5px] text-slate-400">Waiting for the browser to paint.</span>
          </div>
        </div>

        <p
          data-qa="demo_doing"
          class="shrink-0 flex gap-2 px-3 py-2 border-t border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-800/60 font-mono text-[11.5px]"
        >
          <span class="shrink-0 text-blue-600 dark:text-blue-400">{@driving.verb}</span>
          <span class="min-w-0 truncate text-slate-600 dark:text-slate-300">{@driving.target}</span>
        </p>
      </div>
    </div>
    """
  end

  attr :run, :any, required: true

  # Before the first recording, and after one that could not be encoded. The run
  # carries why in both cases, and the header is already showing it.
  defp nothing_recorded(assigns) do
    ~H"""
    <div
      id="demo-pending"
      data-qa="demo_pending"
      class="flex-1 min-h-0 flex flex-col items-center justify-center gap-2 p-8 text-center"
    >
      <p class="text-sm font-semibold text-slate-900 dark:text-slate-100">Nothing recorded yet.</p>
      <p class="max-w-md text-xs text-slate-500 dark:text-slate-400 leading-relaxed">
        {waiting_on(@run)}
      </p>
    </div>
    """
  end

  # --- Private Helpers ---

  defp load(socket) do
    task = socket.assigns.task

    socket
    |> assign(:running, Run.running?(socket.assigns.run))
    |> assign(:demo, Pipeline.read_demo(task))
    |> assign(:beats, Pipeline.list_demo_beats(task))
    |> assign(:recorded, recorded?(task))
    |> assign(:driving, browser_driving(socket.assigns.run, task))
  end

  # There is a demo when there is a video to watch. The write-up is read for what
  # it says about it, but a run that wrote one and could not encode has nothing
  # to show.
  defp recorded?(%Task{scratch_path: scratch_path}) do
    File.regular?(Path.join([scratch_path, "demo", "demo.webm"]))
  end

  defp waiting_on(%Run{error: error}) when is_binary(error), do: "The last recording did not produce a video."
  defp waiting_on(%Run{}), do: "The demo agent records a walkthrough of the change; it will appear here."
end
