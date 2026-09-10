defmodule RailWeb.Components.Button do
  @moduledoc false
  use RailWeb, :html

  @base "inline-flex items-center justify-center gap-1.5 rounded-md font-semibold whitespace-nowrap select-none transition-colors duration-150 focus-visible:outline-2 focus-visible:outline-offset-2 disabled:opacity-50 disabled:pointer-events-none"

  @sizes %{
    "xs" => "px-2 py-1 text-[11px]",
    "sm" => "px-2.5 py-1.5 text-xs",
    "icon" => "h-7 w-7 p-0 text-xs",
    "md" => "px-3 py-2 text-sm"
  }

  @variants %{
    "secondary" =>
      "bg-white dark:bg-slate-800 text-slate-700 dark:text-slate-200 shadow-xs ring-1 ring-inset ring-slate-300 dark:ring-slate-600 hover:bg-slate-50 dark:hover:bg-slate-700 hover:text-slate-900 dark:hover:text-white active:bg-slate-100 dark:active:bg-slate-600 focus-visible:outline-slate-400",
    "primary" =>
      "bg-indigo-600 text-white shadow-xs hover:bg-indigo-500 active:bg-indigo-700 focus-visible:outline-indigo-600",
    "accent" =>
      "bg-indigo-50 dark:bg-indigo-400/10 text-indigo-700 dark:text-indigo-300 shadow-xs ring-1 ring-inset ring-indigo-200 dark:ring-indigo-400/30 hover:bg-indigo-100 dark:hover:bg-indigo-400/20 hover:ring-indigo-300 dark:hover:ring-indigo-400/50 active:bg-indigo-200/70 dark:active:bg-indigo-400/30 focus-visible:outline-indigo-600",
    "danger" =>
      "bg-white dark:bg-slate-800 text-red-600 dark:text-red-400 shadow-xs ring-1 ring-inset ring-red-200 dark:ring-red-400/30 hover:bg-red-50 dark:hover:bg-red-400/10 hover:text-red-700 dark:hover:text-red-300 hover:ring-red-300 dark:hover:ring-red-400/50 active:bg-red-100 dark:active:bg-red-400/20 focus-visible:outline-red-600",
    "danger_solid" => "bg-red-600 text-white shadow-xs hover:bg-red-500 active:bg-red-700 focus-visible:outline-red-600",
    "success" =>
      "bg-emerald-600 text-white shadow-xs hover:bg-emerald-500 active:bg-emerald-700 focus-visible:outline-emerald-600",
    "ghost" =>
      "text-slate-600 dark:text-slate-300 hover:bg-slate-100 dark:hover:bg-slate-700 hover:text-slate-900 dark:hover:text-white active:bg-slate-200 dark:active:bg-slate-600 focus-visible:outline-slate-400",
    "ghost_danger" =>
      "text-slate-500 dark:text-slate-400 hover:bg-red-500/10 hover:text-red-600 dark:hover:text-red-400 active:bg-red-500/20 focus-visible:outline-red-600"
  }

  attr :variant, :string, default: "secondary", values: Map.keys(@variants)
  attr :size, :string, default: "md", values: Map.keys(@sizes)
  attr :type, :string, default: "button"
  attr :class, :any, default: nil
  attr :href, :any, default: nil
  attr :navigate, :any, default: nil
  attr :patch, :any, default: nil
  attr :rest, :global, include: ~w(disabled form name value download target rel)

  slot :inner_block, required: true

  def button(assigns) do
    assigns =
      assign(assigns, :styles, [@base, @sizes[assigns.size], @variants[assigns.variant], assigns.class])

    case nav_attrs(assigns) do
      nil -> plain_button(assigns)
      attrs -> assigns |> assign(:nav, attrs) |> nav_button()
    end
  end

  defp nav_attrs(%{navigate: to}) when not is_nil(to), do: %{navigate: to}
  defp nav_attrs(%{patch: to}) when not is_nil(to), do: %{patch: to}
  defp nav_attrs(%{href: to}) when not is_nil(to), do: %{href: to}
  defp nav_attrs(_assigns), do: nil

  defp plain_button(assigns) do
    ~H"""
    <button type={@type} class={@styles} {@rest}>
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp nav_button(assigns) do
    ~H"""
    <.link class={@styles} {@nav} {@rest}>
      {render_slot(@inner_block)}
    </.link>
    """
  end
end
