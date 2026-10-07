defmodule RailWeb.Components.TriageImageView do
  @moduledoc """
  A triage image enlarged over the page, at one fixed size for every image, with
  Previous and Next through the other images of the same message.
  """
  use RailWeb, :html

  alias Phoenix.LiveView.JS
  alias Rail.Triage.Schemas.Message.Image

  attr :message_id, :string, required: true
  attr :image, Image, required: true
  attr :position, :integer, required: true
  attr :count, :integer, required: true

  def triage_image_view(assigns) do
    assigns =
      assigns
      |> assign(:src, ~p"/triage/messages/#{assigns.message_id}/images/#{assigns.image.external_id}")
      # The server re-renders this after every step, so closing focuses the tile of the image on screen.
      |> assign(
        :close,
        JS.push(JS.focus(to: "#triage-image-open-#{assigns.message_id}-#{assigns.image.external_id}"), "close_image")
      )
      |> assign(:show_steps, assigns.count > 1)
      |> assign(:at_first, assigns.position == 1)
      |> assign(:at_last, assigns.position == assigns.count)

    ~H"""
    <div
      id="triage-image-view"
      phx-window-keydown={@close}
      phx-key="Escape"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/50"
    >
      <.focus_wrap
        id="triage-image-panel"
        role="dialog"
        aria-modal="true"
        aria-label={@image.name}
        phx-click-away={@close}
        phx-window-keydown="image_key"
        class="group/panel flex w-[min(1280px,calc(100vw-48px))] h-[min(860px,calc(100dvh-48px))] flex-col overflow-hidden rounded-2xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900 shadow-2xl"
      >
        <div class="flex h-[49px] shrink-0 items-center gap-2.5 px-2 border-b border-slate-200 dark:border-slate-700">
          <div :if={@show_steps} class="flex shrink-0 items-center gap-0.5">
            <%!-- aria-disabled rather than disabled, so a press that reaches the end keeps focus in the view. --%>
            <button
              type="button"
              id="triage-image-previous"
              aria-label="Previous image"
              aria-disabled={to_string(@at_first)}
              phx-click="step_image"
              phx-value-direction="previous"
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
              id="triage-image-position"
              aria-live="polite"
              class="min-w-[44px] text-center text-[12px] font-semibold tabular-nums text-slate-600 dark:text-slate-300"
            >
              {@position} of {@count}
            </span>
            <button
              type="button"
              id="triage-image-next"
              aria-label="Next image"
              aria-disabled={to_string(@at_last)}
              phx-click="step_image"
              phx-value-direction="next"
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
          <span
            :if={@show_steps}
            id="triage-image-divider"
            class="h-5 w-px shrink-0 bg-slate-200 dark:bg-slate-700"
          ></span>
          <span
            id="triage-image-name"
            class="min-w-0 truncate pl-1.5 font-mono text-[12.5px] font-semibold text-slate-800 dark:text-slate-100"
          >
            {@image.name}
          </span>
          <span class="ml-auto"></span>
          <%!-- Only the browser knows the image failed, so it hides the link that would open the same failure. --%>
          <a
            id="triage-image-original"
            href={@src}
            target="_blank"
            rel="noopener"
            class="shrink-0 inline-flex items-center gap-1 rounded text-[11.5px] font-semibold text-blue-600 dark:text-blue-400 hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500 group-has-[[data-image=failed]]/panel:hidden"
          >
            Open original <.icon name="pi-arrow-up-right" class="size-3" />
          </a>
          <button
            type="button"
            id="triage-image-close"
            aria-label="Close"
            phx-click={@close}
            phx-mounted={JS.focus()}
            class="h-8 w-8 shrink-0 rounded-md flex items-center justify-center text-slate-400 hover:bg-slate-200 dark:hover:bg-slate-700 cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
          >
            <.icon name="pi-x" class="size-4" />
          </button>
        </div>
        <%!-- Keyed by the file, so a step mounts a fresh element in the loading state with no size. --%>
        <div
          id={"triage-image-picture-#{@image.external_id}"}
          phx-hook="ImageFallback"
          data-image="loading"
          class="group/picture flex min-h-0 flex-1 items-center justify-center p-4 [container-type:size] bg-slate-100 dark:bg-slate-950"
        >
          <img
            src={@src}
            alt={@image.name}
            class="hidden group-data-[image=loaded]/picture:block max-w-none h-auto w-[min(calc(var(--natural-width)*2px),100cqw,calc(100cqh*var(--natural-width)/var(--natural-height)))] rounded ring-1 ring-slate-900/10 dark:ring-white/10 shadow-lg shadow-black/40"
          />
          <div
            data-qa="triage-image-view-loading"
            class="flex h-[260px] w-[560px] max-h-full max-w-full items-center justify-center rounded-lg bg-slate-200 dark:bg-slate-800 motion-safe:animate-pulse group-data-[image=loaded]/picture:hidden group-data-[image=failed]/picture:hidden"
          >
            <.icon name="pi-image" class="size-7.5 text-slate-400 dark:text-slate-500" />
          </div>
          <div
            data-qa="triage-image-view-failed"
            class="hidden group-data-[image=failed]/picture:flex h-[260px] w-[560px] max-h-full max-w-full flex-col items-center justify-center gap-2 rounded-lg px-6 text-center border border-dashed border-slate-300 dark:border-slate-600"
          >
            <.icon name="pi-image-broken" class="size-7.5 text-slate-500 dark:text-slate-400" />
            <p class="text-[13px] text-slate-700 dark:text-slate-200">
              Rail could not load <span class="break-all font-mono text-[12px]">{@image.name}</span>.
            </p>
          </div>
        </div>
      </.focus_wrap>
    </div>
    """
  end
end
