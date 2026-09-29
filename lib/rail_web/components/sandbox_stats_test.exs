defmodule RailWeb.Components.SandboxStatsTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.Components.SandboxStats

  setup do
    %{
      stats: %{
        cpus: 14,
        memory_gb: 56,
        reserved_cpus: 14,
        reserved_memory_gb: 30,
        running: 9,
        agent_turns: 7,
        setups: 1,
        cis: 1,
        waiting: 3,
        oldest_waiting: "4m 12s",
        short_on: %{cpus: true, memory: false}
      }
    }
  end

  test "says how much of the machine is reserved and what is free", %{stats: stats} do
    html = render_component(&SandboxStats.sandbox_stats/1, stats: stats)

    assert html =~ "of 14 · none free"
    assert html =~ "of 56 · 26 GB free"
    assert html =~ "7 agent turns · 1 setup · 1 CI"
    assert html =~ "oldest 4m 12s"
  end

  test "names what the line is waiting for" do
    for {short_on, waiting, text} <- [
          {%{cpus: true, memory: false}, 3, "Short on CPUs. Memory is not what they wait for."},
          {%{cpus: false, memory: true}, 3, "Short on memory. CPUs are not what they wait for."},
          {%{cpus: true, memory: true}, 3, "Short on CPUs and memory."},
          {%{cpus: false, memory: false}, 3, "Each waits for the ones ahead of it."},
          {%{cpus: false, memory: false}, 0, "Nothing is waiting."}
        ] do
      stats = %{
        cpus: 0,
        memory_gb: 0,
        reserved_cpus: 0,
        reserved_memory_gb: 0,
        running: 0,
        agent_turns: 1,
        setups: 0,
        cis: 0,
        waiting: waiting,
        oldest_waiting: nil,
        short_on: short_on
      }

      assert render_component(&SandboxStats.sandbox_stats/1, stats: stats) =~ text
    end
  end
end
