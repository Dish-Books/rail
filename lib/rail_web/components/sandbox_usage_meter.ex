defmodule RailWeb.Components.SandboxUsageMeter do
  @moduledoc """
  How much of what a running sandbox reserves it is using right now, as a bar and
  a figure, flagged as it nears the limit it cannot pass.
  """
  use RailWeb, :html

  attr :id, :string, required: true
  attr :used, :any, required: true, doc: "a float, or nil when there is no reading"
  attr :reserved, :integer, required: true
  attr :unit, :string, required: true
  attr :rest, :global

  def sandbox_usage_meter(%{used: nil} = assigns) do
    ~H"""
    <span id={@id} class="font-mono text-xs text-slate-500 dark:text-slate-400" {@rest}>—</span>
    """
  end

  def sandbox_usage_meter(assigns) do
    share = if assigns.reserved > 0, do: assigns.used / assigns.reserved, else: 0.0

    assigns =
      assigns
      |> assign(:width, min(round(share * 100), 100))
      |> assign(:figure, :erlang.float_to_binary(assigns.used / 1, decimals: 1))
      |> assign(:limit, limit(share))

    ~H"""
    <div id={@id} class="flex items-center gap-2" {@rest}>
      <div class="h-1.5 w-14 rounded-full bg-slate-200 dark:bg-slate-700/70 overflow-hidden">
        <span class="block h-full bg-blue-500 rounded-full" style={"width:#{@width}%"} />
      </div>
      <span class="font-mono text-xs text-slate-700 dark:text-slate-300">{@figure}<span class="text-slate-500"> of {@reserved} {@unit}</span><span
        :if={@limit}
        class="text-slate-400"
      > · {@limit}</span></span>
    </div>
    """
  end

  defp limit(share) when share >= 0.99, do: "at limit"
  defp limit(share) when share >= 0.9, do: "near limit"
  defp limit(_share), do: nil
end
