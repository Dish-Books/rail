defmodule Rail.Issues.Utils.LinearPriority do
  @moduledoc """
  Linear numbers its priorities; Rail names them.
  """

  @doc """
  Linear's number for `priority`, or nil for anything that is not one of Rail's.
  """
  def linear_priority(:urgent), do: 1
  def linear_priority(:high), do: 2
  def linear_priority(:medium), do: 3
  def linear_priority(:low), do: 4
  def linear_priority(_other), do: nil
end
