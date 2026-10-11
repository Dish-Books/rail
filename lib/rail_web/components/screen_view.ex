defmodule RailWeb.Components.ScreenView do
  @moduledoc """
  One screen state's shot over the page, at one fixed size for every state as Triage's image view is, with Previous
  and Next through the states in the grid's order, the findings citing the shot, and a Comment box beside it with
  the reader's unsent comments on the state. While the box is open, Escape and the arrow keys are the box's.
  """
  use RailWeb, :html

  alias Phoenix.LiveView.JS

  attr :task_id, :string, required: true
  attr :screen, :map, required: true, doc: "the state as `Rail.Pipeline.list_screens/1` reads it"
  attr :position, :integer, required: true
  attr :count, :integer, required: true
  attr :labels, :map, default: %{}, doc: "each commit on the branch to what made it"
  attr :comments, :list, default: [], doc: "the reader's unsent comments on the state, oldest first"
  attr :draft, :string, default: nil, doc: "what the open comment box holds, or nil while it is closed"
  attr :target, :any, required: true

  def screen_view(assigns) do
    %{screen: screen, task_id: task_id} = assigns
    src = ~p"/tasks/#{task_id}/screens/#{screen.key}?#{[at: DateTime.to_unix(screen.taken_at, :microsecond)]}"

    assigns =
      assigns
      |> assign(:src, src)
      # Closing goes back to the state's card in the grid, the one on screen after any steps.
      |> assign(:close, JS.push(JS.focus(to: "#screen-#{screen.key}"), "close_screen", target: assigns.target))
      |> assign(:show_steps, assigns.count > 1)
      |> assign(:at_first, assigns.position == 1)
      |> assign(:at_last, assigns.position == assigns.count)
      |> assign(:boxed, is_binary(assigns.draft))
      |> assign(:show_side, assigns.comments != [] or is_binary(assigns.draft))

    ~H"""
    <div
      id="screen-view"
      data-qa="screen_view"
      phx-window-keydown={if not @boxed, do: @close}
      phx-key={if not @boxed, do: "Escape"}
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/50"
    >
      <.focus_wrap
        id="screen-view-panel"
        role="dialog"
        aria-modal="true"
        aria-label={@screen.label}
        phx-click-away={@close}
        phx-window-keydown={if not @boxed, do: "screen_key"}
        phx-target={@target}
        class="group/panel flex w-[min(1280px,calc(100vw-48px))] h-[min(860px,calc(100dvh-48px))] flex-col overflow-hidden rounded-2xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900 shadow-2xl"
      >
        <div class="flex h-[49px] shrink-0 items-center gap-2.5 px-2 border-b border-slate-200 dark:border-slate-700">
          <div :if={@show_steps} class="flex shrink-0 items-center gap-0.5">
            <%!-- aria-disabled rather than disabled, so a press that reaches the end keeps focus in the view. --%>
            <button
              type="button"
              id="screen-view-previous"
              aria-label="Previous screen"
              aria-disabled={to_string(@at_first)}
              phx-click="step_screen"
              phx-value-direction="previous"
              phx-target={@target}
              class={[
                "h-8 w-8 shrink-0 rounded-md flex items-center justify-center text-slate-500 dark:text-slate-400 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500",
                @at_first && "opacity-40 cursor-not-allowed",
                !@at_first &&
                  "hover:bg-slate-200 dark:hover:bg-slate-700 hover:text-slate-900 dark:hover:text-slate-100 cursor-pointer"
              ]}
            >
              <.icon name="pi-caret-left-bold" class="size-3.5" />
            </button>
            <span
              id="screen-view-position"
              aria-live="polite"
              class="min-w-[44px] text-center text-[12px] font-semibold tabular-nums text-slate-600 dark:text-slate-300"
            >
              {@position} of {@count}
            </span>
            <button
              type="button"
              id="screen-view-next"
              aria-label="Next screen"
              aria-disabled={to_string(@at_last)}
              phx-click="step_screen"
              phx-value-direction="next"
              phx-target={@target}
              class={[
                "h-8 w-8 shrink-0 rounded-md flex items-center justify-center text-slate-500 dark:text-slate-400 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500",
                @at_last && "opacity-40 cursor-not-allowed",
                !@at_last &&
                  "hover:bg-slate-200 dark:hover:bg-slate-700 hover:text-slate-900 dark:hover:text-slate-100 cursor-pointer"
              ]}
            >
              <.icon name="pi-caret-right-bold" class="size-3.5" />
            </button>
          </div>
          <span :if={@show_steps} class="h-5 w-px shrink-0 bg-slate-200 dark:bg-slate-700"></span>
          <span
            id="screen-view-name"
            class="min-w-0 truncate pl-1.5 text-[12.5px] font-semibold text-slate-800 dark:text-slate-100"
          >
            {@screen.label}
          </span>
          <span
            :if={@screen.commit}
            class="shrink-0 font-mono text-[11.5px] text-slate-500 dark:text-slate-400"
          >
            {String.slice(@screen.commit, 0, 7)}
          </span>
          <span
            :if={@labels[@screen.commit]}
            class="min-w-0 truncate text-[11.5px] text-slate-500 dark:text-slate-400"
          >
            {@labels[@screen.commit]}
          </span>
          <span class="ml-auto"></span>
          <button
            type="button"
            id="screen-view-comment"
            data-qa="screen_view_comment"
            aria-pressed={to_string(@boxed)}
            phx-click="toggle_screen_comment"
            phx-target={@target}
            class={[
              "shrink-0 inline-flex items-center gap-1.5 h-8 px-2.5 rounded-md ring-1 ring-inset text-[11.5px] font-semibold cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500",
              @boxed &&
                "bg-blue-50 dark:bg-blue-950/40 ring-blue-300 dark:ring-blue-800 text-blue-800 dark:text-blue-200",
              not @boxed &&
                "ring-slate-300 dark:ring-slate-600 text-slate-700 dark:text-slate-200 hover:bg-slate-50 dark:hover:bg-slate-800"
            ]}
          >
            <.icon name="pi-chat-text" class="size-3.5" />Comment
          </button>
          <%!-- Only the browser knows the picture failed, so it hides the link that would open the same failure. --%>
          <a
            id="screen-view-original"
            href={@src}
            target="_blank"
            rel="noopener"
            class="shrink-0 inline-flex items-center gap-1 rounded text-[11.5px] font-semibold text-blue-600 dark:text-blue-400 hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500 group-has-[[data-image=failed]]/panel:hidden"
          >
            Open original <.icon name="pi-arrow-up-right" class="size-3" />
          </a>
          <button
            type="button"
            id="screen-view-close"
            aria-label="Close"
            phx-click={@close}
            phx-mounted={JS.focus()}
            class="h-8 w-8 shrink-0 rounded-md flex items-center justify-center text-slate-400 hover:bg-slate-200 dark:hover:bg-slate-700 cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
          >
            <.icon name="pi-x" class="size-4" />
          </button>
        </div>

        <div
          :if={@screen.findings != []}
          id="screen-view-findings"
          class="flex h-9 shrink-0 items-center gap-4 px-4 min-w-0 overflow-hidden border-b border-slate-200 dark:border-slate-700"
        >
          <button
            :for={finding <- @screen.findings}
            type="button"
            title="Open in Findings"
            data-qa="screen_finding"
            phx-click="open_finding"
            phx-value-key={finding.key}
            phx-target={@target}
            class="min-w-0 inline-flex items-center gap-1 text-[11.5px] font-semibold text-blue-600 dark:text-blue-400 hover:underline cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
          >
            <.icon name="pi-warning-circle" class="size-[13px] shrink-0" /><span class="truncate">{finding.title}</span>
          </button>
        </div>

        <div class="flex min-h-0 flex-1">
          <%!-- Keyed by the file, so a step or a retake mounts a fresh element in the loading state. --%>
          <div
            id={"screen-view-picture-#{@screen.key}-#{Path.basename(@screen.file, ".jpg")}"}
            phx-hook="ImageFallback"
            data-image="loading"
            class="group/picture flex min-w-0 min-h-0 flex-1 items-center justify-center p-4 [container-type:size] bg-slate-100 dark:bg-slate-950"
          >
            <img
              src={@src}
              alt={@screen.label}
              class="hidden group-data-[image=loaded]/picture:block max-w-none h-auto w-[min(calc(var(--natural-width)*1px),100cqw,calc(100cqh*var(--natural-width)/var(--natural-height)))] rounded ring-1 ring-slate-900/10 dark:ring-white/10 shadow-lg shadow-black/40"
            />
            <div
              data-qa="screen-view-loading"
              class="flex h-[260px] w-[560px] max-h-full max-w-full items-center justify-center rounded-lg bg-slate-200 dark:bg-slate-800 motion-safe:animate-pulse group-data-[image=loaded]/picture:hidden group-data-[image=failed]/picture:hidden"
            >
              <.icon name="pi-image" class="size-7.5 text-slate-400 dark:text-slate-500" />
            </div>
            <div
              data-qa="screen-view-failed"
              class="hidden group-data-[image=failed]/picture:flex h-[260px] w-[560px] max-h-full max-w-full flex-col items-center justify-center gap-2 rounded-lg px-6 text-center border border-dashed border-slate-300 dark:border-slate-600"
            >
              <.icon name="pi-image-broken" class="size-7.5 text-slate-500 dark:text-slate-400" />
              <p class="text-[13px] text-slate-700 dark:text-slate-200">
                Rail could not load this shot.
              </p>
            </div>
          </div>

          <div
            :if={@show_side}
            id="screen-view-comments"
            class="w-[340px] max-w-[45%] shrink-0 flex flex-col gap-2 p-3 overflow-y-auto border-l border-slate-200 dark:border-slate-700"
          >
            <.screen_comment :for={comment <- @comments} comment={comment} target={@target} />
            <.comment_box
              :if={@boxed}
              id="screen-comment-form"
              body_id="screen-comment-body"
              qa="screen_comment"
              label={@screen.label}
              body={@draft}
              submit="save_screen_comment"
              change="screen_comment_change"
              cancel="cancel_screen_comment"
              target={@target}
              class=""
              narrow
            />
          </div>
        </div>
      </.focus_wrap>
    </div>
    """
  end
end
