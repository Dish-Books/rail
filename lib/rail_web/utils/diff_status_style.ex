defmodule RailWeb.Utils.DiffStatusStyle do
  @moduledoc """
  How what became of a file looks, so a file's badge and its dot in the file
  list never disagree about what `:renamed` is.
  """

  @doc """
  The Tailwind `color` and `tint` classes and the `label` for a diff file's
  `status`. Modified is what a file in a diff is unless it says otherwise, so it
  has no label of its own.
  """
  def diff_status_style(:added), do: %{color: "text-emerald-500", tint: "bg-emerald-500/10", label: "new file"}
  def diff_status_style(:deleted), do: %{color: "text-rose-500", tint: "bg-rose-500/10", label: "deleted"}
  def diff_status_style(:renamed), do: %{color: "text-violet-500", tint: "bg-violet-500/10", label: "renamed"}
  def diff_status_style(:modified), do: %{color: "text-amber-500", tint: nil, label: nil}
end
