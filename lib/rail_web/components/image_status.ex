defmodule RailWeb.Components.ImageStatus do
  @moduledoc """
  Where a host's copy of Rail's sandbox image stands: Current, Copying with how
  much is sent, or Copy failed with why. A dash for a host never reached.
  """
  use RailWeb, :html

  attr :id, :string, required: true
  attr :image, :any, required: true

  def image_status(%{image: nil} = assigns) do
    ~H"""
    <span id={@id} class="text-xs text-slate-500 dark:text-slate-400">—</span>
    """
  end

  def image_status(%{image: :current} = assigns) do
    ~H"""
    <span
      id={@id}
      class="inline-flex items-center gap-1.5 text-xs text-slate-700 dark:text-slate-300 whitespace-nowrap"
    >
      <.icon name="pi-check" class="size-3.5 text-slate-400" />Current
    </span>
    """
  end

  def image_status(%{image: {:copying, sent, total}} = assigns) do
    assigns = assign(assigns, :progress, is_integer(total) && "#{gigabytes(sent)} of #{gigabytes(total)} GB")

    ~H"""
    <span
      id={@id}
      class="inline-flex items-center gap-1.5 text-xs font-semibold text-blue-600 dark:text-blue-400 whitespace-nowrap"
    >
      <.icon name="pi-arrows-clockwise" class="size-3.5" />Copying
    </span>
    <p
      :if={@progress}
      id={"#{@id}-progress"}
      class="mt-0.5 font-mono text-xs text-slate-500 dark:text-slate-400 whitespace-nowrap"
    >
      {@progress}
    </p>
    """
  end

  def image_status(%{image: {:failed, reason}} = assigns) do
    assigns = assign(assigns, :reason, reason)

    ~H"""
    <span
      id={@id}
      class="inline-flex items-center gap-1.5 text-xs font-semibold text-red-600 dark:text-red-400 whitespace-nowrap"
    >
      <.icon name="pi-x-circle" class="size-3.5" />Copy failed
    </span>
    <p
      id={"#{@id}-reason"}
      class="mt-0.5 text-xs text-slate-500 dark:text-slate-400 truncate"
      title={@reason}
    >
      {@reason}
    </p>
    """
  end

  defp gigabytes(bytes), do: :erlang.float_to_binary(bytes / 1024 ** 3, decimals: 1)
end
