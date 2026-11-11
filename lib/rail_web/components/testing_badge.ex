defmodule RailWeb.Components.TestingBadge do
  @moduledoc """
  A ticket's testing state as a small badge, the same on the testing queue, the open ticket's bar and its Properties.
  """
  use RailWeb, :html

  alias Rail.Issues.Schemas.Issue

  attr :state, :atom, required: true, values: Issue.testing_states()
  attr :id, :string, default: nil

  def testing_badge(assigns) do
    assigns = assign(assigns, :style, style(assigns.state))

    ~H"""
    <span
      id={@id}
      data-testing-state={@state}
      class={[
        "inline-flex items-center gap-1 whitespace-nowrap px-1.5 py-0.5 rounded text-[11px] font-semibold",
        @style.class
      ]}
    >
      <.icon name={@style.icon} class="size-3" />{Issue.testing_label(@state)}
    </span>
    """
  end

  defp style(:waiting),
    do: %{
      icon: "pi-hourglass-medium",
      class: "ring-1 ring-inset ring-slate-300 dark:ring-slate-600 text-slate-600 dark:text-slate-300"
    }

  defp style(:testing),
    do: %{icon: "pi-test-tube-fill", class: "bg-blue-100 dark:bg-blue-500/15 text-blue-700 dark:text-blue-300"}

  defp style(:tested),
    do: %{
      icon: "pi-check-circle-fill",
      class: "bg-emerald-100 dark:bg-emerald-500/15 text-emerald-700 dark:text-emerald-300"
    }

  defp style(:sent_to_triage),
    do: %{
      icon: "pi-tray",
      class: "ring-1 ring-inset ring-slate-300 dark:ring-slate-600 text-slate-600 dark:text-slate-300"
    }
end
