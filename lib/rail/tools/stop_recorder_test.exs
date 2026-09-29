defmodule Rail.Tools.StopRecorderTest do
  use Rail.DataCase, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias Rail.Tools
  alias Rail.Tools.Schemas.Restart
  alias Rail.Tools.StopRecorder

  test "records when Rail went down, as a restart still waiting to come back" do
    stub(Application, :get_env, fn
      :rail, :adopt_on_boot, _default -> true
      app, key, default -> call_original(Application, :get_env, [app, key, default])
    end)

    {:ok, pid} = StopRecorder.start_link([])
    Sandbox.allow(Repo, self(), pid)
    # Stopped as its supervisor would stop it, without taking this test down too.
    Process.unlink(pid)

    assert [] = Tools.list_restarts()
    :ok = GenServer.stop(pid, :shutdown)

    assert [%Restart{stopped_at: %DateTime{}, started_at: nil}] = Tools.list_restarts()
  end

  test "stays out of the tree while adoption on boot is off" do
    assert StopRecorder.start_link([]) == :ignore
  end
end
