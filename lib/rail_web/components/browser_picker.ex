defmodule RailWeb.Components.BrowserPicker do
  @moduledoc """
  Review's Browser item: a header row with how many browsers there are and whether any is driving or
  recording, the choice of QA explorer N or Demo recorder with the account each is signed in as, and the
  picked one's tab, its address and size, and a line saying it is idle or how many beats the recording
  has said. The frames are pushed to the image by the page, never drawn through a render.
  """
  use RailWeb, :html

  attr :sessions, :list, required: true, doc: "`%{name:, account:, state:}`, `state` `:driving`, `:recording` or `:idle`"
  attr :picked, :string, default: nil
  attr :url, :string, default: nil
  attr :beats, :integer, default: 0, doc: "how many captions the recording has said"
  attr :target, :any, required: true

  def browser_picker(assigns) do
    assigns = assign(assigns, :current, Enum.find(assigns.sessions, &(&1.name == assigns.picked)))

    ~H"""
    <div
      id="review-browser"
      data-qa="review_browser"
      class="flex-1 min-w-0 min-h-0 flex flex-col overflow-y-auto"
    >
      <div class="h-12 shrink-0 flex items-center gap-2 px-5 border-b border-slate-200 dark:border-slate-700">
        <span class="text-sm font-bold text-slate-900 dark:text-slate-100">Browser</span>
        <span class="text-xs text-slate-500 dark:text-slate-400">{length(@sessions)}</span>
        <span
          :if={@sessions != []}
          data-qa="review_browser_summary"
          class="min-w-0 truncate text-xs text-slate-500 dark:text-slate-400"
        >
          · {summary(@sessions)}
        </span>
      </div>

      <p
        :if={@sessions == []}
        data-qa="review_browser_none"
        class="p-5 text-sm text-slate-500 dark:text-slate-400"
      >
        No browser is open. The QA explorers and the demo recorder each open one of their own as a round runs.
      </p>

      <div :if={@current} class="p-5 flex flex-col gap-3">
        <div
          role="group"
          aria-label="Browser to watch"
          class="inline-flex w-fit max-w-full overflow-x-auto rounded-lg bg-slate-100 dark:bg-slate-800 p-0.5"
        >
          <button
            :for={session <- @sessions}
            type="button"
            id={"review-browser-#{session.name}"}
            data-qa="review_browser_choice"
            aria-pressed={to_string(session.name == @picked)}
            phx-click="pick_browser"
            phx-value-name={session.name}
            phx-target={@target}
            class={[
              "min-w-0 flex items-center gap-2 px-3 py-1.5 rounded-md text-left cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500",
              session.name == @picked && "bg-white dark:bg-slate-700 shadow-xs",
              session.name != @picked && "hover:bg-white/60 dark:hover:bg-slate-700/50"
            ]}
          >
            <span
              :if={session.state == :idle}
              class="size-2 shrink-0 rounded-full bg-slate-400 dark:bg-slate-600"
            />
            <span :if={session.state != :idle} class="relative flex size-2 shrink-0">
              <span class={[
                "absolute inline-flex size-full rounded-full opacity-75 motion-safe:animate-ping",
                session.state == :recording && "bg-red-400",
                session.state == :driving && "bg-blue-400"
              ]} />
              <span class={[
                "relative inline-flex size-2 rounded-full",
                session.state == :recording && "bg-red-500",
                session.state == :driving && "bg-blue-500"
              ]} />
            </span>
            <span class="min-w-0">
              <span class={[
                "block truncate text-xs font-semibold",
                session.name == @picked && "text-slate-900 dark:text-slate-100",
                session.name != @picked && "text-slate-600 dark:text-slate-300"
              ]}>
                {browser_label(session.name)}
              </span>
              <span
                :if={session.account}
                class="block truncate font-mono text-[10.5px] text-slate-500 dark:text-slate-400"
              >
                {session.account}
              </span>
            </span>
          </button>
        </div>

        <div class="flex flex-col overflow-hidden rounded-xl border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-900">
          <div class="flex items-center gap-2.5 px-3 py-2 border-b border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-800/60">
            <span :for={_dot <- 1..3} class="size-2.5 rounded-full bg-slate-300 dark:bg-slate-600" />
            <span
              data-qa="review_browser_url"
              class="flex-1 min-w-0 truncate rounded-md border border-slate-200 dark:border-slate-700 bg-slate-100 dark:bg-slate-900/70 px-2.5 py-1 font-mono text-[11px] text-slate-500 dark:text-slate-400"
            >
              {@url || "about:blank"}
            </span>
            <span class="font-mono text-[11px] text-slate-400 dark:text-slate-500">1920 × 1080</span>
          </div>
          <div class="relative w-full aspect-video bg-slate-900">
            <img
              id={"review-screencast-#{@current.name}"}
              data-qa="review_screencast"
              phx-hook="BrowserScreencast"
              phx-update="ignore"
              alt={"What #{browser_label(@current.name)} is looking at"}
              class="peer absolute inset-0 size-full object-contain"
            />
            <div class="absolute inset-0 flex flex-col items-center justify-center gap-3 bg-slate-900 peer-data-[live=true]:hidden">
              <span class="font-mono text-[11.5px] text-slate-400">
                {if @current.state == :idle,
                  do: "Idle. Nothing is driving this browser.",
                  else: "Waiting for the browser to paint."}
              </span>
            </div>
          </div>
          <p
            data-qa="review_browser_line"
            class="flex gap-2 px-3 py-2 border-t border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-800/60 font-mono text-[11.5px]"
          >
            <span class={["shrink-0", state_class(@current.state)]}>{@current.state}</span>
            <span class="min-w-0 truncate text-slate-600 dark:text-slate-300">{line(@current, @beats)}</span>
          </p>
        </div>
      </div>
    </div>
    """
  end

  defp summary(sessions) do
    counts = Enum.frequencies_by(sessions, & &1.state)

    [{:recording, "recording"}, {:driving, "driving"}, {:idle, "idle"}]
    |> Enum.filter(fn {state, _word} -> Map.get(counts, state, 0) > 0 end)
    |> Enum.map_join(", ", fn {state, word} -> "#{counts[state]} #{word}" end)
  end

  defp line(%{state: :recording} = session, beats), do: "Recording · #{beats(beats)} said so far#{signed_in(session)}"

  defp line(%{state: :driving} = session, _beats), do: "Driving#{signed_in(session)}"
  defp line(session, _beats), do: "Idle#{signed_in(session)}"

  defp beats(1), do: "1 beat"
  defp beats(count), do: "#{count} beats"

  defp signed_in(%{account: nil}), do: ""
  defp signed_in(%{account: account}), do: " · signed in as #{account}"

  defp state_class(:recording), do: "text-red-600 dark:text-red-400"
  defp state_class(:driving), do: "text-blue-600 dark:text-blue-400"
  defp state_class(:idle), do: "text-slate-500 dark:text-slate-400"
end
