defmodule RailWeb.Components.DispatchBanner do
  @moduledoc false
  use RailWeb, :html

  import RailWeb.CoreComponents, only: [icon: 1]

  attr :visible, :boolean, default: true

  def dispatch_banner(assigns) do
    ~H"""
    <div
      :if={@visible}
      id="dispatch-disabled-banner"
      data-qa="dispatch-disabled-banner"
      role="alert"
      class="flex items-center space-x-3 px-4 py-2.5 rounded-lg border border-amber-500/40 bg-amber-500/10 text-amber-900 dark:text-amber-200 text-xs font-medium"
    >
      <.icon name="info_outline" class="h-4.5 w-4.5 shrink-0 text-amber-600 dark:text-amber-400" />
      <span>
        AXIS_NO_DISPATCH=1 is set. The app will inspect and display tasks, but will not invoke agent CLI tools.
      </span>
    </div>
    """
  end
end
