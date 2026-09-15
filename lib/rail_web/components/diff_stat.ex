defmodule RailWeb.Components.DiffStat do
  @moduledoc """
  A file's additions and deletions. Zeroes are drawn too, so the columns line up.
  """
  use RailWeb, :html

  attr :additions, :integer, default: 0
  attr :deletions, :integer, default: 0
  attr :font_size, :integer, default: 12
  attr :class, :string, default: nil

  def diff_stat(assigns) do
    ~H"""
    <div
      data-qa="diff_stat"
      class={[
        "inline-flex items-center gap-1.5 font-mono font-semibold tabular-nums leading-none shrink-0",
        font_size_class(@font_size),
        @class
      ]}
    >
      <span class="text-emerald-500" data-qa="diff_stat_additions">+{@additions}</span>
      <span class="text-rose-500" data-qa="diff_stat_deletions">-{@deletions}</span>
    </div>
    """
  end

  defp font_size_class(10), do: "text-[10px]"
  defp font_size_class(11), do: "text-[11px]"
  defp font_size_class(_default), do: "text-xs"
end
