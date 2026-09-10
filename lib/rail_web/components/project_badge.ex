defmodule RailWeb.Components.ProjectBadge do
  @moduledoc false
  use RailWeb, :html

  attr :project, :any, default: nil
  attr :class, :string, default: nil

  def project_badge(assigns) do
    label = badge_label(assigns.project)
    assigns = assign(assigns, :label, label)

    ~H"""
    <span
      :if={@label != nil}
      data-qa="project-badge"
      class={[
        "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium bg-slate-200 dark:bg-slate-600 text-slate-600 dark:text-slate-300 border border-slate-300 dark:border-slate-600 shrink-0",
        @class
      ]}
    >
      {@label}
    </span>
    """
  end

  defp badge_label(%{linear_team_key: key}) when is_binary(key) and key != "", do: key
  defp badge_label(%{name: name}) when is_binary(name) and name != "", do: name
  defp badge_label(_other), do: nil
end
