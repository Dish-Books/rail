defmodule RailWeb.Components.EmptyState do
  @moduledoc false
  use RailWeb, :html

  import RailWeb.CoreComponents, only: [icon: 1]

  def empty_state(assigns) do
    ~H"""
    <div
      id="overview-empty-state"
      data-qa="overview-empty-state"
      class="flex flex-col items-center justify-center py-12 text-center select-none"
    >
      <div class="flex items-center justify-center h-14 w-14 rounded-full text-emerald-600 dark:text-emerald-400 mb-4">
        <.icon name="check_circle_outline" class="h-14 w-14" />
      </div>
      <h2
        id="empty-state-title"
        data-qa="empty-state-title"
        class="text-xl font-bold text-[var(--color-on-surface)] mb-1.5"
      >
        All clear
      </h2>
      <p
        id="empty-state-subtitle"
        data-qa="empty-state-subtitle"
        class="text-sm text-[var(--color-outline)] max-w-sm"
      >
        Nothing is waiting on you. Bring an issue local to start a task.
      </p>
    </div>
    """
  end
end
