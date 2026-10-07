defmodule RailWeb.Components.TriageImage do
  @moduledoc """
  One image a Slack message came with, as a tile under its text that opens the
  enlarged view. The browser says whether it loaded, through the ImageFallback hook.
  """
  use RailWeb, :html

  alias Rail.Triage.Schemas.Message.Image

  attr :message_id, :string, required: true
  attr :image, Image, required: true

  def triage_image(%{image: %Image{url: url}} = assigns) when is_binary(url) do
    ~H"""
    <div
      id={"triage-image-#{@message_id}-#{@image.external_id}"}
      data-qa="triage-image"
      phx-hook="ImageFallback"
      data-image="loading"
      class="group/image"
    >
      <button
        type="button"
        id={"triage-image-open-#{@message_id}-#{@image.external_id}"}
        aria-label={"Enlarge #{@image.name}"}
        title={@image.name}
        phx-click="open_image"
        phx-value-message_id={@message_id}
        phx-value-file_id={@image.external_id}
        class="group/tile relative block w-[118px] cursor-zoom-in overflow-hidden rounded-lg border text-left bg-white dark:bg-slate-900 border-slate-200 dark:border-slate-700 hover:border-blue-400 dark:hover:border-blue-500 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500 group-data-[image=failed]/image:hidden"
      >
        <span class="relative block h-[62px]">
          <span
            data-qa="triage-image-loading"
            class="absolute inset-0 flex items-center justify-center bg-slate-200 dark:bg-slate-800 motion-safe:animate-pulse group-data-[image=loaded]/image:hidden"
          >
            <.icon name="pi-image" class="size-5 text-slate-400 dark:text-slate-500" />
          </span>
          <%!-- Transparent rather than hidden while loading, since a lazy image that is not drawn never loads. --%>
          <img
            src={~p"/triage/messages/#{@message_id}/images/#{@image.external_id}"}
            alt=""
            loading="lazy"
            class="absolute inset-0 h-full w-full object-cover object-top opacity-0 group-data-[image=loaded]/image:opacity-100"
          />
        </span>
        <span class="absolute top-1 right-1 hidden group-hover/tile:flex group-focus-visible/tile:flex size-5 items-center justify-center rounded bg-slate-900/80 text-white">
          <.icon name="pi-arrows-out-simple-bold" class="size-3" />
        </span>
        <span class="block truncate px-2 py-1 font-mono text-[10.5px] text-slate-500 dark:text-slate-400">
          {@image.name}
        </span>
      </button>
      <div
        data-qa="triage-image-failed"
        title={"Rail could not load #{@image.name}."}
        class="hidden group-data-[image=failed]/image:flex w-[118px] h-[86px] flex-col overflow-hidden rounded-lg border border-dashed border-slate-300 dark:border-slate-600"
      >
        <span class="flex flex-1 flex-col items-center justify-center gap-0.5 px-2 text-center">
          <.icon name="pi-image-broken" class="size-4.5 text-slate-500 dark:text-slate-400" />
          <span class="text-[11px] leading-snug text-slate-600 dark:text-slate-300">Rail could not load it.</span>
        </span>
        <span class="block truncate px-2 py-1 font-mono text-[10.5px] text-slate-500 dark:text-slate-400">
          {@image.name}
        </span>
      </div>
    </div>
    """
  end

  # Slack withheld the file, so Rail has no name or address for it.
  def triage_image(assigns) do
    ~H"""
    <div
      id={"triage-image-#{@message_id}-#{@image.external_id}"}
      data-qa="triage-image-withheld"
      class="flex w-[118px] h-[86px] flex-col items-center justify-center gap-1 rounded-lg border border-dashed border-slate-300 dark:border-slate-600 px-2 text-center"
    >
      <.icon name="pi-eye-slash" class="size-4.5 text-slate-500 dark:text-slate-400" />
      <span class="text-[11px] leading-snug text-slate-600 dark:text-slate-300">
        A file was attached that Rail cannot see.
      </span>
    </div>
    """
  end
end
