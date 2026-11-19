defmodule RailTest.OwnBroadcasts do
  @moduledoc """
  `Rail.PubSub`'s dispatcher in test: a broadcast from one test's processes, or those whose `$callers` lead to it,
  reaches no other test's, since every test shares the seeded project.
  """

  @doc """
  Marks the calling test process as one whose processes keep their broadcasts to themselves.
  """
  def own(_context) do
    Process.put(__MODULE__, true)
    :ok
  end

  @doc false
  def dispatch(entries, from, message) do
    entries =
      case owner(self()) do
        test when is_pid(test) -> Enum.filter(entries, fn {pid, _metadata} -> owner(pid) in [nil, test] end)
        nil -> entries
      end

    Phoenix.PubSub.dispatch(entries, from, message)
  end

  # The first of the process and its `$callers` that is a marked test.
  defp owner(pid) do
    callers =
      case List.keyfind(dictionary(pid), :"$callers", 0) do
        {_key, callers} -> callers
        _none -> []
      end

    Enum.find([pid | callers], &List.keymember?(dictionary(&1), __MODULE__, 0))
  end

  # A process that has exited, or lives on another node, has nothing to read.
  defp dictionary(pid) when pid == self(), do: Process.get()

  defp dictionary(pid) when node(pid) == node() do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> dictionary
      _exited -> []
    end
  end

  defp dictionary(_remote), do: []
end
