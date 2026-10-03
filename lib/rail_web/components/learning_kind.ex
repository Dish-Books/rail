defmodule RailWeb.Components.LearningKind do
  @moduledoc """
  A rule's kind as its icon and label, the same on cards, headers and the review tab.
  """
  use RailWeb, :html

  alias Rail.Learnings.Schemas.Learning

  attr :kind, :atom, required: true
  attr :class, :any, default: nil

  def learning_kind(assigns) do
    assigns = assign(assigns, :icon, kind_icon(assigns.kind))

    ~H"""
    <span
      data-qa="learning-kind"
      class={[
        "inline-flex items-center gap-1 shrink-0 text-[11px] font-semibold text-slate-600 dark:text-slate-300",
        @class
      ]}
    >
      <.icon name={@icon} class="size-[13px] text-slate-400" />{Learning.kind_label(@kind)}
    </span>
    """
  end

  defp kind_icon(:convention), do: "pi-ruler"
  defp kind_icon(:decision), do: "pi-gavel"
  defp kind_icon(:environment), do: "pi-terminal-window"
  defp kind_icon(:product), do: "pi-package"
  defp kind_icon(:design), do: "pi-paint-brush"
  defp kind_icon(:qa), do: "pi-flask"
  defp kind_icon(:calibration), do: "pi-funnel-simple"
end
