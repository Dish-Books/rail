defmodule RailWeb.Components.DiffStat do
  @moduledoc """
  Renders additions (+X in emerald) and deletions (-Y in rose) with tabular figures.
  Zero values are still rendered (e.g. +0, -0).
  """
  use RailWeb, :html

  attr :additions, :integer, default: 0
  attr :deletions, :integer, default: 0
  attr :font_size, :any, default: 12
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
      <span class="text-emerald-500" data-qa="diff_stat_additions">+{format_count(@additions)}</span>
      <span class="text-rose-500" data-qa="diff_stat_deletions">-{format_count(@deletions)}</span>
    </div>
    """
  end

  defp font_size_class(10), do: "text-[10px]"
  defp font_size_class("10"), do: "text-[10px]"
  defp font_size_class(11), do: "text-[11px]"
  defp font_size_class("11"), do: "text-[11px]"
  defp font_size_class(12), do: "text-xs"
  defp font_size_class("12"), do: "text-xs"
  defp font_size_class(class) when is_binary(class), do: class
  defp font_size_class(_other), do: "text-xs"

  defp format_count(count) when is_integer(count), do: Integer.to_string(count)
  defp format_count(_other), do: "0"
end
