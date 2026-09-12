defmodule Rail.Runs.Utils.OnOsProcessFinishedTest do
  use Rail.DataCase, async: true

  import Rail.Runs.Utils.OnOsProcessFinished

  alias Rail.Runs.Schemas.OsProcess

  test "broadcasts the outcome on the os_processes topic" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "os_processes")

    os_process = %OsProcess{id: "osp_test"}
    outcome = %{exit_code: 0}

    assert {:ok, ^outcome} = on_os_process_finished(os_process, outcome)
    assert_receive {:os_process_finished, ^os_process, ^outcome}
  end
end
