defmodule RailWeb.Components.ProgressBar do
  @moduledoc "A thin bar filled to a percent. Callers show the percent beside it as text, so color is not the only signal."
  use RailWeb, :html

  attr :percent, :integer, required: true
  attr :class, :string, default: "h-1.5"

  def progress_bar(assigns) do
    ~H"""
    <div
      class={["w-full rounded-full bg-slate-200 dark:bg-slate-700 overflow-hidden", @class]}
      role="progressbar"
      aria-valuenow={@percent}
      aria-valuemin="0"
      aria-valuemax="100"
    >
      <div class="h-full rounded-full bg-indigo-500" style={"width: #{@percent}%"}></div>
    </div>
    """
  end
end
