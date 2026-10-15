defmodule RailWeb.Utils.FormatReservation do
  @moduledoc false

  @doc """
  Formats what a role or a sandbox reserves: `"1 CPU"`, `"2 CPUs"`, `"0.5 CPUs"`.
  """
  def format_reservation(%{reserved_cpus: cpus}) do
    cpus = if cpus == trunc(cpus), do: trunc(cpus), else: cpus
    "#{cpus} #{if cpus == 1, do: "CPU", else: "CPUs"}"
  end
end
