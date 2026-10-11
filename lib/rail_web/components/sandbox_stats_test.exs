defmodule RailWeb.Components.SandboxStatsTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.Components.SandboxStats

  setup do
    %{
      stats: %{
        cpus: 14,
        memory_gb: 56,
        used_memory_gb: 30.25,
        reserved_cpus: 14,
        running: 9,
        agent_turns: 7,
        setups: 1,
        cis: 1,
        waiting: 3,
        oldest_waiting: "4m 12s",
        short_on_cpus?: true
      }
    }
  end

  test "says how many CPUs are reserved and how much memory is in use", %{stats: stats} do
    html = render_component(&SandboxStats.sandbox_stats/1, stats: stats)

    assert html =~ "of 14 · none free"
    assert html =~ "30.3 GB"
    assert html =~ "of 56 GB on this machine"
    assert html =~ "7 agent turns · 1 setup · 1 CI"
    assert html =~ "oldest 4m 12s"
  end

  test "has a dash for memory on a machine that cannot say what is in use", %{stats: stats} do
    html = render_component(&SandboxStats.sandbox_stats/1, stats: %{stats | used_memory_gb: nil})

    assert html =~ "—"
    assert html =~ "of 56 GB on this machine"
  end

  test "names what the line is waiting for", %{stats: stats} do
    for {short_on_cpus?, waiting, text} <- [
          {true, 3, "Short on CPUs."},
          {false, 3, "Each waits for the ones ahead of it."},
          {false, 0, "Nothing is waiting."}
        ] do
      stats = %{stats | waiting: waiting, oldest_waiting: nil, short_on_cpus?: short_on_cpus?}

      assert render_component(&SandboxStats.sandbox_stats/1, stats: stats) =~ text
    end
  end
end
