defmodule RailWeb.Components.ProjectBadge do
  @moduledoc false
  use RailWeb, :html

  attr :project, :any, required: true
  attr :class, :string, default: nil

  def project_badge(assigns) do
    ~H"""
    <span
      data-qa="project-badge"
      class={[
        "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium bg-slate-200 dark:bg-slate-600 text-slate-600 dark:text-slate-300 border border-slate-300 dark:border-slate-600 shrink-0",
        @class
      ]}
    >
      {@project.linear_team_key}
    </span>
    """
  end
end
