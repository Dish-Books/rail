defmodule RailWeb.Utils.FormatReservation do
  @moduledoc false

  @doc """
  Formats what a role or a sandbox reserves: `"1 CPU · 2 GB"`, `"2 CPUs · 4 GB"`.
  """
  def format_reservation(%{reserved_cpus: cpus, reserved_memory_gb: memory_gb}) do
    "#{cpus} #{if cpus == 1, do: "CPU", else: "CPUs"} · #{memory_gb} GB"
  end
end
