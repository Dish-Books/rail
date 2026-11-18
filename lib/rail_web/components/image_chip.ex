defmodule RailWeb.Components.ImageChip do
  @moduledoc """
  A picture held in a text box before it goes anywhere, shown small with a button that takes it out again. It is
  either an upload `entry` still in the browser, or a picture already stored at `src`.
  """
  use RailWeb, :html

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :entry, :any, default: nil, doc: "an upload entry, previewed from the browser's own copy"
  attr :src, :string, default: nil, doc: "a stored picture's address, opened full size in a new tab"
  attr :busy, :boolean, default: false
  attr :removable, :boolean, default: true
  attr :rest, :global, doc: "the remove button's event and values"

  def image_chip(assigns) do
    ~H"""
    <div
      id={@id}
      data-qa="image-chip"
      title={@name}
      class="group/chip relative size-14 shrink-0 rounded-lg overflow-hidden border border-slate-300 dark:border-slate-600 bg-slate-100 dark:bg-slate-800"
    >
      <.live_img_preview :if={@entry} entry={@entry} alt={@name} class="size-full object-cover" />
      <a :if={@src} href={@src} target="_blank" rel="noopener" class="block size-full">
        <img src={@src} alt={@name} class="size-full object-cover" />
      </a>
      <div
        :if={@busy}
        class="absolute inset-0 flex items-center justify-center bg-white/60 dark:bg-slate-900/60 text-slate-600 dark:text-slate-300"
      >
        <.icon name="pi-circle-notch" class="size-4 motion-safe:animate-spin" />
      </div>
      <button
        :if={@removable}
        type="button"
        data-qa="image-chip-remove"
        aria-label={"Remove #{@name}"}
        class="absolute top-1 right-1 flex size-5 items-center justify-center rounded-full bg-slate-900/75 text-white opacity-0 group-hover/chip:opacity-100 focus-visible:opacity-100 pointer-coarse:opacity-100 cursor-pointer focus-visible:outline-2 focus-visible:outline-blue-500"
        {@rest}
      >
        <.icon name="pi-x-bold" class="size-3" />
      </button>
    </div>
    """
  end
end
